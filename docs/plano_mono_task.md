# Plano: Monomorfização + Refatoração de `Task<T>` (Alinhar com [read roadmap](docs/roadmap.md) Ver Phase 50)

## Etapa 0 — Type Params em `contract` e `skill`

### Necessidade

Hoje `contract` e `skill` **não aceitam type params**. Para o destino final:

```eiwa
contract Awaitable<T> {
    fun await(): T
}

skill TaskNeco : Awaitable<T> {
    implement fun await(): T { ... }
}
```

Precisamos estender a linguagem.

### Tasks

#### Task 50.0.1: Parser — `contract Name<T>` e `skill Name<T>`

Estender `parseContractDeclaration` e `parseSkillDeclaration` para aceitar `<T>` opcional após o nome, igual `fun` e `type` já fazem.

- `src/frontend/parser/declaration.zig` — `contractDeclaration`, `skillDeclaration`
- Adicionar `generic_params: []const []const u8` ao AST de `contract_decl` e `skill_decl`

#### Task 50.0.2: AST — campos `generic_params`

```zig
// ast.zig
pub const contract_decl = struct {
    name: []const u8,
    generic_params: []const []const u8 = &.{},  // NOVO
    contracts: []const []const u8,
    methods: []const FunSig,
    annotations: []const Annotation,
    resolved_c_name: ?[]const u8,
};

pub const skill_decl = struct {
    name: []const u8,
    generic_params: []const []const u8 = &.{},  // NOVO
    ...
};
```

Todos os pontos de criação sintética de `contract_decl`/`skill_decl` no type checker devem ser atualizados para incluir `.generic_params = &.{}`.

- `src/core/ast.zig` — structs
- `src/core/type_checker/clone.zig` — se existir
- `src/core/type_checker/infer_decl.zig` — assinaturas sintéticas

#### Task 50.0.3: Type checker — registro de contracts/skills genéricos

Em `declareSignatures`, contracts e skills com `generic_params.len > 0` devem:
1. Ser registrados em `local_symbols` (visível para imports)
2. Registrar assinatura no scope mas **não** validar corpo ainda (como funções genéricas)
3. `resolved_c_name` com prefixo do módulo

#### Task 50.0.4: Resolução de type params em constraints

```eiwa
contract Awaitable<T> { fun await(): T }
skill TaskLibaco : Awaitable<T> { ... }
```

O `T` na constraint `Awaitable<T>` do skill deve resolver para o type param do skill — mesmo mecanismo de funções genéricas.

#### Verificação

- `contract Awaitable<T> { fun await(): T }` parseia e registra
- `skill Foo : Awaitable<Int>` resolve tipo correto
- Erro se type param usado em posição inválida

---

## Etapa 1 — Monomorfização (Phase 50)

### Visão Geral

Hoje funções genéricas (`fun foo<T>(x: T): T`) são parseadas mas **ignoradas** — type checker e transpiler dão `return` antecipado. `Task<T>` funciona via casos especiais hardcoded. Precisamos de um mecanismo que instancie o corpo da função para cada `T` concreto.

### Arquitetura

```
Código Fonte
    │
    ▼
Parser ──► AST com fun_decl.generic_params = ["T"]
    │
    ▼
Type Checker (declareSignatures)
    │
    ├── Se genérica → registra assinatura mas NÃO type-check o corpo
    │
    ▼
Type Checker (validate)
    │
    ├── Encontra chamada concreta: foo<Int>(42)
    │   ├── Gera uma CÓPIA monomorfizada do fun_decl
    │   │   └── substiui T → Int no AST copiado
    │   └── Type-check o corpo copiado (normal, sem generic_params)
    │
    ▼
Transpiler
    │
    ├── Para cada instância monomorfizada, gera função C separada
    │   └── nome: foo_Int, foo_String, etc (resolved_c_name)
    │
    ▼
C + Runtime
```

### Tasks

