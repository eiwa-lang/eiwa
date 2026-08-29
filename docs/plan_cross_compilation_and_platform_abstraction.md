# Plano de Especificação: Cross-Compilation (`--target`) e Abstração de Plataforma no Eiwa

> Status: Aprovado  
> Data: 2026-08-29  

---

## 1. Visão Geral e Objetivos

O objetivo deste projeto é permitir que o Eiwa compile binários nativos para múltiplos sistemas operacionais e arquiteturas (Linux musl/glibc, macOS Darwin, Windows MinGW, WASM/WASI, etc.) de forma tão simples e direta quanto Go ou Rust, mantendo o sistema de tipos explícito baseado em composição (`type`, `contract`, `skill`, `object`).

### Metas Principais:
1. **Sintaxe Unificada de Plataforma:** Permitir especialização de `object`, `lib` e `type` diretamente pela sintaxe `object("target") Nome`.
2. **Zero Runtime Overhead:** A seleção do código de plataforma ocorre estaticamente em tempo de compilação.
3. **Cross-Compilation Out-of-the-Box:** Suporte ao parâmetro `--target` com aliases simplificados (ex: `--target windows`, `--target linux`) e delegação de linking cruzado para `zig cc -target <triple>`.
4. **Fallback Universal:** Declarações universais (sem discriminador) atuam como fallback padrão para plataformas não especializadas.
5. **Retrocompatibilidade:** Sem a flag `--target`, o `eiwac` funciona exatamente como hoje (detecta o host e usa o toolchain local).

---

## 2. Sintaxe e Design no Código Eiwa

### 2.1 Especialização de Singletons (`object`)

O identificador do objeto é mantido idêntico em todas as plataformas para que o chamador não precise de wrappers ou re-exports.

```kotlin
// std/path.ei

// Implementação para sistemas POSIX (Linux, macOS, BSD)
object("posix") PathUtils {
    fun separator(): String = "/"
}

// Implementação para Windows
object("windows") PathUtils {
    fun separator(): String = "\\"
}

// Em qualquer lugar do código:
val sep = PathUtils.separator() // Resolvido estaticamente no build
```

Múltiplos targets podem ser agrupados na mesma declaração:
```kotlin
object("macos", "linux") AudioDriver : AudioContract {
    implement fun play() { ... }
}

object("windows") AudioDriver : AudioContract {
    implement fun play() { ... }
}
```

### 2.2 Especialização de FFI e Cabeçalhos C (`lib`)

Evita que o compilador tente carregar cabeçalhos incompatíveis (ex: `<windows.h>` no Linux):

```kotlin
@Header("<unistd.h>")
lib("posix") NativeProcess {
    fun getpid(): Int
}

@Header("<windows.h>", "<process.h>")
lib("windows") NativeProcess {
    fun _getpid(): Int
}

object("posix") Process {
    fun pid(): Int = NativeProcess.getpid()
}

object("windows") Process {
    fun pid(): Int = NativeProcess._getpid()
}
```

### 2.3 Fallback Universal

Se existir uma versão universal e uma especializada, a universal é usada para todos os outros targets:

```kotlin
// Usado especificamente no Windows
object("windows") SystemTheme {
    fun isDark(): Bool = WinAPI.checkDarkTheme()
}

// Fallback universal para todas as demais plataformas
object SystemTheme {
    fun isDark(): Bool = false
}
```

---

## 3. Parâmetro `--target` e Resolução de Triples

### 3.1 Aliases Simplificados

O desenvolvedor pode usar nomes diretos e amigáveis ou triples completas:

| Comando | Target Triple Resolvida | Formato / Observação |
|---|---|---|
| `eiwac build --target windows` | `x86_64-windows-gnu` | Binário Windows `.exe` via MinGW ABI |
| `eiwac build --target linux` | `x86_64-linux-musl` | Binário 100% estático (roda em qualquer distro) |
| `eiwac build --target linux-arm64` | `aarch64-linux-musl` | Binário estático Linux ARM64 |
| `eiwac build --target macos` / `darwin` | `aarch64-macos` / `x86_64-macos` | Binário Mach-O macOS |
| `eiwac build --target wasm` / `wasi` | `wasm32-wasi` | WebAssembly WASI |
| `eiwac build --target <triple>` | `<triple>` | Qualquer triple LLVM/Zig suportada |
| *(sem flag `--target`)* | Target do Host | Usa `cc` nativo e bibliotecas locais |

### 3.2 Tags de Correspondência

Um target ativo (ex: `x86_64-unknown-linux-musl`) casa com qualquer uma das seguintes tags nos discriminadores de declaração:
- Nome exato do SO: `"linux"`
- Família do SO: `"posix"`
- Arquitetura: `"x86_64"`
- Triple exata: `"x86_64-unknown-linux-musl"` ou `"x86_64-linux"`

