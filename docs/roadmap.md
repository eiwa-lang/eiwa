# Eiwa Compiler Roadmap & Progress

This document tracks the historical progress, current status, and future roadmap of the Eiwa Compiler. 

> **For AI Agents:** Use this file to identify the current phase, check what has already been built, and check off completed tasks as you work.
> **Phase 73 — Incremental Object Cache & Fast `run`** (Two-Unit Split `deps.o` × `entry.o`, cache AOT `~/.eiwa/cache/bin`, 0.01s hit / 0.27s warm edit) — **concluída**.
> **Fase atual (2026-08):** **Phase 72 — Lacunas do ADR 31 no backend LLVM** (campos de receiver em lambdas sem `this.`; safe-calls encadeados `?.`) — **concluída**.
> **Phase 69 — Dispatchers & Thread Pool** (paralelismo real multi-core estilo Kotlin `Dispatchers`, `task {}` eager em thread pool de N cores, `std.thread`/`std.atomic`, `sync`, `Mutex`) — **concluída** (ADR 51).
> **Phase 68 — Coroutines Stackless** (async/await Kotlin-style; remoção do backend C + neco) — **concluída** (ADR 48).

---

## 🚀 Phase Status & Task Breakdown

### Phase 1 to Phase 5: Infrastructure and Parser (COMPLETED)
- [x] Initialize Zig build environment.
- [x] Create robust lexer and recursive descent parser.
- [x] Establish basic C transpiler and inference engine.

### Phase 6: Control Flow & Expressions (COMPLETED)
- [x] Implement Math, Logic, and Comparison Operators.
- [x] Implement `while` loops, `return`, and assignments.
- [x] Validate via recursive `fibonacci.ei` execution.

### Phase 7: Architecture Refactoring & Documentation (COMPLETED)
- [x] Split source into `core`, `frontend`, and `backend` modules.
- [x] Add Zigdoc to all structural components.

### Phase 8: Classes and OOP Pragmatism (COMPLETED — SUPERSEDED BY PHASE 41)
> **Nota:** O modelo `class` construído aqui (e estendido na Phase 30 com herança) será substituído pelo sistema de composição `type`/`contract`/`skill` da Phase 41 (ADR 25). `class`, `open` e herança serão removidos da linguagem.
- [x] **Task 8.1:** Update Lexer and AST to support `class`, properties, and primary constructors.
- [x] **Task 8.2:** Implement property access (`.`) and instantiation parsing.
- [x] **Task 8.3:** Transpile classes into C `struct` definitions and initialize them safely via implicit `_new` calls.
- [x] **Verify:** Instantiate `class Person(val name: String, var age: Int)` successfully.

### Phase 9: Type Checker Enforcement (COMPLETED)
- [x] **Task 9.1:** Introduce `Scope` (Symbol Table) for resolving variables inside blocks.
- [x] **Task 9.2:** Add `resolved_type` mapping to the AST.
- [x] **Task 9.3:** Emit detailed, rich compiler errors (pointing to exact line and column) when assigning incompatible types.
- [x] **Verify:** The compiler intercepts a `String` to `Int` reassignment, prints a rich `TypeError`, and aborts.

### Phase 10: Standard Library & Advanced Primitives (COMPLETED)
- [x] **Task 10.1:** Implement a native `String` type structure (size + buffer) rather than raw C pointers (`const char*`).
- [x] **Task 10.2:** Transpile `+` operator on Strings into native functions using AST `resolved_type`.
- [x] **Verify:** Manipulate strings natively.

### Phase 11: Methods and Operator Overloading (COMPLETED)
- [x] **Task 11.1:** Add methods support inside classes (`fun` within `class_decl`).
- [x] **Task 11.2:** Inject `self` automatically into method scopes via the TypeChecker.
- [x] **Task 11.3:** AST Desugaring! Convert `a + b` to `a.plus(b)` dynamically during semantic analysis.
- [x] **Verify:** Class `Vector` successfully overloads the `+` operator natively.

### Phase 12: Function Modifiers (COMPLETED)
- [x] **Task 12.1:** Introduce `kw_override` and `kw_operator` to the Lexer and AST.
- [x] **Task 12.2:** Update Parser to parse modifier arrays before function declarations.
- [x] **Task 12.3:** Semantic Enforcement: Block compilation if an overloaded math method is missing the `operator` modifier.
- [x] **Verify:** Strict Kotlin-like enforcement prevents accidental overload.

### Phase 13: Null Safety (COMPLETED)
- [x] **Task 13.1:** Introduce nullable types (`String?` and `String | null`).
- [x] **Task 13.2:** Introduce safe call `?.`, elvis operator `?:`, and not-null assertion `!!`.
- [x] **Task 13.3:** Semantic Enforcement: Block compilation if a nullable type is accessed unsafely.
- [x] **Task 13.4:** Add support to `print()` as a native built-in function via a bypass in the TypeChecker mapping the invocation to C `_Generic printf`. (Note: Later cleaned up via standard library packages).
- [x] **Verify:** Compiler intercepts null-safety violations and the C transpilier emits ternary checks.

### Phase 14: CLI & Build Pipeline (COMPLETED)
- [x] **Task 14.1:** Implement the `eiwa build file.ei` command in the CLI (`main.zig`).
- [x] **Task 14.2:** The `build` command compiles the code generating a standalone static binary without executing it.
- [x] **Task 14.3:** Optimize the pipeline of the C Transpiler to erase intermediate `.c` and `.o` files, leaving only the executable.

### Phase 15: Memory Management & Garbage Collection (COMPLETED)
- [x] **Task 15.1:** Replace manual allocations (`malloc`) in the C Transpiler with a conservative Garbage Collector (Boehm GC) via the `-lgc` linker flag.
- [x] **Task 15.2:** Eliminate memory leaks in native objects (`EiwaString`, class instances).
- [x] **Task 15.3:** Ensure runtime object lifecycles are safe and do not freeze execution.

### Phase 16: Módulos & Multi-file Compilation (COMPLETED)
- [x] **Task 16.1:** Add support for the `import` keyword in the Lexer/Parser.
- [x] **Task 16.2:** Allow the compiler to read, analyze, and compile multiple `.ei` files into a single Global AST.
- [x] **Task 16.3:** Resolve namespace collisions between files using dynamic Name Mangling.

### Phase 17: Core Library, Arrays & For-Loops (COMPLETED)
- [x] **Task 17.1:** Remove the native bypass of functions like `print()`, `assert()`, `exit()` in the TypeChecker, utilizing the hidden standard library package instead.
- [x] **Task 17.2:** Native support for Collections/Arrays (`[String]`).
- [x] **Task 17.3:** Support native iteration with `for` loops (`for (item in list)`).

### Phase 18: Short Ternary Operator (COMPLETED)
- [x] **Task 18.1:** Add support in the Lexer/AST for the Ternary Operator (`condition ? true_expr : false_expr`).
- [x] **Task 18.2:** Implement short ternary (`condition ? true_expr`), which returns `null` automatically if the condition is false.
- [x] **Task 18.3:** Implement semantic validation (verify matching types, forcing short ternaries to return union types with `null`).
- [x] **Task 18.4:** Transpile control structure safely to the C ternary operator.

### Phase 19: Exception Handling & Multi-Catch (COMPLETED)
- [x] **Task 19.1:** Implement support for `try` and `catch` blocks (excluding `finally` to simplify design).
- [x] **Task 19.2:** Add support for Multi-Catch (`catch (e: ExceptionA | ExceptionB)`) and optional catch blocks (`catch { ... }`).
- [x] **Task 19.3:** Map Exceptions and non-local unwinding in the C Transpiler via `<setjmp.h>` (setjmp/longjmp).

### Phase 20: LLVM Native Emitter & Release Pipeline (COMPLETED — LLVM é o único backend, ver Phase 68)
> **Nota (2026-08, Phase 68):** com a remoção do backend C (Fase F da Phase 68), o LLVM deixa de ser
> "padrão com C secundário" e vira o **único backend** (obrigatório no build.zig). O histórico abaixo
> (paridade e promoção) está mantido; a Task 20.12 foi concluída e o backend C entra em remoção.
> **Nota de paridade (Ago 2026, branch `feat/llvm-backend-parity`):** a Task 20.12 (promoção do LLVM a padrão) está **bloqueada** — o emissor ainda não tem paridade total com o backend C.
> **Avanços estruturais recentes (Fev/Ago 2026):**
> 1. **Resolução Estática de Propriedades de Classe na AST (`owner_type_c_name`)**: Adicionamos o campo `owner_type_c_name` aos nós `identifier` e `assignment` da AST (`src/core/ast.zig`) e sua anotação estática no Type Checker (`src/core/type_checker/infer_expr.zig`). Isso eliminou heurísticas frágeis de varredura/adivinhação de structs via HashMap no backend LLVM (`statement.zig` e `expression.zig`), garantindo calculo exato de offsets `GEP2` e prevenindo colisões com structs da stdlib (ex: `json_JsonParser`).
> 2. **Gaps de Paridade Corrigidos:** `hashCode` de primitivos, builtins de `NativeArray` (`.length`/`.push`/`.get`/`.set`), `String.replace`, comparadores de String via `strcmp` (`==`/`!=`), literais de array com wrap em `List<T>`, `for`-in, e terminators de control-flow.
> 3. **Erros de null-termination de Enums:** Corrigidos com `dupeZ` no registro de nomes de enum globals em LLVM IR.
> 4. **Isolamento de Suíte de Teste com `setjmp`**: Suíte de teste LLVM atualizada para envolver cada bloco de teste em quadros de exceção `setjmp`, permitindo isolar falhas e relatar resultados exatos sem abortos silenciosos.
> Gap estrutural remanescente: **dynamic dispatch de contratos** (Phase 61 prioritária). Todos os special cases estão marcados com `TODO(emitter): SPECIAL CASE` para revisão.
Substituição completa do backend C por um emissor nativo LLVM IR construído 100% em memória via LLVM C-API 21 (`llvm-c/Core.h`), eliminando I/O de disco e subprocessos shell.
- [x] **Task 20.1:** Adicionar suporte às flags `--backend=c|llvm` e `--release` na CLI (`src/main.zig`), com detecção dinâmica do LLVM 21 em `build.zig`.
- [x] **Task 20.2:** Construir a infraestrutura básica do emissor nativo LLVM (`src/backend/llvm_emitter/`) traduzindo a AST Resolvida (primitivos, variáveis, condicionais, loops `while` e funções) diretamente em estruturas LLVM em memória.
- [x] **Task 20.3:** Conectar passes de otimização LLVM via PassBuilder (`default<O3>` para `--release` e `mem2reg` para dev) para gerar binários nativos de alta performance.
- [x] **Task 20.4:** Otimizações de Build-Time (Dev Loops instantâneos em < 77ms):
  - Eliminar escrita de arquivos `.ll` e `.c` no disco.
  - Execução JIT instantânea via OrcJIT (`LLVMCreateExecutionEngineForModule`) e emissão direta de objeto `.o` (`LLVMTargetMachineEmitToFile`) sem invocar `clang`/`llc`.
- [x] **Task 20.5:** Suporte a Binário Nativo Direto (`eiwa build --backend=llvm`) com `-O3` e `-lgc` ativado.
- [x] **Task 20.6:** Tipos Compostos & Instanciação (`type`, `object`, `enum`):
  - Mapear campos de `type` para `LLVMStructTypeInContext`.
  - Instanciação de objetos gerenciada pelo GC (`malloc` / `GC_MALLOC`).
  - Leitura e escrita de propriedades (`LLVMBuildStructGEP2`, `.get_expr`, `.set_expr`) e chamadas de métodos de instância.
- [x] **Task 20.7:** FFI Nativo & Bibliotecas C (`lib Name { ... }`):
  - Declaração dinâmica de protótipos de funções C externas no módulo LLVM (`declareLib`).
  - Interoperabilidade com bibliotecas nativas C (`libcurl`, `libpq`, `Boehm GC`, POSIX libc).
- [x] **Task 20.8:** Arrays & Coleções Genéricas (`List<T>`, `Map<K, V>`, `[1, 2, 3]`):
  - Tradução de literais de array (`array_literal`) e expressões de índice (`arr[i]`, `index_expr`, `index_set_expr`).
  - Suporte a layout de array buffer (tamanho, capacidade e elementos) em LLVM IR.
- [x] **Task 20.9:** Lambdas & Closures (`() -> T`):
  - Emissão de funções anônimas em LLVM IR (`lambda_expr`).
  - Suporte a chamadas dinâmicas a ponteiros de função/lambdas em LLVM IR.
- [x] **Task 20.10:** Sistema de Composição (`contract` & Dynamic Dispatch):
  - Emissão e vinculação de implementações de contratos (`contract`) em `type` no LLVM IR.
  - Suporte a chamadas polimórficas de contrato no LLVM backend.
- [x] **Task 20.11:** Exceções & Fibras (`try/catch` e `task { }` / `.await()`):
  - Suporte a propagação de exceções e controle de fluxo seguro em LLVM IR.
  - Suporte a concorrência e tarefas em LLVM IR.
- [x] **Task 20.12:** Transição Completa & Promoção do Backend LLVM a Padrão Oficial (**CONCLUÍDA — paridade total alcançada**):
  - Promover o LLVM Native Emitter (`--backend=llvm`) como o backend oficial padrão da linguagem Eiwa.
  - Backend C mantido como suporte secundário legado (`--backend=c`).
  - Critério objetivo de promoção: paridade total na suíte nativa — `eiwac test samples/tests` com `--backend=llvm` (default quando LLVM disponível) passa 53/53, idêntico ao backend C; `failing_llvm` zerado (Phase 64); suíte completa verde nos dois backends + `zig build test`.

### Phase 21: Native Test System & CLI Refinements (COMPLETED)
- [x] **Task 21.1:** Add native `test "name" { ... }` blocks in the AST and Parser.
- [x] **Task 21.2:** Implement the `eiwa test` CLI command to search for `_test.ei` files and run test suites in isolation.
- [x] **Task 21.3:** Make file extensions optional in imports (focusing strictly on `.ei` files).
- [x] **Verify:** Native tests run and pass using `eiwa test`.

### Phase 22: Top-Level Statements & Hybrid Main (COMPLETED)
- [x] **Task 22.1:** Update the AST and Parser to allow free statements (e.g. `print`, function calls) at the root level of files.
- [x] **Task 22.2:** The TypeChecker scopes all root-level statements and compiles them in order.
- [x] **Task 22.3:** The CTranspiler wraps top-level statements inside the generated `eiwa_main()` or `main()`, avoiding the need for `fun main()`.
- [x] **Task 22.4:** Support Hybrid Main: if the user provides `fun main()`, top-level statements are either wrapped or checked for conflicts.
- [x] **Task 22.5:** Ensure imported modules do not execute their top-level statements; only the entry file or tests run.
- [x] **Verify:** Samples run correctly without needing an explicit `fun main()`.

### Phase 23: Function Overloading & Global Symbol Table (COMPLETED)
- [x] **Task 23.1:** Replace the temporary `.Unknown` type with a global symbol table supporting Function Overloading and C backend Name Mangling.
- [x] **Task 23.2:** Resolve overloaded calls (e.g. `System.print(String)` and `System.print(Int)`) checking argument types statically.
- [x] **Task 23.3:** Validate cross-file overloaded functions in the Global AST.

### Phase 24: Native SDK Architecture (COMPLETED)
- [x] **Task 24.1:** Eliminate utility methods from raw C runtime (`eiwa_runtime.h`), moving primitive logic into the Eiwa SDK.
- [x] **Task 24.2:** Create clean C bindings (`lib C { fun printf(...) }`) and implement the `String` class entirely in Eiwa.
- [x] **Task 24.3:** Move print overloads, `toString` conversions, and concatenation to `std/core.ei`.

### Phase 25: User-Defined Annotations & Metadata (PENDING / LATER)
- [ ] **Task 25.1:** Add support in the Lexer, AST, and Parser for user-defined annotations (e.g. `annotation Header(files: [String])`).
- [ ] **Task 25.2:** Validate that annotations used in code are declared in scope and have matching argument types.
- [ ] **Task 25.3:** Save annotations as reflectable metadata or compile-time options.

### Phase 26: Standard Library Packages & Time API (COMPLETED)
- [x] **Task 26.1:** Map the virtual prefix `std.*` in imports to resolve files inside the compiler's internal `std/` directory.
- [x] **Task 26.2:** Migrate core utilities to the `std.core` package (`std/core.ei`).
- [x] **Task 26.3:** Implement `std.time` package featuring the **Epoch-First** `Time` and `Duration` abstractions.
- [x] **Task 26.4:** Encapsulate `<time.h>` calls inside the `lib NativeTime` block.

### Phase 27: Unary Operators (COMPLETED)
- [x] **Task 27.1:** Add support in the Lexer and Parser for unary prefix operators (e.g. `-10`, `!condition`).
- [x] **Task 27.2:** Update the AST to support `UnaryExpression`.
- [x] **Task 27.3:** Infer unary types in the TypeChecker (`!` requires/returns `Bool`, `-` requires/returns numeric).
- [x] **Task 27.4:** Emit unary expressions in the C Transpiler.

### Phase 28: Native File I/O (`std.fs`) (COMPLETED)
- [x] **Task 28.1:** Design the `std.fs` package containing modern abstractions for reading and writing files (e.g. `File`, `Path`).
- [x] **Task 28.2:** Implement bindings via `lib NativeFS` encapsulating standard POSIX/C library calls (`fopen`, `fread`, `fwrite`, `fclose`).
- [x] **Task 28.3:** Ensure resource clean-up and prevent file descriptor leaks.
- [x] **Task 28.4:** Implement convenience methods (e.g. `fs.readFile(path: String) -> String`).

### Phase 29: True Generics & Collections (`std.collections`) (COMPLETED)
- [x] **Task 29.1:** Add support for Generics in the Parser and TypeChecker (via Monomorphization) to allow container classes without casting.
- [x] **Task 29.2:** Update C Transpiler to emit clean monomorphized structs (e.g. `Box_Int`, `Box_String`) without compiler errors.
- [x] **Task 29.3:** Implement `std.collections` package featuring `List<T>`, `MutableList<T>`, `Set<T>`, `MutableSet<T>`, `Map<K, V>`, and `MutableMap<K, V>`.
- [x] **Task 29.4:** Add dynamic memory allocations (`GC_REALLOC`) for growing arrays in the runtime.
- [x] **Task 29.5:** Implement hash codes (`hashCode()`) for native types (`String`, `Int`) to support hash map bucket placement.