#### Task 50.1.1: Mecanismo de clonagem de AST (COMPLETED)

`cloneNode` + `cloneTypeRef` em `src/core/type_checker/clone.zig`. Já usados por `monomorphizeClass`. Copiam recursivamente um ASTNode substituindo type params por tipos concretos via `generic_map`.

#### Task 50.1.2: Trigger de monomorfização no type checker

Em `inferCall` (`infer_call.zig`), quando:
```
callee = fun_decl com generic_params.len > 0
type_args = [EiwaType.Concrete]
```
1. Gerar chave única: `"funName_T1_T2"` (ex: `"foo_Int"`)
2. Verificar cache de instâncias (`monomorphized_functions: ArrayList(*ASTNode)`)
3. Se não existir: clonar o `fun_decl` com `subst = { T → Int }`, inserir no módulo atual
4. Type-check o clone normalmente

Arquivos afetados:
- `src/core/type_checker/infer_call.zig` — trigger no call resolution
- `src/core/type_checker/core.zig` — `monomorphized_functions` adicionado
- `src/core/type_checker/monomorphize.zig` — nova função `monomorphizeFunction`

#### Task 50.1.3: Geração de C para instâncias

No transpiler:

1. Coletar instâncias monomorfizadas geradas durante o type checking
2. Emitir função C separada para cada uma, com nome mangled:
   - `foo_Int`, `foo_String`, `Task_Int_new`, etc.
3. Atualizar chamadas para usar o nome mangled correto

O transpiler já usa `resolved_c_name` — basta garantir que instâncias tenham c_name único.

Arquivos afetados:
- `src/backend/c_transpiler/declaration.zig` — `emitFunDecl` deve processar instâncias
- `src/backend/c_transpiler/expression.zig` — resolver chamada para instância correta

#### Task 50.1.4: Cache de instâncias

Instâncias monomorfizadas devem ser cacheadas para evitar duplicação. `monomorphized_functions: ArrayList(*ASTNode)` no `TypeChecker`.

#### Task 50.1.5: Tipos genéricos (`type Task<T>`) — via `monomorphizeClass`

Já implementado via `monomorphizeClass`. `Task<Int>` vira struct C concreta com nome `Task_Int`.
Construtor `Task<Int>.new(…)` vira `Task_Int_new(…)`.

#### Verificação

- `eiwa test samples/tests/generics_test.ei` passa
- Funções com múltiplos type params funcionam
- Type params em constraints de contrato funcionam (`T : Stringable`)
- Chamadas com inferência de tipo funcionam (`foo(42)` inferindo `T = Int`)

---

## Etapa 2 — Refatoração de `Task<T>` (Remover Special Cases)

### O que será removido

| Arquivo | Linha | O que faz |
|---------|-------|-----------|
| `infer_call.zig` | ~44 | Hardcoded `if name == "task"` |
| `infer_member.zig` | — | Hardcoded `.await()` resolution |
| `expression.zig` | ~373 | Hardcoded `task()` Geração de C |
| `expression.zig` | ~481 | Hardcoded `.await()` Geração de C |
| `core.zig` (backend) | ~55 | Hardcoded `if base_name == "Task"` em `cType` |

### Novo fluxo

```
eiwa task { 42 }
    │
    ├── task é fun task<T>(block: () -> T): Task<T> (genérica normal)
    │
    ├── Type checker monomorfiza: fun task<Int>(block: () -> Int): Task<Int>
    │   └── Corpo real em std/core.ei roda e retorna Task<Int>
    │
    ├── Transpiler: emite função task_Int normalmente
    │
    └── Task<Int> é type concreto monomorfizado
```

### Tasks

#### Task 50.2.1: Garantir que `fun task<T>` seja type-checkável

O corpo de `task<T>` em `std/core.ei` invoca o construtor de `Task<T>`:

```eiwa
fun task<T>(block: () -> T): Task<T> {
    return Task<T>.new(block)
}
```

