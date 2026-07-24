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

### Phase 20: LLVM Native Emitter & Release Pipeline (PENDING / LATER)
Replacing the temporary C code generation (`temp_out.c` ──> `zig cc`) with a direct LLVM IR emitter constructed in-memory. This eliminates C transpilation overhead and enables advanced low-level control.
- [ ] **Task 20.1:** Add support for the `--release` flag in the CLI (`eiwa build --release file.ei`).
- [ ] **Task 20.2:** Build `llvm_emitter.zig`, bypassing the C backend, and translating the Resolved AST directly into in-memory LLVM structures using LLVM-C API bindings (`@cImport` of LLVM-C headers in Zig) to construct modules directly in memory.
- [ ] **Task 20.3:** Hook up LLVM optimization passes (`-O3` for release and `-O0` for development/run commands) to generate native optimized binaries.
- [ ] **Task 20.4:** Build-Time Optimizations (Speed up Dev Loops):
  - Avoid writing textual LLVM IR (`.ll`) files and invoking the `llc` command line tool, keeping all IR generation and assembly generation in-memory.
  - Skip writing intermediate C code to disk and spawning child processes (`zig cc`/`clang`).
  - Bypass Clang's parsing/typechecking stage of transpiled C code.
- [ ] **Task 20.5:** Runtime Performance Enhancements:
  - **Precise Garbage Collection (Stack Maps):** Emit stack map metadata so the GC knows exactly where references live, replacing the slow, conservative scans of Boehm GC.
  - **Tail Call Optimization (TCO):** Use LLVM's `tail` or `musttail` markers to optimize recursive function calls and prevent stack overflows.
  - **Custom Calling Conventions:** Optimize register allocation and parameters passing for the Eiwa runtime instead of complying with standard C ABI.

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

### Phase 40: Multi-Pass Compiler Architecture Refactoring (Crystal/Kotlin Style) (PLANNED)
Refactor the Eiwa compiler from file-by-file recursive typechecking to a global, multi-pass type resolution architecture inspired by Crystal and Kotlin to natively support project-wide namespaces and circular dependencies.
- [ ] **Task 40.1:** Refactor file resolution to support a global Parsing Pass. Scan all files in the dependency graph starting from the entry point (`main.ei`) and load their parsed ASTs into a shared registry, rather than recursively compiling imports on-the-fly.
- [ ] **Task 40.2:** Implement Type and Signature Declaration Pass. Walk all parsed ASTs and populate a global symbol table with all class, object, and function types and signatures, leaving bodies/initializers un-typechecked.
- [ ] **Task 40.3:** Implement Semantic Body Validation Pass. Typecheck function bodies, method definitions, and initializers using the populated global symbol table. Resolves circular imports and cross-file type dependencies natively.
- [ ] **Task 40.4:** Deduplicate Transpiler Output. Update `CTranspiler` to leverage the global registry, ensuring each standard library module is transpiled exactly once without duplicate C definitions.
- [ ] **Verify:** Run a test verifying circular dependencies between user classes (e.g. `class User` referencing `class Group` and vice-versa) compiles and executes successfully.

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

### Phase 42: Null Safety on Contract Receivers (PENDING)
Contract-typed receivers are erased to `void*` and dispatch dynamically through `eiwa_find_vtable`. The safe-call path (`?.`) currently ignores the null check for contract method calls, and nullable contract types (`Drawable?`) are untested — a null receiver segfaults instead of short-circuiting.
- [ ] **Task 42.1:** Emit the null short-circuit (`(obj) == 0 ? 0 : dispatch`) for `?.` calls on contract-typed receivers in the C Transpiler (`expression.zig` contract dispatch branch).
- [ ] **Task 42.2:** Validate nullable contract types end-to-end: `val d: Drawable? = null`, `d?.draw()`, `d ?: fallback`, and `!!` assertions on contracts.
- [ ] **Task 42.3:** TypeChecker: reject non-safe member access on nullable contract receivers with the standard null-safety error.
- [ ] **Verify:** Tests covering `null` contract references using `?.`, `?:` and `!!` pass without crashes.

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

### Phase 50: Monomorfização Real (Generic Method & Generic Functions) (IN PROGRESS)
> ⚠️ **Regra:** `zig build && ./zig-out/bin/eiwa test` (125+ testes) deve passar **antes** de avançar para a próxima etapa. Cada etapa só começa quando autorizado.
>
> **Nota:** Esta fase implementa o suporte a monomorfização real de funções e métodos genéricos, que é uma dívida técnica herdada da Fase 36.
>
> **Estado atual (23 Jul 2026):** Etapa 0 completa. Etapa 1 parcial (só `type_decl`).
>
> **Ordem de execução:** Etapa 0 → Etapa 1.
> A cada etapa, esperar autorização antes de prosseguir.

#### Etapa 0 — Type Params em `contract` e `skill` (COMPLETED)
- [x] **Task 50.0.1:** Parser: `contract Awaitable<T>` e `skill Foo<T>` — `<T>` opcional após o nome
- [x] **Task 50.0.2:** AST: campo `generic_params` em `contract_decl` e `skill_decl`
- [x] **Task 50.0.3:** Type checker: registro de contracts/skills genéricos em `local_symbols`, early return no corpo
- [x] **Task 50.0.4:** Resolução de type params em constraints (`skill Foo : Awaitable<T>`)
- [x] **Verify:** Contract/skill com type param parseiam e registram corretamente