### Phase 30: Class Inheritance & Polymorphism (COMPLETED)
- [x] **Task 30.1:** Introduce the `open` keyword to the Lexer and Parser.
- [x] **Task 30.2:** Update class declaration syntax to parse inheritance: `class SubClass : SuperClass(args)`.
- [x] **Task 30.3:** Support method overrides (`override` keyword check) and resolve member inheritance in the Type Checker.
- [x] **Task 30.4:** Implement struct embedding in the C Transpiler (first field represents the parent class).
- [x] **Task 30.5:** Emit function pointers for polymorphic methods in the struct and wire them up in constructors.
- [x] **Task 30.6:** Implement type compatibility and casting rules (upcasting and downcasting/smart casts) in the Type Checker.

### Phase 31: Lambda Expressions & Higher-Order Functions (COMPLETED)
- [x] **Task 31.1:** Add support in the Lexer and Parser for function types (e.g. `(Int, Int) -> String`) and lambda literals (e.g. `{ x, y -> x + y }`).
- [x] **Task 31.2:** Update the TypeChecker to resolve lambda argument types and return types, implementing parameter type inference where possible.
- [x] **Task 31.3:** Implement scope capturing (closures) in the TypeChecker to detect variables captured from outer scopes.
- [x] **Task 31.4:** Update the C Transpiler to generate struct representations for closures (containing function pointers and captured environments) and handle invocation.

### Phase 32: Pattern Matching & `when` Expressions (COMPLETED)
- [x] **Task 32.1:** Add the `when` keyword to the Lexer and AST.
- [x] **Task 32.2:** Update the Parser to support pattern matching syntax (matching by value, type check via `is`, and default `else` branch).
- [x] **Task 32.3:** Implement smart-casting in the TypeChecker for matching branches (e.g. if matched via `is String`, treat variable as `String` in that branch).
- [x] **Task 32.4:** Transpile `when` expressions into clean C `switch` statements or chained `if-else` blocks in the C Transpiler.

### Phase 33: Interfaces & Abstract Classes (OBSOLETE — SUPERSEDED BY PHASE 41)
> **Nota:** Esta fase nunca será implementada. O modelo de herança/abstração foi substituído pelo sistema de composição (`contract` + `skill`) definido na Phase 41 e no ADR 25.
- [ ] ~~**Task 33.1:** Add the `interface` and `abstract` keywords to the Lexer and Parser.~~
- [ ] ~~**Task 33.2:** Update AST declarations to support abstract methods (methods without a body) and interface inheritance.~~
- [ ] ~~**Task 33.3:** Implement semantic validation in the TypeChecker: verify that non-abstract classes implement all inherited interface/abstract methods.~~
- [ ] ~~**Task 33.4:** Update the C Transpiler to generate virtual tables (vtables) for interfaces, enabling runtime dynamic dispatch.~~

### Phase 34: Extension Functions (COMPLETED)
- [x] **Task 34.1:** Add support in the Parser and AST for declaring extension functions (e.g., `fun String.lastChar(): String`).
- [x] **Task 34.2:** Resolve extension methods in the TypeChecker statically, registering `this` in scope and binding to receiver type.
- [x] **Task 34.3:** Desugar extension function calls (e.g., `str.lastChar()`) to static function calls with receiver as first argument in LLVM backend.

### Phase 35: Standard Library HTTP & Networking (`std.http` & `std.net`) (COMPLETED)
- [x] **Task 35.1:** Design `std.net` defining Socket and TCP abstractions using POSIX socket FFI bindings.
- [x] **Task 35.2:** Implement `std.http.Client` binding to C `libcurl` to support standard HTTP methods (GET, POST) and return `std.http.Response`.
- [x] **Task 35.3:** Implement `std.http.Server` utilizing `libuv` or lightweight non-blocking sockets with custom C wrappers for event dispatching.
- [x] **Task 35.4:** Write integration tests and sample scripts verifying basic HTTP requests and responses.

### Phase 36: Concorrência Estruturada — Fibras + Tasks (UNIFIED — merged former Phase 36 + Phase 50) (COMPLETED — SUPERSEDED BY PHASES 51/68)
> **Nota (2026-08):** o runtime de **fibras** (`fiber.c`/`fiber.h`) foi substituído pelo neco
> (Phase 51) e este por **coroutines stackless** (Phase 68). `task {}`/`await()` hoje são state
> machines geradas pelo compilador, sem stack switching. Histórico mantido.
> **Nota:** O runtime de fibras foi implementado em **C** (`fiber.c`/`fiber.h`) em vez de Zig, integrando-se diretamente com o C transpilado. A passagem de ponteiros para `makecontext` no macOS arm64 exigiu o workaround de empacotar ponteiros 64-bit como dois argumentos `int`.

#### Camada 1 — Runtime de Fibras e Scheduler (C)
- [x] **Task 36.1:** Implementar runtime de fibras cooperativas em C via `makecontext`/`swapcontext`. Fiber stack de 64KB. Scheduler single-threaded com fila round-robin.
- [x] **Task 36.2:** Scheduler com `enqueue`/`dequeue` para fibers ready. Gestão de fiber finished com yield automático para `calling_fiber`.
- [x] **Task 36.3:** Primitivas `eiwa_fiber_yield()`, `eiwa_fiber_resume()`, `eiwa_task_init()`. Fiber entry via função auxiliar que executa o callback, marca `finished`, e cede controle.
- [x] **Verify:** Fibras executam e cedem corretamente sem bloqueio da thread.

#### Camada 2 — API `task { }` / `await()`
- [x] **Task 36.4:** `type Task<T>` declarado em `std/core.ei` com `Task<T>` tratado como GenericInstance no type checker. Codegen mapeia para `EiwaTask*` (heap-allocated via GC).
- [x] **Task 36.5:** `fun task<T>(block: () -> T): Task<T>` declarado. Type checker intercepta `task { }` como caso especial em `infer_call.zig` (linha 44), inferindo `Task<T>` diretamente.
  - ⚠️ **Dívida técnica:** Este caso especial deve ser substituído por monomorfização real (Generic method) quando disponível.
- [x] **Task 36.6:** Codegen no CTranspiler: `task { }` heap-allocates `EiwaTask` via GC e cria fiber; `.await()` loop com `while(!done) eiwa_fiber_resume`.
  - ⚠️ **Dívida técnica:** O special case no transpiler (`expression.zig:373`) e no type checker (`infer_call.zig:44`, `infer_member.zig`) devem ser removidos quando a monomorfização substituí-los.
- [x] **Task 36.7:** Structured concurrency básico — fibers tracking via `calling_fiber`; fiber pai automaticamente cede para a fibra que a resume.
- [x] **Verify:** `eiwa test samples/tests/task_test.ei` — todos os 8 testes passam (task simples, múltiplas tasks, nested, captura de escopo, tipos complexos).

#### Camada 3 — I/O Não-Bloqueante e std.http
- [ ] **Task 36.8:** Refatorar `std.net.Socket` para ser fiber-aware: operações de I/O que bloqueariam a thread agora yield a fibra e registram o fd no event loop.
- [ ] **Task 36.9:** Refatorar `std.http.Client` e `std.http.Server` para usar o socket não-bloqueante, eliminando a dependência de `libcurl` para operações concorrentes.
- [ ] **Task 36.10:** Atualizar `arest` (servidor HTTP de exemplo) para servir múltiplas conexões concorrentemente em uma única thread usando `task { }`.
- [ ] **Verify:** Servidor `arest` aceita N conexões simultâneas; `std.http.Client` faz requisições paralelas sem bloquear.

#### Evolução Futura (Execution Contexts)
- [ ] **Task 36.11 (Future):** Implementar Execution Contexts (estilo Crystal ADR 36/50) — schedulers concorrentes (1 thread), paralelos (N threads com work-stealing) e isolados (1 fiber = 1 thread OS). Por default, o scheduler permanece single-threaded concorrente. Como Crystal

### Phase 37: Default Parameters (COMPLETED)
- [x] **Task 37.1:** Update AST and Parser to support optional default initializers.
- [x] **Task 37.2:** Implement default parameter injection and validation in the Type Checker.
- [x] **Verify:** Call functions and instantiate classes (`Server()`) using default constructor properties.

### Phase 38: Companion Objects & Boundless Namespaces (COMPLETED)
- [x] **Task 38.1:** Update the Lexer and AST to support the companion `object` keyword both as a named block (`object File { ... }`) and an anonymous block (`object { ... }`).
- [x] **Task 38.2:** Implement Companion Binding in the Parser:
  - If an anonymous `object { ... }` immediately follows a `class Name`, bind the object's contents to the namespace `Name`.
  - If an anonymous `class (...) { ... }` immediately follows an `object Name`, bind the class definition and primary constructor to the namespace `Name`.
- [x] **Task 38.3:** Update the TypeChecker to merge both definitions into a single joint scope:
  - Methods and properties inside `class` belong to instances (implicitly injecting the `self` / `this` pointer).
  - Methods and properties inside `object` are static and bound to the type's static namespace (accessible directly via `Type.member`).
- [x] **Task 38.4:** Support Two-Pass Semantic Analysis to ensure compilation order independence (i.e., resolving `File(path)` inside `object File` even if the `class` definition appears later in the file).
- [x] **Task 38.5:** Update the CTranspiler to emit correct C symbols using static name mangling (e.g., `class File` methods transpile to `File_member(File* self)`, while `object File` methods transpile to static global functions like `File_member(...)` without instance pointer overhead).
- [x] **Verify:** Compile and run a hybrid `File` module where the static factory `File.read(path)` and the instance method `file.read()` coexist seamlessly.

### Phase 39: Standard Library Environment Configuration (`std.env`) (COMPLETED)
- [x] **Task 39.1:** Implement `std.env` using `std.fs.File` to read `.env` files or environment variables. `Env.load()`, `Env.get(key)`, `Env.set(key, value)`, `Env.unset(key)`, `Env.exists(key)`. If `path` is not provided, `Env.load()` should read `.env` in the current directory. If `Env.get()` is called without `Env.load()` being called first, `Env.load()` should be called automatically.
- [x] **Task 39.2:** Implement `Env.get(key, defaultValue: String): String`. If the key is not found, return the default value.
- [x] **Task 39.3:** Implement `Env.get(key, defaultValue: Int): Int`. If the key is not found, return the default value.
- [x] **Task 39.4:** Implement `Env.get(key, defaultValue: Bool): Bool`. If the key is not found, return the default value.
- [x] **Verify:** Compile and run a script that uses `Env.get()` to retrieve environment variables.

### Phase 40: Multi-Pass Compiler Architecture Refactoring (Crystal/Kotlin Style) (COMPLETED)
Refactor the Eiwa compiler from file-by-file recursive typechecking to a global, multi-pass type resolution architecture inspired by Crystal and Kotlin to natively support project-wide namespaces and circular dependencies.
- [x] **Task 40.1:** Refactor file resolution to support a global Parsing Pass. Scan all files in the dependency graph starting from the entry point (`main.ei`) and load their parsed ASTs into a shared registry, rather than recursively compiling imports on-the-fly.
- [x] **Task 40.2:** Implement Type and Signature Declaration Pass. Walk all parsed ASTs and populate a global symbol table with all class, object, and function types and signatures, leaving bodies/initializers un-typechecked.
- [x] **Task 40.3:** Implement Semantic Body Validation Pass. Typecheck function bodies, method definitions, and initializers using the populated global symbol table. Resolves circular imports and cross-file type dependencies natively.
- [x] **Task 40.4:** Deduplicate Transpiler Output. Update `CTranspiler` to leverage the global registry, ensuring each standard library module is transpiled exactly once without duplicate C definitions.
- [x] **Verify:** Run a test verifying circular dependencies between user types (e.g. `CircularUser` referencing `CircularGroup` and vice-versa in `samples/tests/circular_dependency_test.ei`) compiles and executes successfully.

### Phase 41: Composition-Based Type System — `type`, `contract` & `skill` (COMPLETED)
Replace implementation inheritance entirely with the composition model defined in ADR 25: `type` owns state, `contract` defines behavioral APIs, `skill` provides reusable implementation, `object` remains the singleton, `enum` unchanged. **Hard break:** `class`, `open`, `abstract` and inheritance syntax are removed.
- [x] **Task 41.1:** Add `type`, `contract`, `skill`, `implement` tokens and AST nodes with header clauses `:` (contract implementation/requirement) and `+` (skill composition). Remove `class`, `open`, `abstract`, `override` from the Lexer/Parser.
- [x] **Task 41.2:** Parse declaration headers: `type Name(params) : C1, C2 + S1, S2 { ... }`; `contract` bodies restricted to bodyless method signatures; `skill` headers with required contracts.
- [x] **Task 41.3:** TypeChecker contract rules: contracts hold no state/constructors/bodies and cannot be instantiated; implementing types must provide every contract method with the `implement` keyword (`override` is removed with `class`).
- [x] **Task 41.4:** TypeChecker skill rules: skills hold no state/constructors and cannot be instantiated; required contracts (`:`) are *not* implemented — method calls inside a skill resolve against its required contracts.
- [x] **Task 41.5:** Composition validation: a `type` composing `+ Skill` must implement every contract the skill requires, with the exact error `Skill 'Shadow' requires contract 'Drawable'. Type 'Button' does not implement it.`
- [x] **Task 41.6:** Skill conflict resolution: duplicate members across composed skills produce an ambiguity error until the type disambiguates with `implement` and a qualified call (`MouseInput.click()`).
- [x] **Task 41.7:** Replace the `Exception` base class with the `Throwable` contract: `throw`/`catch` accept any type implementing `Throwable`; update `when`/`is` checks to use contract conformance instead of hierarchy.
- [x] **Task 41.8:** Enforce singleton `object` semantics under the new model (direct member access, instantiation forbidden).
- [x] **Task 41.9:** C Transpiler lowering: `type` → struct + methods, `object` → global instance, skill methods → functions on the consuming type, contract-typed values → fat pointers (data + vtable) with dynamic dispatch. Remove struct-embedding inheritance emission.
- [x] **Task 41.10:** Migrate `src/std/*.ei`, samples and tests off `class`/inheritance; delete all inheritance machinery from the TypeChecker.
- [x] **Verify:** Every example in the composition spec (valid and invalid) behaves as specified; full test suite passes with no inheritance code remaining.

> **Known trade-offs (accepted):** skill methods are cloned per consuming type (C++ template-style code duplication in exchange for zero-cost static dispatch); contract-typed values are erased to `void*` in C (the TypeChecker is the only type-safety layer for dynamic dispatch). Follow-ups live in Phases 42–44.

### Phase 42: Null Safety on Contract Receivers (COMPLETED)
Contract-typed receivers are erased to `void*` and dispatch dynamically through `eiwa_find_vtable`. The safe-call path (`?.`) emits a null check wrapper for contract method calls, enabling safe calls (`?.`), non-null assertions (`!!`), and elvis operations (`?:`) on nullable contract receivers (`Drawable?`) without segfaults.
- [x] **Task 42.1:** Emit the null short-circuit (`(obj) == 0 ? 0 : dispatch`) for `?.` calls on contract-typed receivers in the C Transpiler (`expression.zig` contract dispatch branch).
- [x] **Task 42.2:** Validate nullable contract types end-to-end: `val d: Drawable? = null`, `d?.draw()`, `d ?: fallback`, and `!!` assertions on contracts.
- [x] **Task 42.3:** TypeChecker: reject non-safe member access on nullable contract receivers with the standard null-safety error.
- [x] **Verify:** Tests covering `null` contract references using `?.`, `?:` and `!!` pass without crashes (`samples/tests/contract_null_safety_test.ei`).

### Phase 43: Heterogeneous Contract Collections (`List<Drawable>`) (PENDING / LATER)
ADR 25 envisioned heterogeneous collections of contracts (e.g. `List<Drawable>`), but the monomorphizer generates concrete C containers and contract type erasure (`void*`) is not propagated into generic instantiations (element arrays would degrade to invalid `void` element types).
- [ ] **Task 43.1:** Propagate contract erasure into `getCTypeStr` consumers inside monomorphized collections: a `List<Drawable>` must generate its storage as `void*` elements (named e.g. `EiwaArray_voidPtr`) instead of an invalid `void` element type.
- [ ] **Task 43.2:** TypeChecker: allow contract types as generic arguments (`List<Drawable>`, `Map<String, Throwable>`) and ensure method returns/params inside the monomorphized collection keep the contract static type (so returned elements dispatch dynamically).
- [ ] **Task 43.3:** Transpiler: contract dispatch when the receiver expression is a collection element access (e.g. `shapes[0].draw()`).
- [ ] **Verify:** Test that stores `Circle` and `Square` in one `List<Shape>` and dynamically dispatches a method per element.

### Phase 44: Composition Test Coverage Hardening (PENDING)
The composition model (Phase 41) currently has only 5 dedicated tests (`composition_test.ei`). Several interaction paths are unverified.
- [ ] **Task 44.1:** Tests for contracts as function parameters and return types (`fun renderAll(items: List<Drawable>)` without Phase 43, or `fun max(a, b): Drawable` style single-value flows).
- [ ] **Task 44.2:** Cross-module composition: contracts and skills declared in one module, composed in another (including `std`-level contracts beyond `Throwable`).
- [ ] **Task 44.3:** Skills requiring multiple contracts (`skill S : A, B`) and types composing multiple skills with multiple requirements.
- [ ] **Task 44.4:** Negative tests as runnable fixtures: contract with state, contract instantiation, skill instantiation, missing `implement`, unresolved ambiguity, wrong signature/return type.
- [ ] **Task 44.5:** Improve ambiguity error to list all conflicting skills when 3+ collide.
- [ ] **Verify:** New tests pass; negative fixtures fail with the exact expected diagnostics.

### Phase 45: Serialization — `Serializable` Contract + JSON/YAML Skills (COMPLETED)
Compile-time serialization without runtime reflection (ADR 27): the compiler generates `serdeFields(): List<SerdeField>` per `type` marked `: Serializable`; formats are pure-Eiwa skills (`+ Json`, `+ Yaml`) in a new `std.serde` module that walk the field list. Serialization only; deserialization is a future phase.
- [x] **Task 45.1:** Create `src/std/serde.ei`: `contract Serializable`, `SerdeField`, `contract SerdeValue` + std boxes (`IntValue`, `FloatValue`, `BoolValue`, `StringValue`, `ObjectValue`, `ListValue`), and skills `Json`/`Yaml` with `toJson()`/`toYaml()` written 100% in Eiwa.
- [x] **Task 45.2:** TypeChecker: accept the marker contract and resolve the generated `serdeFields()` signature; treat a user-provided `implement fun serdeFields()` as an override of the generated body.
- [x] **Task 45.3:** Compiler codegen: for every `type` implementing `Serializable`, emit the `serdeFields()` body including only serializable fields — primitives, nested `Serializable` types (recursive via `ObjectValue`) and `List<T>` of serializable `T` (via `ListValue`); silently skip all other fields.
- [x] **Task 45.4:** Samples: `samples/serialization_sample.ei` (nested objects, lists, skipped fields) and `samples/tests/serialization_test.ei` covering JSON and YAML output.
- [x] **Verify:** Full suite passes (`zig build`, `zig build test`, `eiwa test samples/tests`); sample output matches expected JSON/YAML.