---

## 4. Pipeline do Compilador e Mudanças de Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│ 1. CLI & Target Triple Parsing (--target)                   │
│    src/main.zig, src/core/target.zig                        │
└──────────────────────────────┬──────────────────────────────┘
                               │ TargetInfo (os, arch, family)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Frontend: Lexer, Parser & AST Support                    │
│    object("target", ...) / lib("target") / type("target")   │
│    src/core/ast.zig, src/frontend/parser/declaration.zig    │
└──────────────────────────────┬──────────────────────────────┘
                               │ AST com platform_targets
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Semantic Analysis & Platform Filtering                   │
│    Filtra nós não aplicáveis ao target ativo                │
│    Valida ausência de duplicatas e cobertura de contratos    │
│    src/core/type_checker/core.zig, infer_decl.zig           │
└──────────────────────────────┬──────────────────────────────┘
                               │ AST Especializado
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. LLVM Backend & Cross-Link Driver                         │
│    Configura TargetTriple, TargetMachine e invoca zig cc    │
│    src/backend/llvm_emitter/core.zig                        │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Stdlib POSIX & Windows Abstraction Refactor             │
│    std/fs.ei, std/process.ei, std/system.ei, std/time.ei    │
└─────────────────────────────────────────────────────────────┘
```

### 4.1 Módulo `src/core/target.zig`
- Cria a struct `TargetInfo`:
  - `triple: []const u8`
  - `os_tag: std.Target.Os.Tag`
  - `arch: std.Target.Cpu.Arch`
  - `family: enum { posix, windows, wasm, none }`
- Métodos:
  - `detectHost(allocator) TargetInfo`
  - `parse(allocator, input) !TargetInfo` (faz o de-para de aliases como `"windows"` $\rightarrow$ `x86_64-windows-gnu`)
  - `matchesTag(self, tag) bool`
  - `matchesAny(self, tags: [][]const u8) bool`

### 4.2 Parser (`src/frontend/parser/declaration.zig`)
- Em `objectDeclaration`, `libDeclaration` e `typeDeclaration`, checa se o token seguinte à keyword é `(` com lista de strings:
  ```zig
  // Exemplo: object("posix", "linux") Name
  ```
- Salva `platform_targets: ?[][]const u8` no nó correspondente em `src/core/ast.zig`.

### 4.3 Type Checker (`src/core/type_checker/core.zig` e `infer_decl.zig`)
- Durante a descoberta de declarações (Pass 0):
  1. Se uma declaração tem `platform_targets`, testa se `target_info.matchesAny(targets)`.
  2. Se não casar e não for universal, a declaração é descartada para o build atual.
  3. Se houver mais de uma declaração especializada válida com o mesmo nome para o mesmo target ativo, reporta erro de duplicata.
  4. Se houver uma declaração especializada ativa e uma universal (fallback), a especializada tem precedência e substitui o fallback.

### 4.4 LLVM Emitter (`src/backend/llvm_emitter/core.zig`)
- Configura `LLVMCreateTargetMachine` com a target triple resolvida.
- No linker driver (`emitNativeBinary`):
  - Se for target diferente do host, invoca `zig cc -target <triple>` como linker.
  - Remove inclusões automáticas de Homebrew macOS (`/opt/homebrew/...`) ao compilar para targets não-macOS.

### 4.5 Refatoração da Biblioteca Padrão (`src/std/`)
- `std/fs.ei`: `lib("posix") NativeFS` vs `lib("windows") NativeFS`.
- `std/process.ei`: `lib("posix") NativeProcess` vs `lib("windows") NativeProcess`.
- `std/time.ei`: `lib("posix") NativeTime` vs `lib("windows") NativeTime`.

---

## 5. Plano de Validação e Testes

1. **Testes Unitários em Zig (`zig build test`):**
   - Resolução de targets (`target.zig`).
   - Parsing de `object("posix")`, `lib("windows")`, `type("linux")`.
   - Filtragem do Type Checker com diferentes `TargetInfo`.
2. **Suíte de Testes do Eiwa (`./bin/eiwac test`):**
   - Garantir 100% de aprovação de toda a suíte existente no host.
3. **Validação de Cross-Compilation:**
   - Teste de build estático: `./bin/eiwac build --target linux samples/hello.ei` $\rightarrow$ Validar formato ELF gerado.
   - Teste de build Windows: `./bin/eiwac build --target windows samples/hello.ei` $\rightarrow$ Validar formato PE/COFF `.exe` gerado.