#### Etapa 1 — Monomorfização (PARCIAL — só `type_decl`)
- [x] **Task 50.1.1:** Mecanismo de clonagem de AST com substituição de type params (`cloneNode`, `cloneTypeRef`)
- [x] **Task 50.1.5:** Tipos genéricos (`type Task<T>`) monomorfizados via `monomorphizeClass`
- [ ] **Foundation fixes:** `String` como built-in em `resolveTypeRef`; `String ↔ Custom(String)` em `isCompatible`; transpiler mapeia `Custom(String)` → `core_String*`
- [ ] **Task 50.1.2:** Trigger no type checker: `inferCall` clona e type-check **funções** genéricas monomorfizadas
- [ ] **Task 50.1.3:** Transpiler: gera função C separada por instância (nome mangled)
- [ ] **Task 50.1.4:** Cache de instâncias para evitar duplicação
- [ ] **Verify:** `zig build && ./zig-out/bin/eiwa test` passa; funções genéricas com `T` funcionam

### Phase 51: Refatoração de `Task<T>` (Corotinas 100% em Eiwa) (PLANNED)
> **Dependência:** Monomorfização Real (Fase 50) concluída.
>
> **Nota:** Plano detalhado em `docs/plano_mono_task.md`. O destino final é `Task<T>` 100% em Eiwa via `contract + skill + lib {}` (neco — https://github.com/tidwall/neco), removendo todos os casos especiais (special cases) do compilador.
>
> **Ordem de execução:** Etapa 1 (Remover Special Cases) → Etapa 2 (Arquitetura Final).

#### Etapa 1 — Remover Special Cases de `Task<T>`
- [ ] **Task 51.1.1:** `fun task<T>` em std/core.ei usa monomorfização em vez de special case
- [ ] **Task 51.1.2:** Construtor `Task<T>` usa `lib {}` (neco) em vez de C inline `({ })`
- [ ] **Task 51.1.3:** Remover special case `task()` em `infer_call.zig:44`
- [ ] **Task 51.1.4:** Remover special case `.await()` em `infer_member.zig`
- [ ] **Task 51.1.5:** Remover special case `Task` codegen em `expression.zig:373`
- [ ] **Task 51.1.6:** Remover special case `.await()` codegen em `expression.zig:481`
- [ ] **Task 51.1.7:** Remover special case `cType("Task")` em `core.zig:55`
- [ ] **Task 51.1.8:** Remover `src/runtime/fiber.c` e `src/runtime/fiber.h` (substituído por neco)
- [ ] **Verify:** `zig build && ./zig-out/bin/eiwa test` passa; `task_test.ei` passa sem special cases

#### Etapa 2 — Arquitetura Final: Contract + Skill + neco
- [ ] **Task 51.2.1:** `contract Awaitable<T>` em `std/core.ei`
- [ ] **Task 51.2.2:** `skill TaskNeco : Awaitable<T>` com `await()` via neco
- [ ] **Task 51.2.3:** `lib {}` binding para neco em `src/runtime/third_party/neco/`
- [ ] **Task 51.2.4:** `type Task<T>` compõe `+ TaskNeco`, construtor cria co-rotina via neco
- [ ] **Task 51.2.5:** `fun task<T>(block)` factory retorna `Task<T>`.new(block)
- [ ] **Verify:** `zig build && ./zig-out/bin/eiwa test` — suite completa passa; zero hacks no compilador

> **Destino final:** `Task<T>` 100% em Eiwa, `contract Awaitable<T>` + `skill TaskNeco` + neco em third_party, zero special cases, zero `makecontext`/`_XOPEN_SOURCE`.

## ✅ Definition of Done (Per Phase)
* [x] **Security/Lint:** No memory leaks in tests (utilizing `std.testing.allocator` across internal Zig modules).
* [x] **Build:** `zig build test` and `zig build run` execute successfully.
* [x] **Errors:** Semantic validations fail gracefully, emitting rich terminal errors.

---

## 🛠️ Historic Bugfixes & Tools
* **C Transpiler `.if_expr` (July 9, 2026):** Fixed C transpiler to emit statements for `if/else` instead of C ternary operators `?:` when in Statement mode, resolving compilation issues with complex blocks (e.g., `return`).
* **Runtime Stream (July 9, 2026):** Updated `eiwa run` command to output `stdout` in real-time (unbuffered) using `child.spawn()` with stream inheritance (`.Inherit`), allowing long-running loops to execute correctly without blocking the TTY.
* **Method Resolution Name Mangling (July 9, 2026):** Resolved a compiler bug where primitive method resolution failed on `Int`, `Bool`, etc., because the type checker searched for the raw type names in `classes_ast` instead of using the mangled name `system_Int`.
* **Modular Standard Library Architecture (July 21, 2026):** Refactored the monolithic `src/std/core.ei` into clean specialist modules (`std.core`, `std.io`, `std.system`, `std.exceptions`), renamed `Printable` to `Echoable`, and centralized implicit import constants in `infer_decl.zig` (ADR 30).
* **Implicit `this` Member Syntax (July 21, 2026):** Made `this.` optional for reading/writing properties and calling sibling methods inside `type` declarations and receiver lambdas (`T.() -> Void`), adding pre-registration of class method signatures in `class_scope`, parameter shadowing resolution, and property assignment emission in CTranspiler (ADR 31).
