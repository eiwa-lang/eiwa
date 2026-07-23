# Eiwa Compiler Architecture

Eiwa is a statically typed, pragmatic programming language that uses Kotlin-inspired syntax. It is written in Zig and transpiles to C, combining high-level developer ergonomics with low-level portability and speed.

## High-Level Pipeline

The Eiwa compiler (`eiwa`) follows a classic multi-pass architecture:
1. **Frontend**: Source Code (`.ei`) -> Tokens -> Abstract Syntax Tree (AST).
2. **Core (Semantic Engine)**: AST -> Scope Resolution -> Type Checking -> Resolved AST.
3. **Backend**: Resolved AST -> Intermediate C Code -> Native Binary.

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

## 3. Backend (Dual-Strategy)

Eiwa emprega uma arquitetura de "Dual-Backend" para entregar o melhor dos dois mundos: ciclos de feedback instantâneos durante o desenvolvimento e performance extrema em produção.

### 3.1. C Transpiler (Modo Desenvolvimento / `run`)
Localizado em `src/backend/c_transpiler/`.
- Foco absoluto em **velocidade de compilação**.
- Pega a AST resolvida e emite código C intermediário puro.
- Em seguida, o CLI aciona internamente o `zig cc -O0` para gerar o binário de debug em tempo recorde (geralmente sub-segundo).
- Útil para testar a aplicação localmente e iterar rápido.

**Runtime representation of the composition model:** every `type` instance starts with an `EiwaTypeDescriptor*` header. The descriptor points to an impl table with one `{contract, vtable}` entry per implemented contract. Contract-typed values are plain `void*`; method calls on them dispatch dynamically via `eiwa_find_vtable(desc, &Contract_contract)[index]`. Concrete receivers always use direct static calls — dynamic dispatch is only paid where contracts are actually used. The same machinery powers `is` checks, smart casts, and `catch` matching against the `Throwable` contract.

### 3.2. LLVM IR Emitter (Modo Produção / `build --release`)
*Fase Futura (Pipeline de Release)*
- Foco absoluto em **performance de execução**.
- Em vez de gerar C, o compilador consumirá os *bindings* nativos do LLVM direto no Zig para emitir **LLVM IR** (Intermediate Representation).
- Aciona o pipeline de otimização agressiva do LLVM (O3), gerando um binário nativo estático, enxuto e livre das abstrações do C.

### Build System (`main.zig`)
Orquestra o fluxo inteiro. Ele decide qual pipeline do Backend acionar dependendo dos argumentos passados via CLI (`run` invoca o C Transpiler, `build --release` invocará o LLVM Emitter).