Com monomorfização, `Task<Int>` vira struct concreta. O construtor `Task<Int>.new` chama libaco para criar a co-rotina de verdade.

#### Task 50.2.2: Código da fibra vai pra `lib {}` (neco)

Em vez de gerar `({ })` inline no transpiler, o construtor de `Task<T>` chama `lib {}`:

```eiwa
lib Neco {
    fun neco_start(fn: OpaquePointer, argc: Int, ...): Int
    fun neco_suspend(): Int
    fun neco_resume(id: Int): Int
    fun neco_lastid(): Int
}
```

O construtor `Task<T>.new(block)` aloca a Task, cria co-rotina via `neco_start`, armazena o `id` em `self.co_id`. A lambda `block` precisa ser convertida para ponteiro de função C via closure.

Arquivo: `src/std/core.ei` + runtime `src/runtime/third_party/neco/`

#### Task 50.2.3: Remover special cases do type checker

Remover:
- Bloco `if (std.mem.eql(u8, name, "task")` em `infer_call.zig` (~linha 44)
- Lógica `.await()` especial em `infer_member.zig`

#### Task 50.2.4: Remover special cases do transpiler

Remover:
- Bloco `c.callee.data == .identifier and … base_name == "Task"` em `expression.zig` (~linha 373)
- Bloco `g.name == "await" and rt_base == GenericInstance(Task)` em `expression.zig` (~linha 481)

#### Task 50.2.5: Limpar `cType` de Task

Remover o special case em `core.zig`:
```zig
.GenericInstance => |gi| {
    if (std.mem.eql(u8, gi.base_name, "Task")) return "EiwaTask*";  // ← REMOVER
}
```

Cada `Task<T>` monomorfizada gera seu próprio C type.

#### Task 50.2.6: Remover `fiber.c` / `fiber.h`

Após libaco integrado, remover todo `src/runtime/fiber.c` e `src/runtime/fiber.h`.

#### Verificação

- `eiwa test samples/tests/task_test.ei` — mesmos 8 testes passam
- Nenhum `grep "task" src/core/type_checker/infer_call.zig` além de nomes de variável
- Nenhum `grep "await" src/core/type_checker/infer_member.zig` como special case
- Nenhum bloco `base_name == "Task"` no transpiler

---

## Etapa 3 — Arquitetura Final: Contract + Skill + neco

### Design final da linguagem

```eiwa
// ===== std/core.ei =====

// Contrato: qualquer coisa que pode ser aguardada
contract Awaitable<T> {
    fun await(): T
}

// Skill: implementa Awaitable usando neco
lib Neco {
    fun neco_start(fn: OpaquePointer, argc: Int, ...): Int
    fun neco_suspend(): Int
    fun neco_resume(id: Int): Int
    fun neco_lastid(): Int
}

skill TaskNeco : Awaitable<T> {
    implement fun await(): T {
        while (!this.done) {
            Neco.neco_resume(this.co_id)
        }
        return *this.resultPtr
    }
}

// Type concreto que compõe o skill
type Task<T>(
    val co_id: Int,
    var done: Bool,
    val resultPtr: OpaquePointer
) + TaskNeco

// Factory function
fun task<T>(block: () -> T): Task<T> {
    return Task<T>.new(block)
}
```

### Tasks

#### Task 50.3.1: Skill methods acessarem `this.props` de `type`

Skills precisam acessar as propriedades do `type` consumidor via `this`. Ex: em `TaskNeco.await()`, `this.done` e `this.co_id` são props de `Task<T>`. Verificar se o mecanismo atual de skill → type resolve isso corretamente (já deve funcionar — skills recebem `this` do tipo consumidor).

#### Task 50.3.2: `lib {}` bindings de neco

Baixar neco em `src/runtime/third_party/neco/` (single-file: `neco.c` + `neco.h`):
- `neco.h` — header público
- `neco.c` — implementação completa (amalgamação, sem dependências)

