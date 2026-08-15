# Eiwa Compiler Architecture

Eiwa is a statically typed, pragmatic programming language that uses Kotlin-inspired syntax. It is written in Zig and compiles directly to **LLVM IR**, combining high-level developer ergonomics with low-level portability and speed.

## High-Level Pipeline

The Eiwa compiler (`eiwa`) follows a classic multi-pass architecture:
1. **Frontend**: Source Code (`.ei`) -> Tokens -> Abstract Syntax Tree (AST).
2. **Core (Semantic Engine)**: AST -> Scope Resolution -> Type Checking -> Resolved AST.
3. **Backend**: Resolved AST -> LLVM IR -> Native Binary (optimized by LLVM).

---

## 1. Frontend (`src/frontend/`)

### Lexer (`lexer.zig`)
Converts raw source code strings into a stream of tokens. It handles keyword recognition, operators, literals (Strings, Ints, Bools, Null), and tracks exact line/column positions for rich error reporting.

### Parser (`parser.zig`)
A Recursive Descent Parser that consumes tokens and builds an Abstract Syntax Tree (AST). 
- Implements statement parsing (variables, conditionals, loops).
- Implements expression parsing based on precedence (assignments, equality, math, method calls, property access).
- Generates data structures defined in `ast.zig`.

---

## 2. Core (`src/core/`)

### AST (`ast.zig`)
Defines the `ASTNode` structures and `TokenType` enums. Every node contains positional metadata (`line`, `column`) and an optional `resolved_type` which is populated during the Semantic pass.

Eiwa's type system is **composition-based** (ADR 25) — there is no implementation inheritance. The declaration nodes are:
- **`type_decl`** — owns state and identity; implements contracts (`:`) and composes skills (`+`).
- **`contract_decl`** — pure behavioral API (method signatures only, no state, no bodies).
- **`skill_decl`** — reusable, stateless implementation; may *require* contracts without implementing them.
- **`object_decl`** — singleton / static namespace (optionally bound to a `type` as a companion).

### Semantic Engine & TypeChecker (`type_checker/`)
The most critical part of the compiler. It ensures mathematical and logical correctness before any code generation occurs. Runs in ordered passes (ADR 23): Parsing → Type Declaration → Signature Declaration → Import Resolution → Body Validation.
- **Scope Management**: Tracks variable declarations block-by-block.
- **Type Inference**: Infers types for literals and expressions.
- **Composition Rules**: A `type` may compose a skill only if it implements every contract the skill requires; duplicate skill members must be resolved explicitly with `implement`; contract members must be provided with the `implement` keyword.
- **Skill Cloning**: Skill methods are cloned into each consuming type and type-checked in that context (same strategy as generic monomorphization).
- **Module Visibility**: Non-destructured imports only re-export symbols declared in the module itself (`local_symbols`) — transitively imported symbols never leak (ADR 26).
- **Enforcement**: Blocks compilation with rich terminal errors if incompatible types are assigned, or if `null` is accessed unsafely.
- **AST Desugaring**: Transforms high-level constructs into low-level method calls (e.g., converting `a + b` to `a.plus(b)` dynamically).
- **Compatibility Layer (`compat.zig`)**: Adapts Zig 0.16.0 unmanaged `std.ArrayList(T)` to provide managed-like ergonomics with direct `.items` slice access and formatted text writers (`.print(...)`, `.writeAll(...)`), isolating toolchain breaking changes from compiler passes.

---

## 3. Backend (Native LLVM)

Eiwa compiles directly to **LLVM IR** via the LLVM C API, delivering instant feedback loops during development and extreme performance in production.

### 3.1. LLVM IR Emitter (`src/backend/llvm_emitter/`)
The primary backend, wired to the LLVM C API from Zig (LLVM 21).
- **Development (`run`/`test`)**: the resolved AST is lowered to LLVM IR in memory and executed through a JIT engine (OrcJIT) — no intermediate files on disk, sub-second feedback loops.
- **Production (`build --release`)**: the same IR goes through LLVM's aggressive optimization pipeline (`-O3`), producing a standalone native binary with a remarkably low footprint.
- Native FFI to system libraries (Boehm GC, libcurl, libpq, POSIX) via LLVM extern declarations.

**Runtime representation of the composition model:** every `type` instance starts with an `EiwaTypeDescriptor*` header. The descriptor points to an impl table with one `{contract, vtable}` entry per implemented contract. Contract-typed values are plain `void*`; method calls on them dispatch dynamically via `eiwa_find_vtable(desc, &Contract_contract)[index]`. Concrete receivers always use direct static calls — dynamic dispatch is only paid where contracts are actually used. The same machinery powers `is` checks, smart casts, and `catch` matching against the `Throwable` contract.

### Build System (`main.zig`)
Orchestrates the whole flow, choosing the backend pipeline from CLI arguments (`run`/`test` use the JIT, `build --release` emits an optimized native binary).