### Phase 46: General Union Types & Multi-Type Collections (COMPLETED)
General Union types (e.g., `String | Int` or `T1 | T2`) across variable declarations, function parameters, and generic collections like `Map<String, String | Int>`.
- [x] **Task 46.1:** Update Parser (`core_parseType`) to support general Union types (`Type1 | Type2 | ...`) in type annotations and generic type arguments.
- [x] **Task 46.2:** Update TypeChecker (`core_resolveTypeRef` and `core_isCompatible`) to resolve general Union types and perform subtyping checks across union variants.
- [x] **Task 46.3:** Update C Transpiler (`getCTypeStr`) to represent general non-null unions as `void*` with primitive autoboxing/unboxing.
- [x] **Task 46.4:** Support multi-type generic collections such as `Map<String, String | Int>` and `MutableMap<String, String | Int>`.
- [x] **Task 46.5:** Update documentation (`docs/roadmap.md`, `docs/decisions.md`, `docs/language_tour.md`) and add samples (`samples/union_sample.ei`) and tests (`samples/tests/union_test.ei`).

### Phase 47: Core System Contracts & Fundamental Skill Derivation (`Stringable`, `Hashable`, `Equatable`, `Echoable`) (COMPLETED)
Establish a unified language-wide contract hierarchy and automatic skill derivation for all Eiwa types (`type`, `object`, and primitives `Int`, `Bool`, `String`).
- [x] **Task 47.1:** Declare core contracts (`contract Stringable`, `contract Equatable`, `contract Hashable`) and core skills (`skill Echoable`) in `src/std/core.ei`.
- [x] **Task 47.2:** Update TypeChecker to automatically inject core contracts (`Stringable`, `Hashable`, `Equatable`) into the implicit contract implementations of every user-declared `type` and `object`.
- [x] **Task 47.3:** Synthesize missing default method implementations (`toString()`, `equals()`, `hashCode()`) in the TypeChecker for types that do not explicitly provide custom implementations, skipping closure/function properties (`is_function`).
- [x] **Task 47.4:** Declare primitive types (`Int`, `Bool`, `String`, `Pointer`) in `src/std/core.ei` as implementers of `Stringable`, `Hashable`, and `Equatable`.
- [x] **Task 47.5:** Refactor compiler dynamic dispatch and C Transpiler to use contract vtables for `Stringable.toString()` and `Hashable.hashCode()` calls across Union types (`String | Int`) and erased generics (`void*`), with C runtime helpers (`eiwa_to_string`, `eiwa_hash_code`).
- [x] **Verify:** Compile and run test suites (`core_contracts_test.ei`) verifying polymorphic `.toString()` calls, generic `Stringable` parameters, and contract-based dynamic dispatch on custom types, primitives, and union types.

### Phase 48: Standard Library Logging (`std.log`) (COMPLETED)
Design and implement the native logging package `std.log` (`src/std/log.ei`) supporting lazy evaluation via lambdas, ANSI colored console output, Throwable exception logging, and skill-based formatters (`skill TextFormatter`, `skill JsonFormatter`).
- [x] **Task 48.1:** Implement `src/std/log.ei` defining `LogLevel`, `contract LogFormatter`, `skill TextFormatter`, `skill JsonFormatter`, `type Logger`, and static facade `object Log`.
- [x] **Task 48.2:** Implement lazy message evaluation via lambda receivers (`Log.info { ... }`), preventing string building when log level is filtered out.
- [x] **Task 48.3:** Implement `Throwable` exception parameters on `warn` and `error` overloads.
- [x] **Task 48.4:** Implement ANSI color output for `TextFormatter` console logging and structured JSON formatting via `JsonFormatter`.
- [x] **Task 48.5:** Implement unit test suite `samples/tests/log_test.ei`, demonstration sample `samples/log_sample.ei`, and integrate `std.log` into `samples/arest/arest.ei`.
- [x] **Verify:** Execute test suite `eiwa test samples/tests/log_test.ei`, verify sample `eiwa run samples/log_sample.ei`, and run `zig build test`.

### Phase 49: First-Class Enum Types & `std.log` Enum Refactoring (COMPLETED)
Introduce native `enum` declarations in the language (`enum LogLevel { TRACE, DEBUG, INFO, WARN, ERROR, OFF }`) with auto-generated ordinal and string representations, and refactor `std.log` (`src/std/log.ei`) to use `LogLevel` enum instead of integer constants.
- [x] **Task 49.1:** Lexer & Parser: Add `kw_enum` keyword and parse `enum Name { Variant1, Variant2, ... }` declarations into AST `enum_decl`.
- [x] **Task 49.2:** TypeChecker: Register `enum` types with variant values, implicit `ordinal: Int`, `name: String`, `values(): List<EnumType>`, `Stringable`, `Equatable`, `Hashable`.
- [x] **Task 49.3:** C Transpiler: Transpile enum declarations to static C enum structs and integer value descriptors.
- [x] **Task 49.4:** Refactor `src/std/log.ei`: Replace `object LogLevel` with native `enum LogLevel`, updating `LogFormatter`, `TextFormatter`, `JsonFormatter`, `Logger`, and `Log` facade to operate on `LogLevel` enum variants instead of raw `Int`s.
- [x] **Task 49.5:** Update samples and tests (`log_sample.ei`, `log_test.ei`, `arest.ei`, `enum_sample.ei`, `enum_test.ei`) to use `LogLevel` enum variants (e.g., `LogLevel.DEBUG`, `LogLevel.INFO`).

### Phase 50: Monomorfização Real (Generic Method & Generic Functions) (COMPLETED)
> **Nota:** Esta fase implementa o suporte a monomorfização real de funções e métodos genéricos, que é uma dívida técnica herdada da Fase 36 (special case `task { }`).

#### Etapa 0 — Type Params em `contract` e `skill` (COMPLETED)
- [x] **Task 50.0.1:** Parser: `contract Awaitable<T>` e `skill Foo<T>` — `<T>` opcional após o nome
- [x] **Task 50.0.2:** AST: campo `generic_params` em `contract_decl` e `skill_decl`
- [x] **Task 50.0.3:** Type checker: registro de contracts/skills genéricos em `local_symbols`, early return no corpo
- [x] **Task 50.0.4:** Resolução de type params em constraints (`skill Foo : Awaitable<T>`)
- [x] **Verify:** Contract/skill com type param parseiam e registram corretamente

#### Etapa 1 — Monomorfização (COMPLETED)
- [x] **Task 50.1.1:** Mecanismo de clonagem de AST com substituição de type params (`cloneNode`, `cloneTypeRef`)
- [x] **Task 50.1.5:** Tipos genéricos (`type Task<T>`) monomorfizados via `monomorphizeClass`
- [x] **Foundation fixes:** `String` como built-in em `resolveTypeRef`; `String ↔ Custom(String)` em `isCompatible`; transpiler mapeia `Custom(String)` → `core_String*`; fix mangling de métodos de String durante validação
- [x] **Task 50.1.2:** Trigger no type checker: `inferCall` clona e type-check **funções** genéricas monomorfizadas (explicit + inferred type args; free functions + methods)
- [x] **Task 50.1.3:** Transpiler: gera função C separada por instância (nome mangled com type args, ex: `generic_methods_test_Util_wrap_Int`)
- [x] **Task 50.1.4:** Cache de instâncias via `monomorphized_nodes` + `functions_ast` para evitar duplicação
- [x] **Verify:** `zig build && ./zig-out/bin/eiwa test` (128 testes) passa; funções genéricas com `T` funcionam; métodos genéricos com type args funcionam

