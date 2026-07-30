# Plano Mestre de Implementação — Fase 20: Emissor Nativo LLVM em Memória & Substituição do Backend C

## 🎯 Objetivo Geral
Substituir gradualmente e integralmente a geração de código C intermediário (`src/backend/c_transpiler/`) por um **Emissor Nativo LLVM IR 100% em Memória** (`src/backend/llvm_emitter/`), ativado via flag CLI `--backend=llvm`.

Ao construir o IR do LLVM diretamente na memória RAM (`LLVMModuleRef`, `LLVMBuilderRef`, `LLVMContextRef`) e compilar para JIT em tempo real ou binário nativo sem tocar no disco com arquivos `.c` ou `.ll` e sem invocar sub-processos externos de compilação C (`clang`/`llc`), eliminamos I/O de disco e atingimos **máxima velocidade de compilação (Dev Loop < 77ms)** e **máxima velocidade de execução (Release -O3 + vectorization)**.

---

## 🛡️ Princípios de Arquitetura & Decisões do Socratic Gate

1. **Arquitetura Dupla Zero-Risco:**
   * O backend C (`--backend=c`) permanece funcional e intocado como fallback/segurança.
   * O backend LLVM (`--backend=llvm`) roda em paralelo e evolui incrementalmente até ser promovido a padrão oficial.
2. **Sem Fallback Silencioso se LLVM ausente:**
   * Se o usuário passar `--backend=llvm` e o sistema não possuir o LLVM 21 instalado, o compilador interrompe imediatamente o build com código de saída 1 e mensagem amigável, sem nunca cair silenciosamente para o backend C.
3. **Instância Limpa JIT (OrcJIT v2):**
   * O comando `eiwa run --backend=llvm` compila e executa o código diretamente da memória RAM via LLVM Execution Engine sem I/O de arquivos temporários.
4. **Detecção Dinâmica do LLVM 21 em `build.zig`:**
   * Localiza automaticamente o LLVM 21 em Linux, macOS (Homebrew `/opt/homebrew/opt/llvm@21`) ou Windows sem caminhos *hardcoded*.

---

## ⚡ Estratégia de Performance (Dev vs Release)

* **Dev Loop (`eiwa run --backend=llvm`):** Roda o PassBuilder com a pass `"mem2reg"`. Promove alocações de pilha (`alloca`) para registradores SSA virtuais em tempo recorde sem perdas com otimizações pesadas.
* **Release Build (`eiwa build --backend=llvm --release`):** Roda o PassBuilder com `"default<O3>"`, `-mcpu=native`, Tail Call Optimization (`LLVMSetTailCall`) e emissão direta de objeto `.o` (`LLVMTargetMachineEmitToFile`) vinculado com `-lgc`.

---

## 🛠️ Roteiro Completo de Tarefas (Tasks 20.1 a 20.12)

### ✅ Fase 20.1 — Build Dinâmico & CLI
- [x] Detecção dinâmica do LLVM 21 em `build.zig`.
- [x] Wrapper C-API LLVM em `src/backend/llvm_emitter/c_bindings.zig`.
- [x] Suporte às flags `--backend=c|llvm` e `--release` em `src/main.zig`.

### ✅ Fase 20.2 — Infraestrutura Básica do Emissor LLVM IR
- [x] Mapeamento de tipos primitivos (`Int`, `Double`, `Bool`, `Void`, `String`) em `types.zig`.
- [x] Tradução de expressões literais, variáveis e operadores em `expression.zig`.
- [x] Tradução de statements, alocações de pilha e controle de fluxo (`while`, `if/else`, `return`) em `statement.zig`.

### ✅ Fase 20.3 — Passes de Otimização no PassBuilder
- [x] Integração de `LLVMRunPasses` com `"mem2reg"` para dev e `"default<O3>"` para release.

### ✅ Fase 20.4 — Execução Instantânea em RAM via JIT
- [x] Execução de módulos em memória RAM via OrcJIT (`LLVMCreateExecutionEngineForModule`) sem I/O de arquivos.

### ✅ Fase 20.5 — Emissão Direta de Binário Nativo
- [x] Emissão de objeto nativo `.o` (`LLVMTargetMachineEmitToFile`) e vinculação com linker nativo via `eiwa build --backend=llvm`.

### ✅ Fase 20.6 — Tipos Compostos & Instanciação (`type`, `object`, `enum`)
- [x] Mapeamento de campos de `type` para `LLVMStructTypeInContext`.
- [x] Instanciação de objetos no heap com alocação `malloc` / `GC_MALLOC`.
- [x] Leitura e escrita de propriedades (`LLVMBuildStructGEP2`, `.get_expr`, `.set_expr`) e chamadas de métodos.

---

### ⏳ Tarefas Pendentes para Substituição Total do Backend C

### ⏳ Fase 20.7 — FFI Nativo & Bibliotecas C (`lib Name { ... }`)
- [ ] Declaração dinâmica de protótipos de funções C externas no módulo LLVM.
- [ ] Suporte a ponteiros `Pointer<T>` e interoperabilidade com `libcurl`, `libpq`, `Boehm GC`, `neco`.

### ⏳ Fase 20.8 — Arrays & Coleções Genéricas (`List<T>`, `Map<K, V>`, `[1, 2, 3]`)
- [ ] Tradução de literais de array (`array_literal`) e expressões de índice (`arr[i]`).
- [ ] Suporte a contêineres monomórficos em LLVM IR.

### ⏳ Fase 20.9 — Lambdas & Closures (`() -> T`)
- [ ] Emissão de structs de closure (ponteiro de função + ambiente de variáveis capturadas).
- [ ] Chamadas dinâmicas a lambdas em LLVM IR.

### ⏳ Fase 20.10 — Sistema de Composição (`contract` & Dynamic Dispatch)
- [ ] Geração de vtables estáticas/dinâmicas em LLVM IR.
- [ ] Suporte a testes e casts de tipo em contratos (`when (x) is Contract`).

### ⏳ Fase 20.11 — Exceções & Fibras (`try/catch` e `task { }` / `.await()`)
- [ ] Suporte a `try/catch` via `LLVMBuildInvoke` / landingpads ou unwind.
- [ ] Troca de contexto de fibras cooperativas em LLVM IR.

### ⏳ Fase 20.12 — Transição Completa & Depreciação do Backend C
- [ ] Promover `--backend=llvm` como o backend oficial padrão da linguagem Eiwa.
- [ ] Marcar o backend C transpiler como legado.

---

## 🧪 Plano de Verificação Contínua

```bash
# 1. Compilar o compilador Eiwa
zig build

# 2. Executar a suíte de testes unitários do compilador
zig build test

# 3. Executar toda a suíte de 146+ testes nativos Eiwa
./zig-out/bin/eiwa test

# 4. Executar arquivos de teste específicos via LLVM JIT
./zig-out/bin/eiwa run samples/tests/llvm_expressions_test.ei --backend=llvm
./zig-out/bin/eiwa run samples/tests/llvm_math_test.ei --backend=llvm
./zig-out/bin/eiwa run samples/tests/llvm_type_test.ei --backend=llvm

# 5. Compilar executável nativo em release (-O3) via LLVM
./zig-out/bin/eiwa build samples/tests/llvm_type_test.ei --backend=llvm --release
```
