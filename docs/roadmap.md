# Eiwa Compiler Roadmap & Progress

This document tracks the historical progress, current status, and future roadmap of the Eiwa Compiler. 

> **For AI Agents:** Use this file to identify the current phase, check what has already been built, and check off completed tasks as you work.

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

### Phase 20: LLVM Native Emitter & Release Pipeline (IN PROGRESS)
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
- [x] **Task 20.12:** Transição Completa & Promoção do Backend LLVM a Padrão Oficial:
  - Promover o LLVM Native Emitter (`--backend=llvm`) como o backend oficial padrão da linguagem Eiwa.
  - Backend C mantido como suporte secundário legado (`--backend=c`).

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

### Phase 34: Extension Functions (PENDING)
- [ ] **Task 34.1:** Add support in the Parser for declaring extension functions (e.g., `fun String.lastChar(): String`).
- [ ] **Task 34.2:** Resolve extension methods in the TypeChecker statically (ensuring they can access public members of the receiver class).
- [ ] **Task 34.3:** Desugar extension function calls (e.g., `str.lastChar()`) to static helper function calls (e.g., `lastChar(str)`) in the C Transpiler.

### Phase 35: Standard Library HTTP & Networking (`std.http` & `std.net`) (COMPLETED)
- [x] **Task 35.1:** Design `std.net` defining Socket and TCP abstractions using POSIX socket FFI bindings.
- [x] **Task 35.2:** Implement `std.http.Client` binding to C `libcurl` to support standard HTTP methods (GET, POST) and return `std.http.Response`.
- [x] **Task 35.3:** Implement `std.http.Server` utilizing `libuv` or lightweight non-blocking sockets with custom C wrappers for event dispatching.
- [x] **Task 35.4:** Write integration tests and sample scripts verifying basic HTTP requests and responses.

### Phase 36: Concorrência Estruturada — Fibras + Tasks (UNIFIED — merged former Phase 36 + Phase 50) (COMPLETED)
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

### Phase 51: Refatoração de `Task<T>` (Corotinas 100% em Eiwa) (DONE)
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
- [ ] **Task 59.6b:** Comandos `init`, `add`, `remove`, `update`, `freeze` no CLI.
- [ ] **Task 59.7:** Resolução transitiva (MVS), arquivos `resolutions/` e `eiwa.freeze`.
- [ ] **Task 59.8:** Dependências de registry (versões exatas) quando houver registry.

---

## ✅ Definition of Done (Per Phase)
* [x] **Security/Lint:** No memory leaks in tests (utilizing `std.testing.allocator` across internal Zig modules).
* [x] **Build:** `zig build test` and `zig build run` execute successfully.
* [x] **Errors:** Semantic validations fail gracefully, emitting rich terminal errors.

---

## 🛠️ Historic Bugfixes & Tools
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