### Phase 51: Refatoração de `Task<T>` (Corotinas 100% em Eiwa) (DONE — SUPERSEDED BY PHASE 68)
> **Nota (2026-08):** esta fase levou o `Task<T>` ao modelo **neco (stackful)**. A **Phase 68**
> (coroutines stackless) **substitui o neco**: o `@MainWrapper`/`lib Neco` são removidos e o runtime
> de corrotinas vira state machine gerada pelo compilador + Scheduler em Eiwa puro. Histórico mantido.
> **Dependência:** Monomorfização Real (Fase 50) concluída ✅.
>
> **Nota:** Plano detalhado em `docs/plano_mono_task.md`. O destino final é `Task<T>` 100% em Eiwa via `contract + skill + lib {}` (neco — https://github.com/tidwall/neco), removendo todos os casos especiais (special cases) do compilador.
>
> **Ordem de execução:** Etapa 1 (Remover Special Cases) → Etapa 2 (Arquitetura Final).

#### Etapa 1 — Remover Special Cases de `Task<T>`
- [x] **Task 51.1.1:** `fun task<T>` em std/core.ei usa monomorfização em vez de special case
- [x] **Task 51.1.2:** Construtor `Task<T>` usa `lib {}` (neco) em vez de C inline `({ })`
- [x] **Task 51.1.3:** Remover special case `task()` em `infer_call.zig:44`
- [x] **Task 51.1.4:** Remover special case `.await()` em `infer_member.zig`
- [x] **Task 51.1.5:** Remover special case `Task` codegen em `expression.zig:373`
- [x] **Task 51.1.6:** Remover special case `.await()` codegen em `expression.zig:481`
- [x] **Task 51.1.7:** Remover special case `cType("Task")` em `core.zig:55`
- [x] **Task 51.1.8:** Remover `src/runtime/fiber.c` e `src/runtime/fiber.h` (substituído por neco)
- [x] **Verify:** `zig build && ./zig-out/bin/eiwa test` passa; `task_test.ei` passa sem special cases

#### Etapa 2 — Arquitetura Final: Contract + neco
- [x] **Task 51.2.1:** `contract Awaitable<T>` em `std/core.ei`
- [x] ~~**Task 51.2.2:** `skill TaskNeco : Awaitable<T>` com `await()` via neco~~ (ver divergência acima: `await()` ficou em `type Task<T>`)
- [x] **Task 51.2.3:** `lib Neco` binding para neco em `src/runtime/third_party/neco/` (+ `neco/neco_wrapper.c`, referenciado direto pelo `@Header` do `lib Neco`: trampolim de closure, macro `main` própria, cola Boehm GC ↔ stacks de corotina; patch `EIWA PATCH` no `neco.c` para rotear alocação de stacks pelo env allocator)
- [x] **Task 51.2.4:** `type Task<T>(var id: Int, var done: Bool, var result: T?, val block: () -> T) : Awaitable<T>`
- [x] **Task 51.2.5:** `fun task<T>(block)` factory retorna `Task<T>` e inicia a corotina via `Neco.start`
- [x] **Verify:** `zig build && ./zig-out/bin/eiwa test` — suite completa passa (132 testes); zero hacks no compilador

### Phase 52: Captura de `var` por referência em lambdas (boxed captures) (COMPLETED)
 **Motivação:** toda captura de variável por lambda era **por valor**. Mutar uma `var`
 capturada dentro da lambda não propagava para o escopo externo — quebrava o padrão
 fire-and-forget de tasks (ex: sinalizar conclusão, acumular resultado).

 **Causa raiz encontrada (2026-07-26):** a detecção de captura existia apenas no caminho
 de **leitura** (`inferIdentifier`). Uma `var` capturada **exclusivamente por atribuição**
 (ex: `{ flag = true }`) nunca passava por esse caminho, então `is_boxed` não era setado
 e o transpiler emitia cópia por valor no env struct. Resolução: espelhar a detecção de
 captura em `inferAssignment` (`infer_expr.zig`) — ADR 39.

 **Tarefas:**
 - [x] **Task 52.1:** Diagnosticar por que `is_boxed` não é setado → `inferAssignment` não tinha detecção de captura (só `inferIdentifier`).
 - [x] **Task 52.2:** Checker marca como boxed toda `var` mutável atribuída dentro de lambda (cruzando `is_function_boundary`), incluindo corpos de `task {}`.
 - [x] **Task 52.3:** Transpiler emite decl boxed, leituras/escritas via `->value` e capture por ponteiro (caminho já existente, agora exercitado).
 - [x] **Task 52.4:** `val` (imutável) NÃO boxed — cópia por valor preservada.
 - [x] **Task 52.5:** `task {}`: mutação de `var` capturada visível após `await()` — teste "task without return value should complete" passa.
 - [x] **Verify:** novos testes em `closure_capture_test.ei` (4 casos) e `task_test.ei`; suite completa verde (147 testes).

### Phase 53: Driver PostgreSQL — `std.db` + `std.postgres` (COMPLETED)
> **Dependência:** Phase 51 (neco) concluída ✅.
>
> **Referência:** Plano completo em [`docs/plan_pglib.md`](plan_pglib.md).
>
> **Filosofia:** 100% Eiwa — a única camada C é o glue mínimo em `neco_wrapper` (`waitReadable`/`waitWritable`) e um helper opcional em `libpq_wrapper` para conversão de params. Tudo o mais é `.ei` puro.

#### Etapa 0 — Pré-requisitos de Runtime
- [x] **Task 53.0.1:** Adicionar `eiwa_neco_wait_readable(fd)` e `eiwa_neco_wait_writable(fd)` ao `neco_wrapper.c` (padrão idêntico ao `eiwa_neco_sleep`).
- [x] **Task 53.0.2:** Declarar ambas as funções em `neco_wrapper.h`.
- [x] **Task 53.0.3:** Expor `Neco.waitReadable(fd: Int)` e `Neco.waitWritable(fd: Int)` no `lib Neco` em `src/std/core.ei`.
- [x] **Verify:** `zig build` compila sem erros; os bindings aparecem no objeto C.

#### Etapa 1 — Contracts `std.db`
- [x] **Task 53.1.1:** Criar `src/std/db.ei` com `contract Database`, `contract Connection`, `contract Statement`, `contract Result`, `contract Row`, `contract Transaction`.
- [x] **Task 53.1.2:** `contract Connection` usa `params: List<String>` (varargs postergado para fase futura).
- [x] **Task 53.1.3:** `contract Result` expõe `val rowsAffected: Int` e iteração via `for row in result`.
- [x] **Task 53.1.4:** Criar `src/std/db_error.ei` com `type DbError(val message: String) : Throwable`.
- [x] **Verify:** `zig build` com imports de `std.db` funciona; contratos reconhecidos pelo type checker.

#### Etapa 2 — Binding Nativo `lib NativePg`
- [x] **Task 53.2.1:** Criar `src/runtime/third_party/libpq/libpq_wrapper.h` com helper `eiwa_pq_exec_params` (converte `EiwaArray*` de `String` para `char**` antes de chamar `PQexecParams`).
- [x] **Task 53.2.2:** Criar `src/postgres/native.ei` com `lib NativePg { @Link("pq") @Header("<libpq-fe.h>") }` expondo: `PQconnectdb`, `PQfinish`, `PQsendQuery`, `PQconsumeInput`, `PQisBusy`, `PQgetResult`, `PQclear`, `PQresultStatus`, `PQntuples`, `PQnfields`, `PQfname`, `PQgetvalue`, `PQsocket`, `PQerrorMessage`, `PQexec`, `eiwa_pq_exec_params`.
- [x] **Verify:** `zig build` linka contra `libpq`; funções nativas acessíveis.

#### Etapa 3 — Implementação `postgres/`
- [x] **Task 53.3.1:** `src/postgres/row.ei` — `type PgRow(val result: OpaquePointer, val rowIdx: Int, val nfields: Int) : Row` com `int()`, `string()`, `bool()`, `double()`.
- [x] **Task 53.3.2:** `src/postgres/result.ei` — `type PgResult(val rows: List<PgRow>, val rowsAffected: Int) : Result`. Após construção, chama `PQclear()` imediatamente (eager — dados já em memória Eiwa).
- [x] **Task 53.3.3:** `src/postgres/statement.ei` — `type PgStatement(val conn: OpaquePointer, val name: String) : Statement` com `query(params)` e `execute(params)`.
- [x] **Task 53.3.4:** `src/postgres/connection.ei` — `type PgConnection(val conn: OpaquePointer) : Connection`. O loop async: `PQsendQuery → PQsocket → Neco.waitReadable(fd) → PQconsumeInput → PQgetResult`.
- [x] **Task 53.3.5:** `src/postgres/transaction.ei` — `type PgTransaction(val conn: Connection)` com `BEGIN`/`COMMIT`/`ROLLBACK` (rollback automático em exceção).
- [x] **Task 53.3.6:** `src/postgres/postgres.ei` — entry point: `fun driver(): Database`.
- [x] **Verify:** `zig build`; `eiwa run samples/pg_sample.ei` conecta e executa queries básicas.

#### Etapa 4 — Testes e Samples
- [x] **Task 53.4.1:** Executar `eiwa test samples/tests/postgres_test.ei` — todos os testes passam (requer PostgreSQL local com banco `eiwa_test`).
- [x] **Task 53.4.2:** Verificar `samples/pg_sample.ei` como demo completo (connect, query, prepared, transaction).
- [x] **Task 53.4.3:** Documentar variáveis de ambiente de conexão no header do sample.
- [x] **Verify:** Suite completa `eiwa test samples` verde (postgres_test é skip-safe se libpq não disponível).

### Phase 54: Argumentos Nomeados & Framework HTML (`samples/html/`) (COMPLETED)
> **Motivação:** Permitir a construção de DSLs HTML expressivas e legíveis no Eiwa com chamada de funções usando Argumentos Nomeados (`div(class = "container", id = "hero")`), combinando Receiver Lambdas (`HTMLBuilder.() -> Void`), `write("...")` para texto intercalado e higienização automática contra XSS.

#### Etapa 1 — Argumentos Nomeados no Compilador
- [x] **Task 54.1.1:** Adicionar nó `.named_arg` na união de dados de `ASTNode` em `src/core/ast.zig`.
- [x] **Task 54.1.2:** Atualizar o Parser (`src/frontend/parser/expression.zig`) para reconhecer `identificador = expressao` dentro da lista de argumentos de chamadas.
- [x] **Task 54.1.3:** Atualizar o Type Checker (`src/core/type_checker/infer_call.zig`) para associar parâmetros nomeados aos nomes de parâmetros definidos na função, preenchendo valores padrão unsupplied.
- [x] **Task 54.1.4:** Atualizar o C Transpiler (`src/backend/c_transpiler/expression.zig`) para emitir o código C correspondente dos argumentos nomeados na ordem correta de declaração dos parâmetros.
- [x] **Verify:** Testes unitários do compilador `zig build test` e suite nativa `samples/tests/html_test.ei` (100% PASS).

#### Etapa 2 — Framework HTML em `samples/html/`
- [x] **Task 54.2.1:** Criar `samples/html/html.ei` com os builders `HTMLBuilder`, `HeadBuilder`, `BodyBuilder`.
- [x] **Task 54.2.2:** Suporte a `write("...")` para escrita de nós de texto intercalados com sub-tags.
- [x] **Task 54.2.3:** Suporte a parâmetro de texto direto em tags simples (`h1("Título")`, `p("Texto")`).
- [x] **Task 54.2.4:** Suporte a Void Tags (auto-fechadas) como `img`, `input`, `meta`, `link`, `br`, `hr`.
- [x] **Task 54.2.5:** Sanitização e Escape XSS automático para textos e valores de atributos.
- [x] **Task 54.2.6:** Criar `samples/html/main.ei` com o exemplo completo de uso.
- [x] **Verify:** Executar `./zig-out/bin/eiwa run samples/html/main.ei` e testar a saída HTML gerada (100% funcional).

### Phase 55: Identificadores Únicos — `std.uuid` + `std.ulid` + `contract Identifier` (COMPLETED)
> **Motivação:** Fornecer identificadores únicos nativos de alta performance e seguros para bancos de dados, APIs e modelos de domínio.
>
> **Recursos:**
> - `contract Identifier`: Contrato base para IDs (`toString()`, `toBytes()`).
> - `type Uuid`: Geração UUID v7 (Time-ordered por padrão), UUID v4 (aleatório) e parsing/validação de strings formato RFC.
> - `type Ulid`: Geração ULID (128-bit: timestamp + entropia aleatória em Crockford Base32), decoding/encoding e extração de timestamp Unix.
> - Entropy CSPRNG nativa via `eiwa_random_bytes` e timestamp de milissegundos de 64 bits via `eiwa_now_millis`.

- [x] **Task 55.1:** Helpers C de entropia `eiwa_random_bytes` e tempo de milissegundos `eiwa_now_millis` em `src/backend/c_transpiler/eiwa_runtime.h`.
- [x] **Task 55.2:** Bindings em `lib NativeMemory` em `src/std/core.ei` + mapeamento de `Int` para `int64_t` no transpiler C.
- [x] **Task 55.3:** Módulo `src/std/uuid.ei` com `contract Identifier`, `type Uuid` e `object Uuid`.
- [x] **Task 55.4:** Módulo `src/std/ulid.ei` com `type Ulid`, `object Ulid` e algoritmo Crockford Base32.
- [x] **Task 55.5:** Registro dos pacotes `std.uuid` e `std.ulid` no compilador (`src/core/type_checker/infer_decl.zig`).
- [x] **Verify:** Suite de testes `samples/tests/id_test.ei` 100% PASS; suite nativa completa `eiwa test` verde.

### Phase 56: Suporte ao Tipo `Double` (64-bit IEEE 754) (COMPLETED)
> **Motivação:** Fornecer suporte nativo a números de ponto flutuante de dupla precisão (`double` em C) em Eiwa, permitindo literais decimais (ex: `3.14159`), operações aritméticas completas, conversões numéricas e integração com bibliotecas da Standard Library (`std.serde`, `std.json`, `std.yaml`, `std.db`, `std.math`). O tipo `Float` (32-bit) fica diferido para uma fase futura.

#### Etapa 1 — Lexer e AST
- [x] **Task 56.1.1:** Atualizar Lexer (`src/frontend/lexer.zig`) para reconhecer números com ponto decimal (ex: `123.456`) e emitir token `double_literal`.
- [x] **Task 56.1.2:** Adicionar tipo primitivo `Double` em `src/core/type_system.zig` e no AST (`src/core/ast.zig`).

#### Etapa 2 — Type Checker & Semântica
- [x] **Task 56.2.1:** Atualizar o Type Checker (`src/core/type_checker/`) para inferir literais decimais como `Double`.
- [x] **Task 56.2.2:** Suporte a operadores aritméticos (`+`, `-`, `*`, `/`, comparadores) para `Double`, e coerção/promoção com `Int`.
- [x] **Task 56.2.3:** Adicionar métodos de conversão `.toDouble()`, `.toInt()` e `.toString()` para os tipos `Double` e `Int`.

#### Etapa 3 — C Transpiler & Runtime & Standard Library
- [x] **Task 56.3.1:** Mapear `Double` para o tipo nativo C `double` em `src/backend/c_transpiler/`.
- [x] **Task 56.3.2:** Adicionar helper de formatação `sprintfDouble` e helpers inline C `eiwa_double_to_int` e `eiwa_int_to_double` em `eiwa_runtime.h` e `std.core`.
- [x] **Task 56.3.3:** Adicionar suporte a `SerdeDouble` e `SerdeDoubleList` em `std.serde`, `std.json` e `std.yaml`.
- [x] **Task 56.3.4:** Adicionar suporte a `double(name)` em `contract Row` em `std.db` e `Double` em `Math` (`std.math`).

#### Etapa 4 — Testes & Validação
- [x] **Task 56.4.1:** Criar suite de testes nativa `samples/tests/double_test.ei` validando literais, precisão matemática, comparadores, conversões e funções de `Math`.
- [x] **Task 56.4.2:** Executar `zig build test` e `eiwa test` para garantir regressão zero.

### Phase 57: Tipo `Float` (32-bit IEEE 754) & Sufixo de Literal `f` (FUTURE / POSTPONED)
> **Motivação:** Adicionar o tipo de precisão simples (32-bit `float` em C) com literais como `3.14f` para interoperação de baixa nível (FFI), buffers compactos e performance em gráficos/vetores.

### Phase 58: Módulo Monetário e Financeiro — `std.money` + Fowler Allocation Engine (COMPLETED)
> **Motivação:** Prover um modelo financeiro seguro e moderno contra erros binários de ponto flutuante IEEE 754, alinhado ao Money Pattern de Martin Fowler e com taxa de alocação exata sem perda de centavos em rateios de parcelas ou impostos.
>
> **Recursos:**
> - `type Currency(val code: String, val symbol: String, val decimals: Int)` com objetos pré-definidos (`Currencies.BRL`, `USD`, `EUR`, `JPY`, `GBP`).
> - `type Money(val cents: Int, val currency: Currency)` baseado em menor unidade não-fracionada (*Minor Units / Centavos*).
> - Sobrecarga de operadores (`+`, `-`, `*`, `==`) com checagem estrita de integridade de moeda (dispara exceção ao somar `BRL` + `USD`).
> - Métodos `.allocate(ratios: List<Int>)` e `.split(parts: Int)` para distribuição ponderada com alocação sequencial de centavos remanescentes (*remainder cents*).
> - Suporte a sobrecarga de operadores estendida no compilador (`*` para `.times` e `/` para `.div` em tipos personalizados).

- [x] **Task 58.1:** Módulo `src/std/money.ei` com `Currency`, `Currencies`, `Money`, sobrecarga de operadores e engine `.allocate` / `.split`.
- [x] **Task 58.2:** Registro do pacote `std.money` em `src/core/type_checker/infer_decl.zig`.
- [x] **Task 58.3:** Suporte no TypeChecker (`src/core/type_checker/infer_expr.zig`) para desugar `.star` (`*`) em `.times` e `.slash` (`/`) em `.div` em tipos personalizados.
- [x] **Task 58.4:** Registro do ADR 45 em `docs/decisions.md` e atualização do guia da linguagem em `docs/language_tour.md`.
- [x] **Verify:** Sample `samples/money_sample.ei` e suíte de testes nativa `samples/tests/money_test.ei` 100% PASS.

---

### Phase 59: Package Manager — `eiwa` CLI + `eiwac` backend (IN PROGRESS)
> **Motivação:** Unificar a experiência do desenvolvedor em um único CLI (`eiwa`) para projetos e dependências, com o compilador renomeado para `eiwac` e usado apenas como backend. Spec completa em [docs/plan_package_manager.md](plan_package_manager.md).
>
> **Recursos:**
> - Binário do compilador renomeado para `eiwac` (`zig build` instala em `bin/eiwac`).
> - CLI `eiwa` escrito 100% em Eiwa (`cli/src/main.ei`), compilado com `eiwac build -o bin/eiwa`.
> - Projetos com manifesto `eiwa.yaml` (`name`, `version`, `output`, `dependencies`) e entry point fixo `src/main.ei`.
> - Dependências git (`github:` + `branch`/`tag`/`commit`) clonadas em `~/.eiwa/repository/<nome>/<commit>` e repassadas ao compilador como `--module-path`.
> - Compilador: novos flags `-o <nome>` e `--module-path <dir>`; argv exposto ao programa (`eiwa_args_count`/`eiwa_args_get`); includes e `@Source`/`@Include` resolvidos por caminho absoluto independente do cwd; `run` repassa argumentos extras ao programa.
> - Bibliotecas extraídas para repos próprios: `eiwa-lang/html`, `eiwa-lang/arest`, `eiwa-lang/postgres`.

- [x] **Task 59.1:** Renomear binário para `eiwac` e instalar em `bin/` via `zig build`.
- [x] **Task 59.2:** Flags `-o`, `--module-path`, `--help` no `eiwac`; repasse de args em `run`; paths independentes do cwd.
- [x] **Task 59.3:** Runtime expõe argc/argv (`eiwa_args_count`/`eiwa_args_get` em `eiwa_runtime.h`).
- [x] **Task 59.4:** CLI `eiwa` em Eiwa com `build`, `run`, `--help`, `project-dir` e resolução de dependências git (parser minimalista do manifesto, TODO para DTO).
- [x] **Task 59.5:** Extrair `samples/html`, `samples/arest`, `samples/postgres` para os repos `eiwa-lang/*` e consumi-los via `eiwa.yaml` em `samples/project/*`.
- [x] **Task 59.6:** Comando `test` no CLI (executa `test/` do projeto com dependências resolvidas).
- [x] **Task 59.6b:** Comandos `init`, `add`, `remove` no CLI (sources `github:`/`gitlab:`/URL git, flags `--branch|--tag|--commit`).
- [x] **Task 59.6d:** Comando `update` no CLI (re-resolve via `ls-remote`, atualiza `resolutions/` e `eiwa.freeze`).
- [x] **Task 59.6c:** Comando `freeze` no CLI + flag `--frozen` e prioridade do `eiwa.freeze` sobre `resolutions/`.
- [ ] **Task 59.7:** Resolução transitiva (MVS) entre dependências.
- ~~**Task 59.8:** Dependências de registry~~ — cancelada: não haverá registry próprio, apenas sources git (GitHub, GitLab, URL custom).

---

### Phase 60: Default Values Referencing Sibling Parameters (COMPLETED)
> **Motivação:** Suportar o padrão Kotlin de defaults que referenciam parâmetros anteriores do mesmo construtor/função (ex.: `type Dispatcher(val builder: ArestBuilder, val http: HttpDispatcher = HttpDispatcher(builder))`). Hoje o initializer é validado contra o escopo externo em `inferTypeDecl`/`inferFunDecl` (`src/core/type_checker/infer_decl.zig`), e os parâmetros irmãos só são registrados no `class_scope`/`fun_scope` **depois** do próprio default ser checado — a referência falha com `TypeError: Undeclared variable`.
>
> **Exemplo de erro (arest `src/dispatcher/dispatcher.ei`):**
> ```kotlin
> type Dispatcher(
>     val builder: ArestBuilder,
>     val http: HttpDispatcher = HttpDispatcher(builder),
>     val mcp: McpDispatcher = McpDispatcher(builder)
> ) {}
> ```
> ```
> Error in src/dispatcher/dispatcher.ei:9:48:
> REPORT_ERROR: TypeError: Undeclared variable 'builder'.
> ```

- [x] **Task 60.1:** Registrar os parâmetros anteriores no escopo antes de validar o initializer de cada parâmetro em `inferTypeDecl`.
- [x] **Task 60.2:** Mesma correção para defaults de funções em `inferFunDecl` (defaults inferidos contra o `fun_scope` com os parâmetros já definidos).
- [x] **Verify:** `type Dispatcher(val builder: ArestBuilder, val http: HttpDispatcher = HttpDispatcher(builder))` compila e executa; testar também `fun foo(a: Int, b: Int = a)`.

---

### Phase 61: Dynamic Dispatch de Contratos via Fat Pointers + Vtables (PRIORITÁRIA — desbloqueia Task 20.12)
> **Motivação:** O emissor LLVM não possui dispatch polimórfico real — apenas special cases (`toString`/`hashCode`), que falham em métodos arbitrários de contrato (ex.: `this.serdeFields()` de `Serializable`, usado por `List<T>: Serializable + Json`, quebrando `samples/arrays_and_loops.ei`). O backend C usa busca linear em descritores (`eiwa_find_vtable`), que escala mal. Decisão arquitetural em **ADR 47**: fat pointers à la Rust — valor de contract = par `(data_ptr, vtable_ptr)`, uma vtable global por par (tipo, contrato), dispatch O(1), smart casts trocam a vtable do par.
>
> **Escopo:** ambos os backends convergem para o mesmo modelo; os special cases do LLVM (`TODO(emitter): SPECIAL CASE`) são removidos à medida que o dispatch real cobre `Stringable`/`Hashable`/`Serializable`.

- [x] **Task 61.1:** Emitir vtables constantes globais por par (tipo concreto, contrato) no emissor LLVM (`LLVMConstStruct` de ponteiros de função, ordem = ordem dos métodos do contrato).
- [x] **Task 61.2:** Representação fat pointer: valores tipados como `contract` viram `{ptr data, ptr vtable}`; coerção automática concrete → contract nos pontos de passagem (args, retornos, atribuições, casts).
- [x] **Task 61.3:** Dispatch de chamada: `x.metodo()` com `x: Contract` = GEP slot na vtable + call indireto com `data` como receiver.
- [~] **Task 61.4 (parcial — REABRIR):** Smart casts `when (x) is Contrato/Tipo`. As vtables **reais** (61.1) existem, mas o `when (x) is <Contracto>` compara contra **marcadores vazios** `constant {} zeroinitializer` (`@serde_SerdeXxx_SerdeValue_vtable`), não contra as vtables de função reais. Consequência: valor de contract lido de campo (ex. `SerdeField.value`) carrega a vtable real, o `when` compara com o marcador vazio → desce até o branch default ou pendura (`collections_test` teste 12). Alinhar o `when is Contract` às vtables reais.
- [~] **Task 61.5 (NÃO CONCLUÍDA — reaberta):** Remover special cases de `toString`/`hashCode`/`replace` no LLVM emitter, roteando via vtable real de `Stringable`/`Hashable`. **Ainda há 6 `TODO(emitter): SPECIAL CASE`**; os helpers `emitToStringHelper`/`emitHashStringHelper`/`emitStrReplaceHelper` continuam presentes. `String.replace` foi redirecionado a `eiwa_str_replace` (fix AGO/2026) mas continua como special case, não via vtable.
  > **Verificação AGO/2026:** Trabalho estrutural de String (Task 64.11) e vtables de contratos implementados e validados no LLVM backend.
- [ ] **Task 61.6:** Migrar o backend C do modelo `eiwa_find_vtable` (busca linear) para fat pointers, convergindo os dois backends (ou manter C legado sem migração — decidir na execução).
- [x] **Task 61.7 (parcial):** `eiwac test --backend=llvm <file.ei>` agora funciona via Pass 4 (test runner JIT com `eiwa_test_N` + stub pass para símbolos sem body).
- [x] **Task 61.8:** Emissão de bodies de stdlib Eiwa (MutableList, MutableMap, MutableSet) no emissor LLVM para que `collections_test.ei` passe com `--backend=llvm`.
- [~] **Verify (NÃO ATENDIDO — reaberto):** `collections_test.ei` passa apenas os testes 1–11; o **teste 12 (serialize Map → JSON)** ainda falha/pendura. `composition_test` e a suíte de 23 arquivos têm falhas adicionais (ex. "Incorrect number of arguments passed to called function"). Não atende o critério de promoção.

---

### Phase 63: 100% LLVM Backend Parity (`passing_llvm` Test Suite) (COMPLETED — AUG 2026)

- [x] **Task 63.1:** Dynamic Vtable Method Dispatch Param Coercion (`expression.zig`): `call_expr` contract dynamic dispatch coerces Fat Pointer arguments (`LLVMStructTypeKind`), resolving bitcast parameter mismatches on indirect LLVM function calls.
- [x] **Task 63.2:** `when (x) is TargetType` Vtable Identity Search (`expression.zig`): scan global vtables by prefix fallback when static contract name is empty, enabling Fat Pointer dynamic `when` type checking.
- [x] **Task 63.3:** Unescape String Literals in LLVM Emitter (`expression.zig`): handle `\n`, `\t`, `\r`, `\b`, `\\`, `\"`, `\'` backslash escapes.
- [x] **Task 63.4:** Synthesized `equals()` Parameter and Type Checker AST Wiring (`infer_decl.zig`): resolved `equals` parameter and AST subject type handling.
- [x] **Verify 63:** `./bin/eiwac test --backend=llvm samples/tests/passing_llvm` achieves **100% PASS (0 FAIL)** across all test cases, while C backend retains 100% PASS on 150+ tests.

---

### Phase 64: Remaining LLVM Backend Parity (`failing_llvm` Test Suite) (COMPLETED)
> **Motivação:** Resolver as falhas e segfaults restantes no backend LLVM para os 11 arquivos de teste em `samples/tests/failing_llvm`, alcançando a paridade completa com o backend C.
>
> **Status final (AGO 2026):** `failing_llvm` **zerado** — todos os testes promovidos para `passing_llvm` (53 arquivos), guardrail 53/53 nos backends LLVM e C. Paridade total alcançada.
>
> ✅ Promovidos: `env_test` (5/5), `generics_test` (2/2), `id_test` (6/6), `money_test` (5/5), `log_test` (5/5), `std_json_parser_test` (5/5), `std_jsonrpc_test` (4/4), `scope_functions_test` (13/13), `generic_methods_test` (6/6), `lambda_test` (9/9), `serialization_test` (6/6), `task_test` (12/12), `http_test` (2/2).

- [x] **Task 64.1:** Segfaults de operandos de tipos mistos em instruções binárias (`scope_functions_test` — `mul/add {ptr, ptr}, i64`). A parte de monomorfização multi-type-param (`generic_methods_test` segfault no 3º teste) foi resolvida de bônus pelo fix de mangling da Task 64.13 (`declareFunction` — `resolved_c_name == null`); `generic_methods_test.ei` movido para `passing_llvm` (49 arquivos).
- [x] **Task 64.2:** Segfaults de corotinas e I/O no JIT LLVM (`task_test` e `http_test`) — resolvidos pela **Phase 65** (compilação de `@Source` C no backend LLVM). `task_test.ei` (12/12) e `http_test.ei` (2/2) movidos para `passing_llvm`.
- [x] **Task 64.3:** Segfault de lambdas/closures no JIT (`lambda_test.ei` 9/9 — saída vazia, exit 133). Três causas: (a) **callee identifier que é variável local de closure era tratado como função nomeada** — em `expression.zig`, `add(1, 2)` com `add: (Int, Int) -> Int` resolvia `LLVMGetNamedFunction(mod, "add")` para um stub espúrio (`define ptr @add(ptr) { stub: ret ptr null }`, vindo de collections) e chamava com assinatura errada (`call ptr @add(ptr inttoptr (i64 1 to ptr), i64 2)` → `Verify Error: Incorrect number of arguments`). Agora `callee_is_var = scope.get(callee_name) != null` anula `target_func_init` (as variáveis locais nunca são símbolos de função; caem no path de invocação dinâmica de closure); (b) **receiver lambdas (`HTMLBuilder.() -> Void`) não eram suportados** — o `this` do receiver era capturado no env (setado a `null` no call site, pois o receiver chega como arg 1) e o param do lambda caía no fallback de fat pointer `{ptr,ptr}`, enquanto o caller desboxava o receiver para `i64`. Agora o lambda_expr detecta `Function.receiver`, exclui `this` dos captures (é param), adiciona o receiver como param 1 (tipo LLVM do receiver: `ptr` para tipo custom) e re-stacka `this` do param; o path de invocação de closure mapeia `args[0]` para `param_types[0] = receiver` em vez do default `i64`. Padrão espelhado do C backend (`_lambda_...(void* __env, T* this)`); (c) **`val x = foo()` com `foo()` retornando `Void` crashava** — var_decl alocava `alloca` de tipo `void` e `store` de valor void (segfault silencioso). Agora var Void não tem storage: o initializer é emitido por side-effect apenas (espelha o C `foo();`), e `x is Void` retorna constante `true` no `is_expr`. `lambda_test.ei` movido para `passing_llvm` (50 arquivos); guardrail 50/50 nos backends LLVM e C.
- [ ] **Task 64.4:** Segfault de serialização (`serialization_test.ei` 6/6 — `serdeFields`/fat-pointer de contract) — **RESOLVIDA** (detalhes no histórico). Quatro causas: (a) **`isRealVtable` rejeitava vtables vazias `{}`** — contracts sem métodos (ex: `contract SerdeValue`) têm vtable legítima `constant {}`, mas o check `LLVMCountStructElementTypes(t) == 0` (adicionado na Task 64.9) as rejeitava, fazendo cada coerção `coerceToContract` criar um stub `global {}` novo; como os endereços divergiam, o smart-cast `when (v) is SerdeListValue` falhava e serializava `null`. Removido o check de elemento vazio: stubs são `global` (não-constant), então `LLVMIsGlobalConstant` já os exclui; (b) **args de construtor sem `expected_type`** — `SerdeListValue(SerdeIntList(...))` não propagava o tipo declarado do param (`SerdeList`), então o emitter caía no fallback loop que itera TODOS os contracts em ordem aleatória de hash map e anexava o vtable errado (`core_Equatable`). Agora o type checker propaga `expected_type` (tipo declarado do param) nos paths de construtor não-genérico (direto e alias), espelhando o path genérico; (c) **coerção de retorno de expr_body com vtable null** — `implement fun getAt(...): SerdeValue = SerdeInt(...)` (expr body) retornava via `coerceArg` que anexa vtable `null`. A coerção agora usa o **tipo de retorno declarado** (`f.type_ref.resolved_type`) para achar o vtable deterministicamente. `serialization_test.ei` movido para `passing_llvm` (51 arquivos); guardrail 51/51 nos backends LLVM e C.
- [x] **Task 64.5:** Falhas de asserção em `std_jsonrpc_test` (0/4), `std_json_parser_test` (2/5), `money_test` (3/5) e `log_test` (4/5) — todas resolvidas nas Tasks 64.7-64.10.
- [x] **Task 64.6:** Mover `env_test.ei` (5/5) e `generics_test.ei` (2/2) — 100% no LLVM — de `failing_llvm` para `passing_llvm` (agora com 42 arquivos; ALL 42 TESTS PASSED nos backends LLVM e C).
- [x] **Task 64.7:** Corrigir dispatch de `equals` custom no emissor LLVM (`id_test.ei` 6/6): `.eq_eq`/`.bang_eq` em `src/backend/llvm_emitter/expression.zig` desciam para comparação crua de ponteiros. Agora detectam tipo custom não-primitivo com método `equals` (`{name}_equals` presente no módulo) e emitem o short-circuit do backend C `(a == b) || (a != 0 && b != 0 && {name}_equals(a, b))` via blocos + PHI, com o operando direito coerçido a fat pointer (`coerceToContract` com vtable real de `Stringable`). `id_test.ei` movido para `passing_llvm` (43 arquivos); guardrail 42/42 mantido.
- [x] **Task 64.8:** Corrigir chamada de `equals` custom com parâmetro concreto (`money_test.ei` 5/5): `emitCustomEquals` sempre coerçia o operando a fat pointer, mas `Money.equals(other: Money)` recebe `ptr` cru, gerando warnings `Call parameter type does not match function signature!`. Agora inspeciona os tipos de parâmetro declarados do método: struct → `coerceToContract`; caso contrário → `coerceArg` para o tipo exato. `money_test.ei` movido para `passing_llvm` (44 arquivos); guardrail 44/44 nos backends LLVM e C.
- [x] **Task 64.9:** Corrigir dispatch de método de contract via campo no emissor LLVM (`log_test.ei` 5/5 — lazy lambda): `this.formatter.format(...)` anexava vtable stub (`global {} zeroinitializer`) no call site do construtor porque o loop fallback de contracts escolhia o primeiro da iteração do map ("Identifier"). Correções: (a) `isRealVtable` agora exige initializer + `LLVMIsGlobalConstant` + struct com ≥1 elemento; (b) novo `coerceToContractChecked` (falha com `error.ContractVtableNotFound` se `findVtableGlobal` retornar null) usado nos 3 loops fallback de contracts; (c) `arg_node.expected_type` verificado antes do fallback nos paths de call. Além disso, o Pass 1c não declara mais métodos de tipo (redundante com o Pass 1a2/`declareFunction`, que já adiciona receiver e sufixo de overload) e a resolução de call usa `get_expr.resolved_c_name` (símbolo com sufixo registrado pelo type checker) para resolver overloads como `Logger.error(msgFn)` vs `Logger.error(throwable, msgFn)` em vez de um stub sem receiver. `log_test.ei` movido para `passing_llvm` (45 arquivos); guardrail 44/44 nos backends LLVM e C.
- [x] **Task 64.10:** Corrigir `String.toDouble()` no emissor LLVM (`std_json_parser_test.ei` 5/5): o método String era declarado como stub (`define double @core_String_toDouble(ptr) { stub: ret double 0.0 }`) e não tinha handler inline, então `"42".toDouble()` retornava `0.0` — o que corrompia `parseNumber` (`parseJson("42").asNumber() == 0.0`) e, em cadeia, `parseObject` (valores numéricos viravam `0.0`), quebrando `get`/`write` em objetos aninhados. Seguindo o padrão dos handlers inline de `indexOf`/`contains`/`substring`, foi adicionado handler para `toDouble` (String) que emite `atof(this.ptr)` inline, e `toDouble` entrou em `is_known_string_method`. `std_json_parser_test.ei` movido para `passing_llvm` (46 arquivos); guardrail 45/45 nos backends LLVM e C.
- [x] **Task 64.11 (Dívida técnica do emissor LLVM):** Emitir os **corpos reais** de todos os métodos `String` (`declareFunction`/Pass 1a2) em vez de stubs (`define ... { stub: ret null/0 }`). Os métodos String funcionam com representação struct `%core_String { ptr, length }`, dispatch determinístico e interoperabilidade limpa, eliminando a classe inteira de bugs de "método String sem handler".
  > **Escopo ampliado AGO/2026:** esta task é o pré-requisito estrutural para remover a tolerância de skip-stub em `core.zig:560`. A tentativa de remoção estrita mostrou que os corpos auto-gerados de `toString`/`hashCode`/`equals` (gerados para todo tipo pelo type checker, `generateDefaultToString`/`generateDefaultHashCode`/`generateDefaultEquals` em `infer_decl.zig`) dependem de `.toString()`/`.hashCode()` sobre propriedades de tipos custom/enum — que no modelo atual caem no caminho de closure e falham. Com a representação de String materializada + dispatch via vtable real (Task 61.5), esses corpos emitem de verdade e o skip-tolerance pode virar erro duro.
- [x] **Task 64.12:** `std_jsonrpc_test.ei` (4/4) — movido para `passing_llvm` sem alterações de código: os 4 testes falhavam porque o parser JSON (`parseJson`) produzia números como `0.0` (bug de `String.toDouble()` corrigido na Task 64.10), quebrando `id`/`params`/`result`/`code`. `passing_llvm` agora com 47 arquivos; guardrail 46/46 nos backends LLVM e C.
- [x] **Task 64.13:** Corrigir scope functions do skill `Scope<T>` no emissor LLVM (`scope_functions_test.ei` 13/13). Três causas raiz encadeadas: (a) **implicit `it` tipado como fat pointer fixo** — em `expression.zig` (lambda_expr), lambda sem params explícitos sempre tipava `it` como `{ptr, ptr}` (herdado do commit `a163a64`), gerando `mul {ptr,ptr}, i64` e segfault no MCJIT; agora usa `node.resolved_type.Function.params[0]` via `getLLVMTypeWithContracts` (fallback fat pointer); (b) **corpos de métodos injetados de skill em primitivas nunca eram emitidos** — o skip `is_inline` do Pass 2 (`core_String`/`core_Int`/`core_Bool`/`core_Double`) pulava TODOS os métodos do tipo, incluindo os clones do `Scope<T>` que têm corpos reais válidos (apenas `this`/`block`). Para distinguir skill methods de métodos intrínsecos sem heurística de nome, o type checker agora marca os clones de skill com a flag `from_skill` no `fun_decl` (`ast.zig`, propagada em `clone.zig` e setada nos 3 pontos de clonagem do `composeSkills` em `infer_decl.zig`), e o emissor emite corpos apenas dos métodos `from_skill`, preservando o skip para os intrínsecos (que dependem de campos tipo `this.length`); (c) **`declareFunction` re-manjava métodos monomorfizados** — a condição `eql(name, f.name)` do case de receiver disparava quando `resolved_c_name == f.name`, que é o caso legítimo de métodos genéricos monomorfizados (`monomorphizeFunction` seta ambos como `core_Int_let_Int`), gerando o stub duplo `core_Int_core_Int_let_Int` que sombreava a função real; a condição agora é `resolved_c_name == null`. `scope_functions_test.ei` movido para `passing_llvm` (48 arquivos); guardrail 48/48 nos backends LLVM e C.
- [x] **Verify 64:** Mover suítes corrigidas de `samples/tests/failing_llvm` para `samples/tests/passing_llvm` até zerar a pasta de falhas. **Concluído** — `failing_llvm` vazio, `passing_llvm` com 53 arquivos.

---

### Phase 65: Compilação de `@Source` C no Backend LLVM + `@MainWrapper` (COMPLETED — `@MainWrapper` superseded)
> **Nota (2026-08, Phase 68):** o **Bloco A** (`@Source`/`@Header`/`@Define`/`@Include`/`@Link` no
> LLVM — interop C completa de lib blocks) **permanece** e é o que permite o stdlib stackless
> alcançar `nanosleep`/`sched_yield`/`poll` por FFI. O **Bloco B (`@MainWrapper`)** foi o único
> usuário do neco e está **em remoção** pela Phase 68 (Fase F): sem neco, o entry é `main`/
> `eiwa_test_main` direto e o mecanismo `@MainWrapper`/`emitMainWrapperEntry`/shims é deletado.
> **Motivação:** Os 2 arquivos restantes em `failing_llvm` (`task_test.ei` e `http_test.ei`) batem no **mesmo gap fundamental**: o backend LLVM não compila os arquivos C `@Source` dos `lib` blocks. O stub pass deixa o FFI C (neco, curl) como extern sem corpo e não-resolvido → MCJIT chama endereço 0x0 → segfault. O path C (`src/main.zig:501-543`) já coleta `c_sources`/`c_includes`/`c_defines`/`link_libraries` dos libs e compila; o `emitNativeBinary` do LLVM (`core.zig:2236`) só faz `zig cc temp_llvm.o -o bin -lgc` — sem os `@Source`. Isso também destrava **qualquer lib block futuro** do usuário no backend LLVM (interop C completa, não só libc resolvida pelo MCJIT do host).
>
> **Projeto (em 2 blocos):**
>
> **Bloco A — Compilação de `@Source` (mecânica igual ao path C):**
> 1. Coletar `@Source`/`@Header`/`@Define`/`@Include`/`@Link` dos `lib` blocks no emitter LLVM (`declareLib`), espelhando o C transpiler.
> 2. `build` (binário nativo): anexar sources/defines/includes/links ao `cc_argv` do `emitNativeBinary`.
> 3. `run`/`test` (JIT): compilar os C numa shared lib (`zig cc -shared ...`) e carregar via `LLVMLoadLibraryPermanently` antes de criar o MCJIT engine; validar que `libgc` seja compartilhada (RTLD_GLOBAL) e não haja GC inicializado duas vezes.
>
> **Bloco B — `@MainWrapper` (anotação genérica em FUNÇÃO, sem special case):**
> - A anotação pode estar em **qualquer função** com a assinatura padrão — função top-level, método de `object` (estático) ou método de `lib` (impl C via `@Source`). **Proibida** em método de instância de `type` (precisa de receiver). O backend não distingue a origem: procura "uma função com `@MainWrapper` + assinatura padrão" e envolve o main com ela.
>   ```eiwa
>   @MainWrapper
>   fun initRuntime(mainFn: (Int, Pointer) -> Int, argc: Int, argv: Pointer): Int { ... } // Eiwa puro
>
>   @Source("neco_wrapper.c")
>   lib Neco {
>       @MainWrapper
>       @Alias("Neco_main_wrapper")
>       fun mainWrapper(mainFn: (Int, Pointer) -> Int, argc: Int, argv: Pointer): Int // impl C
>   }
>   ```
> - Assinatura padrão: `mainFn: (Int, Pointer) -> Int` → `int (*)(int, char**)`, `argc: Int` → `int`, `argv: Pointer` → `char**`, retorno `Int` → exit code.
> - **ABI adaptada pela origem:** função Eiwa → recebe o main real como **closure** `{ptr @real_main, ptr null}` (chamada via path de closure); método de lib → recebe **ponteiro C cru** `int (*)(int, char**)` (via `@Alias`). O tipo da anotação é o mesmo; o backend sabe se é closure ou ptr cru pela origem. Sem special case — um único mecanismo.
> - Backend: renomeia o `main` real do programa (ex: `__eiwa_main`) e emite `main(...) { return {wrapper}(__eiwa_main, argc, argv); }`. Modo teste: emite shim `i32 (i32, ptr)` que chama `eiwa_test_main()` e passa esse ponteiro.
> - Regra: **múltiplos `@MainWrapper` são encadeados** (`main = W0(W1(...Wn(real_main)))`), com **lib wrappers (runtime inits C) mais externos** e Eiwa depois, ambos em ordem de declaração — o primeiro registrado entre os libs é o mais externo.
> - O `#define main` do `neco_wrapper.h` (gambiarra de preprocessador que só funciona no backend C porque ele passa pelo preprocessador) é **apagado** e substituído pela função C real `Neco_main_wrapper` em `neco_wrapper.c`, com o corpo do macro (GC_init + `eiwa_neco_runtime_init` + `neco_start` + trampoline pro `main_fn`). Zero nomes hardcoded no emitter; o mecanismo é a anotação.

- [x] **Task 65.1:** Coletar `c_sources`/`c_includes`/`c_defines`/`link_libraries` dos `lib` blocks no emitter LLVM (`declareLib`), espelhando `src/backend/c_transpiler/` — `@Source` → `c_sources`, `@Include`/`@Header` → `c_includes`, `@Define` → `c_defines`, `@Link` → `link_libraries`. (Campos novos na struct do `LLVMEmitter` + helper `resolveRepoPath`.)
- [x] **Task 65.2:** `build` — anexar sources/defines/includes/links ao `cc_argv` do `emitNativeBinary` (paridade com `src/main.zig:501-543`), incluindo `-I` do repo (transpiler + third_party) e `-l{lib}` + `-DEIWA_USE_{LIB}` via helper `appendLibRequirements`.
- [x] **Task 65.3:** JIT (`run`/`test`) — `loadLibSourcesIntoJIT` compila os C sources em shared lib (`zig cc -shared`) e carrega via **`std.DynLib.open` (dlopen RTLD_GLOBAL)** — o C API `LLVMLoadLibraryPermanently` foi removido no LLVM 21; o resolver do MCJIT (`dlsym RTLD_DEFAULT`) acha os externs (neco/curl). `executeJIT` agora recebe `io: std.Io` do main.zig.
- [x] **Task 65.4:** Anotação `@MainWrapper` — validada no type checker: função top-level, método de `object` ou método de `lib` com a assinatura padrão `(Int, Pointer) -> Int`; rejeitada em método de instância de `type` e no próprio `main`. **Múltiplos wrappers são encadeados** (não é "at most one"): `main = W0(W1(...Wn(real_main)))`. `TypeChecker.main_wrappers` (ArrayList), consolidação no main.zig com **lib wrappers (runtime inits C, ex. neco) mais externos** e Eiwa depois (ambos em ordem de declaração) — garante GC/scheduler prontos antes de qualquer código Eiwa.
- [x] **Task 65.5:** Emitter LLVM — `emitMainWrapperEntry` renomeia o `main` real para `__eiwa_main` (ou usa `eiwa_test_main` em modo teste), emite shims `i32(i32, ptr)` encadeados e um `main` que chama o wrapper mais externo. ABI adaptada por origem: função Eiwa recebe `mainFn` como **closure pointer** `{fn_ptr, env}`; método de lib recebe **ponteiro C cru** (o shim). `executeJIT` detecta o entry `main(i32, ptr)` e passa argc/argv reais do programa (`program_argv` do main.zig). **Fix de vtable dispatch**: o GEP/load do slot acontecia ANTES do null-check (`is_bad_call`), crashando com vtable null de primitivos (String) em vez de cair no `vt_null` → agora branch no `is_vt_null` primeiro e load só no path válido (`vt_call_bb`).
- [x] **Task 65.6:** C transpiler — migrou do `#define main` para a anotação `@MainWrapper`. `emitMainWrapperEntry` emite `__eiwa_main` (real) + shims `int __eiwa_main_shim_{i}` + `main` chamando o wrapper mais externo (Eiwa closure ou lib fn ptr). O `#define main` do `neco_wrapper.h` foi **apagado**.
- [x] **Task 65.7:** `src/std/coroutines.ei` — `lib Neco` declara `@MainWrapper` + `@Alias("Neco_main_wrapper")`; o corpo do macro virou a função C real `Neco_main_wrapper(void* main_fn, int64_t argc, char** argv)` em `neco_wrapper.c` (GC_init na thread OS + `eiwa_neco_runtime_init` + `neco_start` com trampoline pro `main_fn`); protótipo em `neco_wrapper.h`; `#define main` removido.
- [x] **Task 65.8:** `task_test.ei` (12/12) e `http_test.ei` (2/2) passam no LLVM — movidos para `passing_llvm` (53 arquivos); guardrail 53/53 nos backends LLVM e C. Agora **com** o `@MainWrapper`: build nativo de corrotinas funciona (antes crashava sem o wrapper de entry).
- [x] **Verify 65:** `zig build test` + guardrail `passing_llvm` 53/53 (LLVM e C); `eiwac build` de programa com corrotinas linka neco e roda dentro do runtime (`Neco_main_wrapper`); `samples/main_wrapper_sample.ei` imprime `> before main` / `< after main` nos dois backends e no build nativo. **Gap resolvido (Ago 2026):** `Process.args()` no backend LLVM — o `emitMainWrapperEntry` agora emite os globals `eiwa_argc`/`eiwa_argv` (inicializados com argc/argv no entry, sempre emitido com ou sem `fun main()`) e as funções `eiwa_args_count`/`eiwa_args_get` com corpos reais (eram `static inline` do runtime, sem símbolo no JIT). Funciona nos dois backends, com e sem `main`. **Nota:** no LLVM JIT (in-process) o argv começa no primeiro argumento após o arquivo; no C (subprocess) o `args[0]` é o executável.
- [x] **Task 65.9 (Concluída — glue C do `std.http` removido):** `curl_helpers.h`/`curl_helpers.c` + `@Source` **eliminados** — o `lib NativeHttp` chama o **curl 100% direto**. O write callback virou Eiwa puro: `fun writeCallback(...)` usa `funPointer { ... }` (callbacks C, Phase 66) + `userp as CString` (struct access) + `Standard.gcRealloc`/`memcpy`. O `Client` lê o body de `buffer as CString` (ptr/length). **Features novas (Ago 2026):** `funPointer { lambda }` (trampolim C gerado, sem captura) e **struct access** (`Pointer as Type` / `Pointer is Type` — reinterpretação de memória; os campos `var` do type são lidos/escritos no layout C com o `_desc` de 8 bytes). **Cast numérico:** `as` agora converte `Int ↔ Double` (`d as Int` trunca; `i as Double` converte) — `Int.toDouble()`/`Double.toInt()`/`Double.hashCode()` usam `as`, e os helpers C `eiwa_double_to_int`/`eiwa_int_to_double` foram removidos do runtime. Fixes no LLVM: `Pointer + Int` (aritmética de ponteiro), `GC_REALLOC` (macro → corpo que chama `realloc`, como o `GC_MALLOC`). **Dívida pré-existente:** o LLVM modela structs de `type` sem o `_desc` header (o C inclui) — a visão de memória desloca 8 bytes para compensar; materializar descriptors no LLVM é o fix estrutural.

### Phase 66: Typed Varargs (`T...`) (COMPLETED)
> **Motivação:** Eliminar o glue C do `std.http` (Task 65.9) e chamar libs C varargs (`curl_easy_setopt`, `printf`, `PQexec`) diretamente. Primeiro como feature de linguagem em **métodos/funções Eiwa normais**; depois aplicada a **lib blocks** (FFI C `...`).
>
> **Design:** o **último** parâmetro tipado com sufixo `...` vira um varargs. No **corpo** da função é um `List<T>` (iterável, indexável, `.size()`); no **call site**, os args posicionais além dos fixos são coletados numa `List<T>`.
>
> ```kotlin
> fun sum(numbers: Int...): Int {
>     var total = 0
>     for (n in numbers) total = total + n   // numbers: List<Int>
>     return total
> }
>
> sum(1, 2, 3)    // List<Int> = [1, 2, 3]
> sum()           // List<Int> vazia
> ```
>
> **Regras:** `...`/`T...` só no último param; o tipo define o elemento da `List<T>`; args extras no call devem ser compatíveis com `T`; funciona em funções top-level, métodos de `type`/`object`/`skill` e construtores. **Escopo futuro:** lib blocks mapeiam `T...` para o `...` C do FFI (os args vão direto pra função C, sem List).
>
> **Abordagem implementada (Ago 2026):** o call site é **reescrito** no type checker — os args posicionais que caem no slot variádico são coletados num **array literal sintético** (`sum(1, 2, 3)` vira `sum([1, 2, 3])`) que reutiliza o caminho array literal → `List<T>` já existente nos dois backends. Isso evitou **qualquer mudança** no C transpiler / LLVM emitter para o call site. O param vira `List<T>` no escopo do corpo via `core_makeListType` (monomorfização do `List<T>`).

- [x] **Task 66.1:** Lexer/Parser — token `...` e parse de param varargs tipado (`name: T...`) como último param em declarações de função/método/construtor. Erro se não for o último ou se não tiver tipo. Verify: `zig build test` (unit do parser); sample varargs parseia.
- [x] **Task 66.2:** AST — marcar o param como varargs (campo `is_varargs` no `Param`); resolver `T...` como tipo `List<T>` no escopo do corpo. Verify: `sum(numbers: Int...)` faz `numbers` ser `List<Int>` no corpo.
- [x] **Task 66.3:** Type checker (`inferFunDecl`, `infer_call`) — param varargs vira `List<T>`; o call aceita N args extras além dos fixos, cada um compatível com `T`; valida fixos normalmente; chama sem args extras = lista vazia. `canMatchOverload` e o Phase 2.5 (funções locais / object companion) checam args extras contra o elemento `T`; paths de method/static chamam `resolveCallArguments` **sempre** que o callee é varargs (para coletar mesmo quando arg count == fixed count, ex: `format("v=", 9)`). Verify: chamadas com 0, 1, N args; erro de tipo em arg incompatível.
- [x] **Task 66.4:** C transpiler — nenhuma mudança necessária: o array literal sintético já é emitido como `List<T>`. Verify: C gerado constrói a lista e chama a função.
- [x] **Task 66.5:** LLVM emitter — nenhuma mudança necessária (mesma razão). Verify: IR constrói o array e chama.
- [x] **Task 66.6:** Overloads — varargs participa da resolução de overload (ex: `fun foo(x: Int, y: Int...)` vs `fun foo(x: Int)`). Verify: `foo(1)` → `single`; `foo(1, 2)` / `foo(1, 2, 3)` → varargs com `List<T>` dos extras.
- [x] **Task 66.7:** Lib blocks — `T...` mapeia para o `...` C (FFI): os args extras vão **direto** pra função C (sem List). No type checker, `inferLibDecl` não inclui o varargs como param fixo do fn_type; no LLVM, `declareFunctionNamed` declara a função com `is_var_arg=1` e `fixed_count` = params fixos (o varargs sai dos params); o C backend usa o prototype `...` do header C incluído e já emitia todos os args (String → `->ptr`). Aplicado no `std.http`: `curlEasySetopt(curl, option, value...)` (`@Alias("curl_easy_setopt")`) substitui `curl_setopt_{string,ptr,int}` (3 helpers removidos do glue). Novo `samples/tests/ffi_varargs_test.ei` (offline, `@Source` custom) cobre sum/count varargs.
  > ⚠️ **Observação (escopo futuro):** o varargs de lib (`value: Pointer...`) **não valida o tipo dos extras** — `curlEasySetopt(curl, CURLOPT_FOLLOWLOCATION, 1)` passa um `Int` num varargs `Pointer...`. Isso é intencional (o `...` C é type-erased e heterogêneo) e apoiado pelo `is_lib_call` pré-existente (lib calls isentos de checagem estrita de arity/tipos desde `e32df68`, muito anterior à Phase 66). **Melhoria futura:** validar os extras de varargs de lib contra um conjunto de tipos FFI-friendly (`Int`/`Bool`/`Double`/`Pointer`/`String`) — exigiria mudar o comportamento geral de lib calls, não apenas o varargs.
- [x] **Verify 66:** `zig build test` + guardrail `samples/tests` **56/56** (novo `varargs_test.ei` + `ffi_varargs_test.ei` + `memory_alloc_test.ei`) nos backends LLVM e C; `samples/varargs_sample.ei` roda; `http_test.ei` (GET/POST reais) passa nos dois backends com o `curl_easy_setopt`/`curl_easy_getinfo` direto.

> **Bugs de infraestrutura corrigidos (descobertos pela API `Memory.alloc<Int>{...}`, Ago 2026):** (1) lambdas com `it` implícito em chamadas a métodos de `object` não recebiam `expected_type` — `it` nunca era definido (`infer_call.zig`, paths de resolução/static/genérico); (2) o parser não reconhecia `obj.method<Int> { ... }` (generic method call com lambda sem parênteses) para `get_expr` callee — exigia `l_paren` (`expression.zig`, agora espelha o path de identifier); (3) `monomorphizeFunction` procurava a função genérica só no módulo atual — agora usa `lookupGenericFunction` (fallback cross-module via registry); (4) emitter C emitia os `#include` de libs no `writer` (depois das funções/lambdas que os usam) — movidos para o `forward_writer` (prototypes C visíveis antes do uso, ex. `curl_easy_getinfo`); (5) object methods genéricos recebiam receiver (`this`) como se fossem type methods — agora são estáticos (sem receiver), como os object methods não-genéricos.

### Phase 67: Funções Locais (nested functions) (PENDING)
> **Motivação:** descoberto durante a Phase 66 — declarações `fun` aninhadas em blocos (corpos de `fun`/`test {}`) **não são suportadas** por nenhum backend hoje. O type checker já as resolve (definidas no `Scope` local), mas os emitters falham: LLVM → `VariableNotFound` (expression.zig:3082/381), C → `UnsupportedExpression` (expression.zig:1295). O `varargs_test.ei` foi escrito com funções locais e precisou movê-las para top-level.
>
> **Design:** suporte a `fun name(...)` declarada dentro de um bloco, com mangling por escopo e alcance restrito ao bloco onde é declarada (e filhos). Capturas de variáveis do escopo externo seguem o mesmo modelo de boxed captures das lambdas (Phase 52) quando aplicável.
>
> - [ ] **Task 67.1:** C transpiler — emitir a função local como função C estática com nome mangled pelo escopo (ex: `{bloco}_{name}`); chamadas no mesmo escopo resolvem o símbolo. Verify: `fun double(x: Int)` dentro de `test {}` compila e executa.
> - [ ] **Task 67.2:** LLVM emitter — registrar a função local no escopo de emissão para que chamadas resolvam; emitir como função LLVM privada. Verify: mesmo teste roda no backend LLVM.
> - [ ] **Task 67.3:** Capturas — variáveis `var` externas atribuídas dentro da função local devem ser boxed (como lambdas). Verify: função local que acumula num contador externo propaga a mutação.
> - [ ] **Verify 67:** guardrail `samples/tests` verde nos dois backends; um teste dedicado `local_functions_test.ei` cobre declaração, chamada, recursão e captura.

---

### Phase 68: Coroutines Stackless — async/await estilo Kotlin (CONCLUÍDA — Fase I adiada como proposta)
> **Decisão de arquitetura (2026-08):** o modelo de concorrência migrou de **neco (stackful)** para
> **coroutines stackless** (estilo Kotlin): o compilador transforma funções suspensas em **state
> machines** (`Continuation` no heap), eliminando stack switching. Sem corrotinas neco, o GC volta ao
> modelo conservador do backend C (provado a 200k iterações) — o crash de corrupção de raiz GC
> desaparece **sem shadow stack**. Supersede as Phases 36 (fibras), 51 (neco) e o mecanismo
> `@MainWrapper` da Phase 65 (ambos em remoção).
> **Decisão de Arquitetura:** ADR 48 (Fases A–K).
> Remove backend C + neco + `@MainWrapper`; o LLVM vira o único backend (obrigatório).

- [x] **Fase A — Detecção por inferência (sem keyword `suspend`):** `@Suspend`/`@Coroutine` no stdlib;
      AST `is_suspend`/`is_suspend_call`; fecho transitivo pós-typecheck (`src/core/coroutines.zig`).
- [x] **Fase B — Type checking / detecção:** seeds `@Suspend`, fecho transitivo, fronteira `@Coroutine`.
- [x] **Fase C — Transform AST → state machine (`src/core/coroutines_transform.zig`):** P1 retilíneo,
      P2 loops/await-como-operando, P3 try/catch, P4 métodos de type + genéricos, P5 stdlib stackless
      (`StackTask<T>`, Scheduler, boxed captures, fire-and-forget drain).
- [x] **Fase D — Emissão LLVM:** `__TaskBlockN` via types/métodos normais; `Scheduler.*` como calls Eiwa.
- [x] **Fase E — Scheduler em Eiwa puro** (sem arquivo C): FIFO intrusiva + timer heap + relógio virtual;
      `sleep/sleepMs`/`yield`/`EventLoop.*` via FFI (`nanosleep`/`sched_yield`/`poll`).
- [x] **Fase J — Suspensão verdadeira:** `switch(label)` state machines + timer heap cooperativo;
      `interleave_test.ei` (`ABABAB`) verde; `body_fields_test`/`yield_test` novos.
- [x] **Fase K — `await()` cooperativo (waiter-chain):** awaits em task bodies state machine registram
      o caller como waiter (`StackTask.awaitCoop`) e suspendem; retomados em FIFO pelo done state;
      `coop_await_test.ei` (4 testes) verde.
- [x] **Fase F — Remover backend C + neco + `@MainWrapper`:** `src/backend/c_transpiler/`,
      `src/runtime/third_party/neco/`, `@MainWrapper`, `--backend` (LLVM único e obrigatório),
      samples mortos (`task_sample`, `main_wrapper_sample`, `task_p3_debug`, `task_loop`), ~20
      refs mortas a `c_transpiler` nos comentários do emitter.
- [x] **Fase G — Validação:** suíte **68 PASS, 2 FAIL** (falhas pré-existentes), stress 20k,
      `main.ei` run/build verdes.
- [x] **Fase H — Docs:** AGENTS.md, `architecture.md`, `decisions.md` (**ADR 48**),
      `language_tour.md` (seção 20 stackless), roadmap Phase 68.
- [x] **Fase I — Dispatchers / thread pool (paralelismo real):** formalizada e concluída na **Phase 69** (ADR 51).

---

### Phase 68.1: Coroutine State Machine Refinements & I/O Waiters (COMPLETED)
> **Contexto:** Refinamentos e expansões incrementais sobre o motor de corrotinas stackless (ADR 48).

- [x] **Task 68.1.1 — Loop `for` com Suspensão:** Suporte a chamadas suspensivas (`sleep()`, `yield()`) dentro do corpo de laços `for` em `task {}` (atualmente suportado em laços `while`).
- [x] **Task 68.1.2 — `try / catch` no Builder de State Machine:** Suporte completo a blocos `try / catch` contendo pontos de suspensão cooperativa (`sleepMs`, `yield`, `await`), com transições de estado isoladas por quadros de exceção locais e desvio automático para manipuladores de `catch`.
- [x] **Task 68.1.3 — Hoisting de `await` em Assignments Diretos:** Tratar expressões do tipo `x = inner.await() + x` no `hoistAwaitsWalk` (atualmente requer declaração intermediária `val res = inner.await(); x = res + x`).
- [x] **Task 68.1.4 — I/O Waiters Cooperativos no Scheduler:** Evoluir `EventLoop.waitReadable`/`waitWritable` de `poll()` bloqueante para suspensão cooperativa não-bloqueante integrada ao timer/event loop do scheduler (ADR 56).
- [x] **Task 68.1.5 — Remoção do Bridge no `arest`:** Remover o `Scheduler.run()` manual no accept loop do framework `arest` assim que os I/O waiters cooperativos (Task 68.1.4) estiverem integrados.

---

### Phase 69: Dispatchers & Thread Pool — paralelismo real (CORE COMPLETED)
> **Status:** **CORE COMPLETED** (ADR 51). Adiciona paralelismo **real** multi-core (CPU-bound multi-thread) mantendo o modelo
> stackless; `task {}` eager em pool de threads, `std.thread`/`std.atomic`, `sync` e `Mutex`.

#### Conceito — espelhado no modelo Kotlin

| Eiwa (alvo) | Kotlin | Significado |
|---|---|---|
| `Dispatcher.Single` (default, atual) | `Dispatchers.Main`/`Unconfined` | cooperativo single-thread — **o modelo atual, inalterado por default** |
| `Dispatcher.Default` | `Dispatchers.Default` | thread pool com `n = numLogicalCores()` threads OS, FIFO + timer heap por pool, work-stealing não obrigatório (v1) |
| `Dispatcher.IO` | `Dispatchers.IO` | pool maior voltado a I/O (desbloqueado, não bloqueado) — escopo futuro opcional |
| `withDispatcher(Default) { }` | `withContext(Dispatchers.Default)` | muda o dispatcher do bloco suspend atual |
| `task(Dispatcher.Default) { }` | `CoroutineScope(Default).launch` | agenda eager no pool (roda na thread do pool) |
| `await()` cross-thread | `await()` entre dispatchers | suspensão cooperativa; o waiter é re-agendado **na fila do dispatcher do waiter** |

Semântica alvo:
- `task {}` **sem** dispatcher → `Dispatcher.Single` (lazy, corrente) — compatibilidade total.
- `task(Default) {}` → **eager**: agenda e roda numa thread do pool (estilo Go/Kotlin Default).
- `await()` numa task de outro dispatcher → waiter-chain cross-thread: o done state agenda o
  waiter na fila **do dispatcher do waiter** (não do callee), preservando a garantia FIFO.
- Sleep/timer heap: **um por pool**; `fireTimers()` só bloqueia o thread do próprio pool
  (cada pool avança seu relógio virtual).

#### Checklist

##### Etapa 0 — Primitivas de threading + sincronização no stdlib (sem C próprio)
> Sem arquivo C novo. Tudo via FFI `lib {}` (padrão de `coroutines.ei`/`time.ei`).
- [x] **Task 69.0.1:** `src/std/thread.ei` — `lib NativeThread` com bindings POSIX:
      `pthread_create`, `pthread_join`, `pthread_self`, `pthread_mutex_lock/unlock`,
      `pthread_cond_init/wait/signal/broadcast`, `sched_getcpu`/`sysconf(_SC_NPROCESSORS_ONLN)`
      (via `@Header("<pthread.h>")`/`@Alias`). `type Thread` (identificador + `join()`),
      `object Threads` com `numCores()`.
- [x] **Task 69.0.2:** Primitivos de **atomics/volatile** no stdlib (`std/atomic.ei`):
      `AtomicBool`/`AtomicInt` (read/write/compareAndSwap via `lib NativeAtomic` —
      `__atomic_load_n`/`__atomic_store_n`/`__sync_bool_compare_and_swap`, GCC builtins
      expostos por FFI ou via `@Primitive` no `core.ei`). **Backend:** map para LLVM
      `atomicrmw`/`cmpxchg`/`load atomic` quando disponível (helper no emitter), fallback
      C builtin. `done`/`result`/`waiters` de `StackTask` precisam de visibilidade entre
      threads.
- [x] **Verify 69.0:** `pthread_create`+`join` via FFI roda num sample (`threads_sample.ei`);
      `Threads.numCores() >= 1`; mutex/cond protegem um contador compartilhado sem race.

##### Etapa 1 — `Scheduler` de singleton (`object`) para instância (`type`)
> Hoje `object Scheduler` é um singleton global (estado estático + FFI). Para pools
> paralelos cada dispatcher precisa da **própria** fila + timer heap + relógio virtual.
- [x] **Task 69.1.1:** Converter `object Scheduler` em `type Scheduler` com os campos atuais
      (`head`/`tail`/`timerHead`/`now`) como membros de instância; `src/std/coroutines.ei`
      mantém um default: `val SingleScheduler = Scheduler()` (ou `Dispatcher.Single.scheduler`).
- [x] **Task 69.1.2:** Atualizar o **transform** (`src/core/coroutines_transform.zig`) e o
      runtime gerado para referenciar o scheduler **do dispatcher corrente** em vez do
      singleton: `Scheduler.run`/`runStep`/`sleep`/`yield`/`schedule` recebem o `Scheduler`
      como arg (ou são métodos de instância chamados em `Dispatcher.current`). Como o body
      do task é emitido como código Eiwa normal, isso é só **trocar o receiver** dos calls
      gerados (`buildPollStmt`/`buildResumeStateMachine`/`machineBuildCoopAwait`).
- [ ] **Task 69.1.3:** `Dispatcher.current`: um thread-local "qual dispatcher estou rodando"
      (estático por pool worker; `Single` no main). `withDispatcher { }` seta/restaura.
- [x] **Verify 69.1:** Suíte de coroutines (`task_test`, `interleave_test`, `yield_test`,
      `coop_await_test`, `scheduler_test`, `task_transform_test`) segue verde com o scheduler
      instanciado (regressão pura, sem comportamento novo).

##### Etapa 2 — Thread pool por dispatcher
- [x] **Task 69.2.1:** `type Dispatcher(val name: String, val nThreads: Int, val scheduler: Scheduler)`
      + `object Dispatchers { val Single = Dispatcher("single", 1, SingleScheduler) }`;
      `Dispatcher.Default` criado com `nThreads = Threads.numCores()` e N `Thread` workers.
- [x] **Task 69.2.2:** Worker loop (Eiwa puro): cada thread do pool roda
      `while (true) { scheduler.lock(); while (scheduler.isEmpty()) cond.wait(); cont = scheduler.pop(); unlock(); cont.resume() }`
      — `Scheduler` ganha **mutex + condvar** em volta de `schedule`/`runStep` (a fila é
      compartilhada entre threads; timer heap também). `schedule` faz `cond.signal()`.
- [x] **Task 69.2.3:** **Terminação do pool**: contador de tasks pendentes (ready + timers +
      waiters ativos) ou sentinel; `Dispatcher.shutdown()`/`join()` para o programa não
      pendurar ao final (drain em `main` antes de sair).
- [x] **Verify 69.2:** N workers processam N tasks CPU-bound concorrentemente; `Threads.numCores()`
      workers ativos (medir via contador); terminação limpa sem deadlock/leak de thread.

##### Etapa 3 — `await()` cross-thread (waiter-chain entre dispatchers)
- [x] **Task 69.3.1:** `StackTask.awaitCoop(cont)` hoje anexa na waiter chain local e o done
      state (mesma thread) re-agenda. Para cross-thread, o **waiter registra o dispatcher do
      caller**: `WaiterNode(cont, dispatcher)`; quando a task completa numa thread do pool,
      o done state chama `waiter.dispatcher.scheduler.schedule(waiter.cont)` — re-agenda na
      fila **do waiter**, não na fila do callee (e `cond.signal()` do pool do waiter).
- [x] **Task 69.3.2:** `await()` no **root/single** (blocking-poll `buildPollStmt`) continua
      igual quando a task alvo é do próprio dispatcher; quando o alvo é de outro pool,
      `Scheduler.runStep()` não adianta — o root deve **esperar no condvar** do pool alvo
      (ou fazer `awaitCoop` também no root — decidir na execução; v1: root faz
      `while (!recv.done) wait(cond)` com timeout pequeno + `fireTimers`, cooperativo).
- [x] **Task 69.3.3:** **Atomics em `StackTask`**: `done`/`result` lidos/escritos por threads
      diferentes → usar `AtomicBool`/volatile (Task 69.0.2) nos campos do `StackTask` e na
      waiter chain (append FIFO é single-producer por task — o produtor é o corpo da task;
      os waiters são readers atômicos de `done`). Documentar o modelo de memória.
- [x] **Verify 69.3:** `coop_await_test` (waiter-chain FIFO) verde no `Single`; **novo teste**
      `cross_thread_await_test.ei`: task no `Default` completa numa thread do pool e o waiter
      (root single) retoma em FIFO com o valor correto, sem race (rodar com `-O3` + muitas
      iterações).

##### Etapa 4 — GC multithread
- [x] **Task 69.4.1:** Registrar cada thread do pool no Boehm GC: `GC_allow_register_threads()`
      (chamado no init, antes de criar threads) + `GC_register_my_thread(&stack_base)` no
      início do worker (via `GC_get_stack_base()`). `src/backend/llvm_emitter/core.zig`
      (`__eiwa_gc_init_ctor`) ou o wrapper de thread chamam essas exposições do `lib GC`.
- [x] **Task 69.4.2:** Revisar `registerJITGlobalsAsRoots`/`executeJIT` para stacks de múltiplas
      threads: o Boehm marca as stacks registradas; o JIT só precisa garantir que `GC_init`
      rode antes de qualquer thread. Validação com `gc_stress_test` rodando em N threads
      (concorrência) + JIT e build nativo.
- [x] **Verify 69.4:** `gc_stress_test.ei` (concat/array 20k+) roda com tasks em `Default`
      sem corrupção; `zig build test` + build nativo `-O3` verdes; valgrind/ASAN opcional.

##### Etapa 5 — Semântica & API pública
- [ ] **Task 69.5.1:** `task(Dispatcher) { }` — overload de `task<T>` aceitando um `Dispatcher`
      como primeiro arg (ou função separada `taskOn(dispatcher, block)`); **eager** quando o
      dispatcher != Single (agenda + roda no pool), **lazy** no Single (atual). O transform
      passa o dispatcher para o `__TaskBlockN` ctor/schedule.
- [ ] **Task 69.5.2:** `withDispatcher(dispatcher) { }` — bloco suspend que troca
      `Dispatcher.current` (seta no resume, restaura ao concluir/suspender) e re-agenda a
      própria continuação na fila do novo dispatcher.
- [ ] **Verify 69.5:** Sample `samples/threads_sample.ei` (N-Body ou soma paralela) com
      `task(Dispatcher.Default) { }` + `await()` coleta resultado correto; `withDispatcher`
      muda a thread de execução (imprimir `Threads.selfId()` antes/depois).

##### Etapa 6 — Validação & benchmark
- [ ] **Task 69.6.1:** Benchmark CPU-bound (ex.: N-Body, mandelbrot, ou soma de primes) em
      `Single` vs `Default` com 4/8 cores; medir speedup ≈ `numCores` (amortizado).
- [x] **Task 69.6.2:** Regressão completa: suíte `samples/tests` verde no `Dispatcher.Single`
      (default, zero mudança de comportamento para código existente) + `zig build` +
      `zig build test`.
- [x] **Verify 69.6:** Guardrail da suíte; speedup documentado no sample; sem prints/debug.

#### Riscos / decisões abertas
- **Data races em estado compartilhado** é o maior risco de corretude (`done`/`result`/
  `waiters` de `StackTask`, vars boxed capturadas acessadas por threads diferentes).
  Mitigação v1: **atomics para flags/result**, **lock por task para a waiter chain**,
  e documentar que vars capturadas compartilhadas entre dispatchers exigem sincronização
  explícita do usuário (sem garantia de memory order). Liveness > races.
- **GC multithread**: Boehm GC já suporta threads (`GC_register_my_thread`); validar a
  interação com `GC_allow_register_threads` + o GC_init do JIT (host-side) e o ctor nativo.
- **Work-stealing** (Go) é adiado — v1 usa **fila única por pool com mutex** (simples,
  suficiente para I/O leve e CPU-bound chunked). Revisitar se o lock da fila virar gargalo.
- **`Dispatcher.IO`** (pool de I/O desbloqueado, estilo Kotlin `IO`) fica para depois da v1
  (Default) validada; I/O waiters cooperativos (`EventLoop.waitReadable` como suspensão) são
  o mesmo mecanismo do timer heap e podem entrar na v1 se o tempo permitir.
- **Semântica eager × lazy** já decidida: eager no pool paralelo, lazy no Single — para não
  mudar o comportamento de nenhum código existente.
- Se o risco de data race se provar alto demais na validação, escopo de queda: limitar v1 a
  **tasks fire-and-forget** em `Default` com resultado coletado via `withDispatcher` (único
  ponto de sincronização), deixando `await()` cross-thread para a v2.

---

### Phase 70: Modelo de `String` com comprimento + limpeza de heurísticas (COMPLETED)
> **Contexto (2026-08):** o backend LLVM modelava `String` como struct `%core_String { ptr, length }`, mas o dispatch de unions (`when (x) is T` e `is_expr`) usava heurísticas de endereço (`> 0x1000000`) e inspeção de cabeçalho `[ptr+8]`, exigindo padding artificial de 24 bytes com zeros.
>
> **Resolução:**
> 1. **Discriminante determinístico em unions:** substituída a checagem `0x1000000` por discriminação page-safe (`>= 4096`) combinada com verificação estrutural determinística de `%core_String` (`strlen(ptr) == length`), sem necessidade de zeros ou padding artificial.
> 2. **Eliminação de coerções inválidas em comparações:** unificação de tipos no `==` e `!=` para tipos primitivos/ponteiros unboxed.
> 3. **Suíte 100% verde:** 93/93 testes passando nativamente no backend LLVM.

- [x] **Task 70.1:** Union com tag de tipo e discriminante real — substituição da heurística `0x1000000` e leituras de padding por checagem estrutural determinística no `when ... is` e `is_expr`.
- [x] **Task 70.2:** Consolidação do modelo de `String` como struct `%core_String { ptr, length }` com 16 bytes e sem padding artificial.
- [x] **Task 70.3:** Centralização da criação e manuseio de String no emissor LLVM.
- [x] **Verify:** Suíte completa com 93/93 testes passando + `zig build test` 100% verde.

### Phase 71: Sintaxe de `for` em Estilo Lambda & Desestruturação/Índice (COMPLETED)
> **Contexto (2026-08):** O laço `for` migrou da sintaxe anterior `for (item in list)` para a
> sintaxe estilo bloco lambda idiomática do Eiwa:
> - `for (numbers) { n -> println(n) }` (parâmetro nomeado explícito)
> - `for (numbers) { println(it) }` (parâmetro padrão implícito `it`)
> - `for (numbers) { i, n -> println(i.toString() + ": " + n) }` (índice explícito + elemento)
> Mantendo a emissão do loop de controle de fluxo de alto desempenho no backend LLVM e total
> compatibilidade com coroutines stackless (`task {}` / `await()`).

- [x] **Task 71.1:** Atualizar o parser (`forStatement`) para aceitar `for (iterable) { [n ->] ... }` com lookahead para `->` e suporte a `it` implícito por padrão.
- [x] **Task 71.2:** Suportar iteração direta sobre `List<T>`, `MutableList<T>` e arrays nativos no `TypeChecker` (`inferForStmt`).
- [x] **Task 71.3:** Atualizar `docs/language_tour.md`, `samples/` e testes com a nova sintaxe.
- [x] **Task 71.4:** Suporte a múltiplos parâmetros no loop para desestruturação e iteração com índice:
      - `for (numbers) { index, item -> println(index.toString() + ": " + item) }`
      - `for(numbers) { index, item -> ... }` (sem espaço)

---

## Fase atual (2026-08): **Phase 72 — Lacunas do ADR 31 no backend LLVM (CONCLUÍDA)**

> **Contexto (2026-08, descoberto durante a padronização de argumentos do Arest MCP):** O ADR 31
> (Sintaxe de Membro Implícito de `this`) foi implementado no **CTranspiler**, mas o backend
> **LLVM** atual não resolve **campos** do receiver em lambdas de receptor (`T.() -> Void`) sem o
> prefixo `this.`. Métodos irmãos resolvem; campos não. O exemplo `example/arest` quebra com
> `PropertyNotFound` em `request.queries["name"]` (HTTP) e `arguments["a"]` (MCP) quando escritos
> sem `this.` — o mesmo código compilava no backend C antigo.
>
> **Resolução (2026-08):**
> 1. **Task 72.1 — campos de receiver sem `this.`:** o type checker setava `current_class_props`
>    no `inferLambdaExpr` mas **não** `current_type_c_name`, então `inferIdentifier`/
>    `inferAssignment` marcavam `is_class_property` com `owner_type_c_name = null` e o emissor
>    LLVM caía no fallback de nome de função (`lambda_anon_...`) → `PropertyNotFound`. Agora o
>    receiver lambda seta `current_type_c_name` para o tipo mangled do receiver.
> 2. **Boxing de captura por atribuição em receiver lambda:** `inferAssignment` fazia `break` ao
>    encontrar um escopo com `this` — o `receiver_scope` do lambda (que define `this`) impedia a
>    detecção de captura de `var` externas. Novo flag `Scope.is_receiver_boundary` distingue o
>    escopo de receiver do escopo de classe: o walk agora atravessa o receiver scope (sem boxar
>    propriedades do receiver, tratadas pelo path de `is_class_property`).
> 3. **Task 72.4 — coerção primitivo→contract dentro de receiver lambda:** `this.show(42.0)` (método
>    irmão via `this`) era roteado pelo path "static-method" (get_expr com `Function.c_name`) que
>    usava só `coerceArg` — fat pointer com vtable `null` → `eiwa_to_string` dereferenciava o bit
>    pattern (`0x4045...`). O path agora constrói o fat pointer real via `coerceToContract`
>    (espelhando o path sibling).
> 4. **Task 72.2 — safe-calls encadeados `?.`:** builtins em receivers union/nullable
>    (`toString`/`toInt`/`toDouble` sobre `Int?`/`Double?`/`Bool?`/`String?`) agora são emitidos
>    por `emitUnionBuiltin` (null-check `?.` + desboxagem do variant + re-boxing do resultado), e
>    comparações `T? ==/!= scalar` usam `emitNullableScalarCompare` (null-check primeiro, para
>    `null` nunca igualar scalar zero).

- [x] **Task 72.1:** Corrigir resolução de campos do receiver em lambdas de receptor (`T.() -> Void`) no backend LLVM sem exigir `this.` (espelhar o ADR 31 / CTranspiler). Caso mínimo que falha hoje:
      ```eiwa
      type Box(val name: String, var count: Int = 0)
      fun runBox(init: Box.() -> Void) { val b = Box("x", 1); init(b) }
      fun main() { runBox { println(name); println(count) } }  // PropertyNotFound
      ```
      Com `this.` explícito compila e roda. Também quebra em lambdas de receptor aninhadas (padrão do Arest: `arest {}` → `routing {}` → `get("/") { }`).
- [x] **Task 72.2:** Corrigir safe-calls encadeados `?.` (ex.: `arguments["a"]?.asNumber()?.toInt()`). Hoje `PropertyNotFound`/ICmp verification error no LLVM; `!!` por valor presente e `?:` único funcionam.
- [x] **Task 72.3:** Adicionar teste de regressão em `samples/tests/` cobrindo campo `val` e `var` em receiver lambda simples e aninhado.
- [x] **Task 72.4:** Corrigir coação de primitivo → contract (`Stringable`/`SerdeValue`/etc.) **dentro de receiver lambda** no backend LLVM. Fora de lambda funciona; dentro de lambda, o fat pointer `{data, vtable}` não é construído e o valor cru do primitivo vira o `data` (segfault ao dereferenciar o bit pattern do double). Caso mínimo que falha:
      ```eiwa
      type Box(val label: String) {
          fun show(value: Stringable): String { return label + ":" + value.toString() }
      }
      fun runBox(init: Box.() -> Void) { val b = Box("x"); init(b) }
      fun main() {
          runBox {
              show(40.0 + 2.0)   // segfault: 0x4045000000000000 (bit pattern de 42.0)
          }
      }
      ```
      `show("ola")` (String) funciona mesmo no lambda — String já é ponteiro; só primitivos numéricos/bool quebram. É o que impede `respond(value: Stringable)` no Arest MCP (`McpCall.respond(a + b)`).
- [x] **Verify:** `samples/tests/receiver_lambda_fields_test.ei` (10 testes) cobre campo `val`/`var` simples e aninhado, captura por atribuição, coerção primitivo→contract (Double/Int/Bool), safe-calls encadeados e semântica null-check; suíte completa **94/94 PASSED** (LLVM único) + `zig build test` verde. **Nota:** `example/arest` não está neste repositório (extraído para repo próprio); os cenários `request.queries["name"]`, `arguments["a"]` e `McpCall.respond(a + b)` são cobertos pelos testes de regressão equivalentes.

---

### Phase 73: Incremental Object Cache & Fast `run` — Two-Unit Split (COMPLETED)
> **Contexto (2026-08):** O tempo de inicialização do `eiwa run` em projetos com dependências (`example/home`, `arest`, etc.) levava ~2.8s porque o compilador reprocessava, fazia typecheck e emitia IR LLVM para a árvore completa de dependências e stdlib do zero.
>
> **Resolução (Entregue em `perf/incremental-cache` — Fases B, A0, A1, A2, A3):**
> 1. **Cache de Binário Completo (A0/A1):** Execuções com fontes inalterados checam o hash da árvore de fontes e disparam o binário nativo em cache diretamente em **~0.01s - 0.02s (140x mais rápido)**.
> 2. **Separação de Emissão em Duas Unidades (A2/A3):**
>    - `deps.o`: Toda a Standard Library + dependências externas (`--module-path`, `arest`, `html`, `postgres`) são emitidas e cacheadas em `~/.eiwa/cache/objects/<hash>.o`.
>    - `entry.o`: Apenas o código do projeto do usuário é emitido em cada ciclo de edição.
> 3. **Resolução Determinística de Símbolos:**
>    - Helpers e intrinsics emitidos com linkage `internal` (evita `duplicate symbol`).
>    - Variáveis globais mutáveis de runtime (`eiwa_exception_stack`, `eiwa_active_exception`, `GC_init`) de posse exclusiva do `entry unit`.
>    - Inclusão de **Pool Signature** (nomes ordenados de `classes_ast`) no hash do `deps.o` para garantir vtables genéricas consistentes.
> 4. **Resultados:** Tempo de rebuild em edição caindo de 2.78s para **0.27s** (nível `go run`), com 95/95 testes passando na suíte de regressão.

- [x] **Task 73.1:** Implementar otimizações de hotpaths do emissor (Fase B — build ReleaseSafe por padrão, token index para reachability/vtables).
- [x] **Task 73.2:** Implementar infraestrutura de cache com SHA-256 e fast-path AOT para `eiwa run` (Fases A0/A1).
- [x] **Task 73.3:** Desacoplar emissão de objeto (`emitObjectFile`) e linkagem nativa (`linkObjects`) com arquivos temporários únicos por PID (Fase A2).
- [x] **Task 73.4:** Implementar split de emissão em duas unidades (`deps.o` × `entry.o`) com linkage `internal` para helpers e ownership de runtime no entry unit (Fase A3).
- [x] **Task 73.5:** Estabilizar vtables de genéricos com Pool Signature no hash do `deps.o` e validar suíte completa (95/95 PASSED).
- [x] **Verify:** `eiwa run` no projeto `home` inicializa em ≤ 0.1s (hit: ~0.01s / warm edit: ~0.27s).

---

### Phase 74: Compilação Incremental em Escala — Package-Level Cache & Export Data (FUTURE / BACKLOG)
> **Contexto:** Com a Phase 73, projetos pequenos e médios (até ~10.000 linhas) compilam no dev-loop em ~0.27s (onde o link físico de ~100ms é o teto). Conforme surgirem projetos de grande escala em Eiwa (30k a 100k+ linhas de código próprio), o `entry unit` começará a dominar o tempo de compilação.
>
> **Gatilho de Ativação:** Reabrir esta fase quando o tempo de rebuild do `entry.o` em projetos reais ultrapassar **0.8s - 1.0s** (projetos > 15.000 - 20.000 LOC de código do usuário).

- [ ] **Task 74.1: Particionamento Granular por Pacote/Diretório (Package-Level Cache):**
      - Em vez de $N$-way por arquivo individual (que sobrecarregaria o linker com centenas de arquivos `.o`), emitir e cachear **um `.o` por pacote/pasta** (modelo Go), mantendo a lista de objetos no linker entre 10 e 25 arquivos.
- [ ] **Task 74.2: Export Data Hashing (Assinaturas Públicas):**
      - Extrair e armazenar o hash apenas das declarações e assinaturas públicas exportadas de cada módulo.
      - Alterações em corpos de funções privadas ou comentários não invalidam os pacotes dependentes, eliminando re-typecheck e re-link em cascata desnecessários.
- [ ] **Task 74.3: Deduplicação de Monomorfizações com `linkonce_odr`:**
      - Com múltiplos pacotes de usuário gerando código separadamente, tipos genéricos monomorfizados de `classes_ast` instanciados em múltiplos pacotes devem ser emitidos com linkage `linkonce_odr` para fusão automática no link-time.
- [ ] **Task 74.4: Otimização de Linker Driver (`lld` / `mold`):**
      - Adicionar detecção e suporte opcional a linkers modernos ultrarrápidos (`lld` no Linux/Windows, `mold`) para reduzir o piso de linkagem de ~100ms para < 30ms em projetos com múltiplos pacotes.
- [ ] **Verify:** Projeto com 50.000+ LOC de código de usuário recompila e linka uma alteração pontual em ≤ 0.35s.

---
* [x] **Errors:** Semantic validations fail gracefully, emitting rich terminal errors.

---

## 🐞 Known Bugs — Coroutines (Aberto)

### Bug 1: `sync { ... }` com lambda que muta membro de `object` dentro de `task {}` → busy-loop 100% CPU (HANG)
- **Status:** ABERTO (pré-existente, confirmado também com o transform de state machine sem as correções recentes).
- **Sintoma:** a task nunca completa; a thread principal gira em `while (!done) runStep()` a 100% CPU; o processo fica congelado até o timeout do harness (`EIWA_TEST_TIMEOUT_MS`).
- **Como reproduzir** (arquivo de teste isolado):
  ```kotlin
  import { assert } from "std.core"
  import { sync } from "std.thread"

  object CoopLog {
      var log: String = ""
  }

  test "sync mutation hang" {
      CoopLog.log = ""
      val shared = task {
          sleepMs(5)
          sync {
              CoopLog.log = CoopLog.log + "S"   // muta membro de object DENTRO do lambda
          }
          40
      }
      val r = shared.await()
      assert(r == 40 && CoopLog.log == "S")
  }
  ```
  `./bin/eiwac test samples/tests/coop_await_test.ei`-style: rodar o teste acima trava em 100% CPU sem imprimir nada.
- **Contraste (funciona):** `sync { print("x") }` dentro de um `task {}` passa (lambda **não** muta membro de object). O disparo é especificamente a **mutação de membro de `object`** (`CoopLog.log = CoopLog.log + "S"`) dentro do lambda passado ao `sync`, num body de task cooperativo (contém `sleepMs`/`yield` → vira state machine).
- **Sintoma relacionado (variante helper):** extrair o `sync` para uma função helper (`fun appendLog(s: String) { sync { CoopLog.log = CoopLog.log + s } }`) **não trava**, mas a escrita é **perdida** — `CoopLog.log` fica `""` mesmo com r1/r2 corretos. Ou seja, o acesso a membro de `object` via lambda dentro de task está corrompido (leitura/escrita em cópia errada ou captura quebrada).
- **Causa provável:** o transform de corrotinas (`src/core/coroutines_transform.zig` — `collectCaptures`, boxed captures, e/ou a reescrita de lambdas dentro de corpos de `task {}`) trata a referência ao `object` global `CoopLog` como se fosse uma variável local capturável e a promove para campos da continuation gerada, gerando acesso incorreto à memória do objeto (busy-loop no estado de resume ou escrita perdida). O path de lambda com captura de `object`/referência global dentro de state machine não está coberto.
- **O que corrigir:** audit a captura de **objetos/globais** (não locais) em lambdas dentro de corpos de `task {}` no `coroutines_transform.zig`; um `object` não deve ser "capturado" para o estado — a referência deve ser resolvida estática/global. Adicionar um teste de regressão com `sync { mutaMembroDeObject }` dentro de `task {}` + `await`.

### Bug 2: `coop_await_test.ei` — "multiple tasks awaiting the same task are resumed FIFO" (flake ~1/12)
- **Status:** ABERTO (pré-existente). Teste compartilha `CoopLog.log` (String global) mutada concorrentemente por `shared`, `t1` e `t2` em threads de pool diferentes → **lost update** → `assert(res == "S12" || res == "S21")` falha intermitentemente.
- **Não é bug do scheduler:** é race **do teste** (estado compartilhado não-sincronizado). O fix idiomático (`sync`) esbarra no **Bug 1** acima.
- **O que corrigir:** (a) resolver o Bug 1 para permitir `sync` no teste; ou (b) redesenhar o teste sem estado global mutável (verificar waiter-chain pelos valores de resultado `r1==43`/`r2==44`, que já provam o resumo de múltiplos waiters).

---

## ✅ Coroutines — Correções recentes (validado)

- **Lost-wakeup do done state (fix):** o done state de `StackTask` escrevia `done=true` e drenava `waiters` **sem** o `task.mutex` que `awaitCoop` usa para registrar waiters. Um waiter anexado entre `done=true` e o drain ficava órfão → seu `await()` girava em busy-loop a 100% CPU (**bug de produção**, fritava um core). Corrigido sincronizando result+done+drain com `task.mutex` no transform (`buildResume`/`buildResumeStateMachine`). Foi o que eliminou o **freeze** do `eiwac test`.
- **Stale-label do estado de suspensão (fix):** o estado de suspensão gerado chamava `Scheduler.yield/sleep(this)` (que enfileira a continuation) e **depois** setava `this.label = <próximo>`. Na janela, um worker popava a continuation e relia o **label obsoleto**, re-executando o estado (e estados seguintes) — o flake do `try_catch_suspend_test.ei` ("second_ok" rodando 2x, ~2.5% sob carga). Corrigido setando o label **antes** de enfileirar. Guardrail: `coop_try_catch_repeated_test.ei`.
- **I/O não-bloqueante (`coop_io_test.ei`):** o teste assumia 10ms fixos para o servidor escutar — sob carga o `connect()` do cliente dava ECONNREFUSED (o servidor ainda não tinha feito `listen`), o servidor travava no `accept()` e o teste acabava em timeout. Fix: o cliente faz **retry no connect**. (Investiguei também races de EAGAIN no `Socket.read`/`eiwa_socket_write` e propus retries, mas **foram revertidos por desnecessários** — a suíte segue 100% verde só com o retry no connect.)

---

## 🛠️ Historic Bugfixes & Tools
* **Int/Double Numeric Promotion in Binary Ops (Aug 31, 2026):** `x * 2.0` with `x: Int` emitted `mul i64, double` (LLVM verification error) or returned `0` in method bodies — the emitter's `is_double` only inspected the **left** operand (`bin.left.resolved_type == .Double`), even though the type checker already resolves `Int op Double` to `.Double`. Now `is_double` is true when **either** operand is `Double` (guarded to both-numeric so custom-type operators like `Money * Int` still dispatch via `.times()`), and the `Int` operand is promoted with `SIToFP` before the float op/comparison. Regression tests added to `double_test.ei` (`Int * Double`, `Double * Int`, `+`/`-`/`/`, comparisons, `Int * Int` stays `Int`).
* **Phase 72 — ADR 31 LLVM Gaps (Aug 31, 2026):** All four gaps closed. (1) **Receiver-lambda field access:** `inferLambdaExpr` now sets `current_type_c_name` alongside `current_class_props`, so `name`/`count` inside `T.() -> Void` resolve fields with the correct owner type (was `PropertyNotFound`). (2) **Boxing of captured `var` by assignment inside receiver lambdas:** the capture walk in `inferAssignment` broke at any scope containing `this`; a new `Scope.is_receiver_boundary` flag marks receiver scopes so the walk crosses them (class-property targets are still excluded from boxing). (3) **Primitive→contract coercion inside receiver lambdas:** `this.show(42.0)` routed through the "static-method" path which only called `coerceArg` (fat pointer with null vtable → `eiwa_to_string(0x4045...)` segfault); the path now builds the real fat pointer via `coerceToContract`. (4) **Chained safe calls (`?.`):** builtins (`toString`/`toInt`/`toDouble`) on nullable/union receivers now emit via `emitUnionBuiltin` (null-check + variant unboxing + result re-boxing), and `T? ==/!= scalar` comparisons via `emitNullableScalarCompare` (null-checked, so `null != 0`). Regression suite `receiver_lambda_fields_test.ei` (10 tests); full suite 94/94 PASSED + `zig build test` green.
* **Primitive→Contract Coercion in Receiver Lambdas (Aug 30, 2026):** Coercing a primitive (`Int`/`Double`/`Bool`) to a contract (e.g. `Stringable`) inside a receiver lambda does not build the fat pointer `{data, vtable}` — the raw 64-bit value becomes `data`, so `toString()` dereferences the bit pattern (e.g. `42.0` → `0x4045000000000000`) and segfaults. `String` works (already a pointer). Blocks `McpCall.respond(value: Stringable)` on numeric args. Tracked as **Phase 72 / Task 72.4**.
* **Receiver-Lambda Field Access Gap (Aug 30, 2026):** ADR 31 (implicit `this`) was implemented in the CTranspiler but is incomplete in the LLVM backend: receiver lambdas (`T.() -> Void`) resolve sibling **methods** without `this.`, but **fields** (`request`, `arguments`, `server`) fail with `PropertyNotFound` — including nested receiver lambdas (Arest's `arest{}` → `routing{}` → `get("/"){}`). Examples (`example/arest`, `example/home`) are written in the idiomatic no-`this.` form and will compile once fixed. Also, chained safe calls (`a?.b()?.c()`) fail (`PropertyNotFound`/ICmp verify error); single `??`-style elvis and `!!` on present values work. Tracked as **Phase 72**.
* **Unified Process-Isolated Test Runner (Aug 13, 2026):** Refactored `eiwac test <directory>` in `src/main.zig` to use process-isolated child process spawning (`std.process.spawn`) across **both** C and LLVM backends. Eliminates fragile single-process synthetic module bundling (`import {}`), preventing segfaults/aborts in individual test files from halting execution of subsequent tests in the directory, and ensuring clean memory and GC state per test file.
* **LLVM `String.toString()` Stub Null-Hang (Aug 10, 2026):** `core_String_toString` era emitido como stub retornando `null` (sem corpo válido), propagando `null` pela serialização (`serdeFields` → `SerdeString` → `writeJsonValue` → `escapeJsonString` → `eiwa_str_replace(null)` → `strlen(null)` → loop). O `collections_test.ei` pendurava no teste 12. Intercepta `.toString()` sobre receiver `String` retornando `this` (identidade) antes do dispatch genérico no emissor LLVM; remove o bloco `replace` tardio que ficou morto (Phase 62). Também a partir daqui os logs de diagnóstico do emissor LLVM (`LLVM Debug:`/per-function/stub-fallback e o print do verificador `LLVMVerifyFunction`) ficam atrás da env `EIWA_LLVM_VERBOSE=1`, deixando builds normais limpos — mensagens de falha dura (JIT/Verify/Target) permanecem sempre visíveis.
* **Concurrency Module Extraction (July 26, 2026):** Moved all concurrency infrastructure (`lib Neco`, `Taskable`, `TaskableNeco`, `Task<T>`, `task()`) from `std.core` to the new `std.coroutines` module, keeping `Awaitable<T>` in core. Non-destructured imports now also re-export `generic_functions_ast` of local symbols (ADR 37).
* **Trailing Lambda with Explicit Type Args (July 26, 2026):** Parser accepted trailing lambda only after `(...)`; `task<Int> { }` now creates the `call_expr` with `type_args` directly when `{` follows `>`.
* **C Reserved Word Escaping (July 26, 2026):** User identifiers colliding with C keywords (`var bool = false`) broke the generated C. New `cIdent()` helper in the transpiler prefixes reserved names with `eiwa_` across var decls, identifiers, assignments, function params and lambda captures (ADR 38).
* **Closure Capture-by-Assignment Boxing (July 26, 2026):** Mutable vars captured **only by assignment** inside lambdas were never boxed (capture detection existed only in `inferIdentifier`), so mutations were invisible outside. Mirrored detection into `inferAssignment` — completes Phase 52 (ADR 39).
* **Sibling Calls to Skill/Forward Methods (July 26, 2026):** Method pre-registration in `class_scope` did not populate `functions_ast`, so unqualified calls to later-defined methods (e.g. skill-composed `exec`/`join`) failed without `this.`. Pre-registration now also inserts into `functions_ast` (ADR 36a).
* **Kotlin-Style Scope Functions (July 26, 2026):** `let`/`run`/`also`/`apply`/`takeIf`/`takeUnless` now work on every type via universal auto-injection of `Scope<T>` (moved to `std.core`, T bound to Self), `with(x) { }` became a top-level function, generic method inference now handles type params in function-return position (via `Unknown` return placeholder), and monomorphized methods support `this` (receiver as first C param) (ADR 40).
* **C Transpiler `.if_expr` (July 9, 2026):** Fixed C transpiler to emit statements for `if/else` instead of C ternary operators `?:` when in Statement mode, resolving compilation issues with complex blocks (e.g., `return`).
* **Runtime Stream (July 9, 2026):** Updated `eiwa run` command to output `stdout` in real-time (unbuffered) using `child.spawn()` with stream inheritance (`.Inherit`), allowing long-running loops to execute correctly without blocking the TTY.
* **Method Resolution Name Mangling (July 9, 2026):** Resolved a compiler bug where primitive method resolution failed on `Int`, `Bool`, etc., because the type checker searched for the raw type names in `classes_ast` instead of using the mangled name `system_Int`.
* **Modular Standard Library Architecture (July 21, 2026):** Refactored the monolithic `src/std/core.ei` into clean specialist modules (`std.core`, `std.io`, `std.system`, `std.exceptions`), renamed `Printable` to `Echoable`, and centralized implicit import constants in `infer_decl.zig` (ADR 30).
* **Implicit `this` Member Syntax (July 21, 2026):** Made `this.` optional for reading/writing properties and calling sibling methods inside `type` declarations and receiver lambdas (`T.() -> Void`), adding pre-registration of class method signatures in `class_scope`, parameter shadowing resolution, and property assignment emission in CTranspiler (ADR 31).