Criar binding `lib Neco` em `src/std/core.ei` expondo as funções necessárias.

#### Task 50.3.3: Construtor `Task<T>.new(block)` com neco

O construtor da type `Task<T>` deve:
1. Alocar a Task via GC
2. Criar lambda C a partir do `block` (closure)
3. Chamar `neco_start(fn_ptr, argc, ...)` com a lambda
4. Armazenar `co_id` (retornado por `neco_lastid()`) na Task

O closure packing (lambda → `{fn_ptr, env}`) já existe no transpiler para closures normais. O construtor precisa receber a lambda como `EiwaClosure` e extrair `fn_ptr` + `env`.

#### Task 50.3.4: `await()` via skill implementado

O método `await()` no skill `TaskNeco`:
1. Loop `while(!this.done)` chamando `Neco.neco_resume(this.co_id)`
2. Quando done, ler `this.resultPtr` e retornar valor tipado

Isso substitui os `({ })` blocks do transpiler atual.

#### Task 50.3.5: Remover runtime legado

Após neco + refatoração:
- `src/runtime/fiber.c` — deletar
- `src/runtime/fiber.h` — deletar
- `src/main.zig` — remover `src/runtime/fiber.c` dos args de compilação

#### Verificação

- `eiwa test samples/tests/task_test.ei` — mesmos 8 testes passam
- `eiwa test` — suite completa passa (123+ testes)
- Nenhum código de runtime legado (grep por `fiber.c`, `fiber_entry`, `swapcontext`)
- Nenhum special case no compilador

---

## Estrutura de Diretórios Final

```
src/
├── runtime/
│   └── third_party/
│       └── neco/
│           ├── LICENSE
│           ├── neco.c
│           └── neco.h
├── std/
│   └── core.ei              ← Task<T>, Awaitable<T>, TaskNeco, task<T>
├── core/
│   ├── ast.zig               ← generic_params em contract/skill/fun/type
│   ├── monomorph.zig         ← NOVO: mecanismo de clonagem + substituição
│   └── type_checker/
│       ├── infer_call.zig    ← sem special cases
│       ├── infer_member.zig  ← sem special cases
│       └── ...
├── frontend/
│   └── parser/
│       └── declaration.zig   ← <T> em contract, skill
└── backend/
    └── c_transpiler/
        ├── expression.zig    ← sem special cases
        ├── core.zig          ← sem special case Task
        └── ...
```

---

## Dependências Completas

```
Etapa 0 (Contract/Skill Generics) ─── necessário para Etapa 3
    │
    ▼
Etapa 1 (Monomorfização) ─────────── necessário para Etapas 2 e 3
    │
    ▼
Etapa 2 (Remover Special Cases) ──── necessário para Etapa 3
    │
    ▼
Etapa 3 (Contract + Skill + neco) ─── destino final
```

## Cronograma Estimado

| Etapa | Esforço | Complexidade |
|------|---------|--------------|
| 0 — Type params em contract/skill | 2 dias | Média |
| 1 — Monomorfização | 3-5 dias | Alta |
| 2 — Remover special cases | 1 dia | Baixa |
| 3 — Contract + Skill + neco | 2-3 dias | Média |
| **Total** | **8-11 dias** | |

## Checklist Final (100% do destino)

- [ ] `contract Awaitable<T>` com type param
- [ ] `skill TaskNeco : Awaitable<T>` com type param
- [ ] Funções genéricas monomorfizadas (`fun task<T>`)
- [ ] Tipos genéricos monomorfizados (`type Task<T>`)
- [ ] neco em `third_party/neco/` com binding `lib Neco`
- [ ] `Task<T>` usando `skill TaskNeco` + neco no runtime
- [ ] Nenhum special case `task`/`await` no compilador
- [ ] `fiber.c`/`fiber.h` removidos
- [ ] 125+ testes passando
