# AI Agent Guide - Eiwa Compiler Project

Welcome, AI Agent! This guide outlines the project context, technical stack, architecture, and coding guidelines for the Eiwa Compiler. Read this file before making any changes.

## 🌌 Project Overview
Eiwa is a pragmatic, statically typed, natively compiled systems language with a Kotlin-inspired syntax. 
* **The Compiler** is built from scratch in **Zig (0.16.0)**.
* **The Backend** compiles Eiwa code (`.ei`) into **LLVM IR** via the LLVM C API — executed through a JIT for development loops and optimized with `-O3` for production binaries. A C-transpilation backend remains for compatibility and is not the primary path.
* **Memory Management:** Driven by a conservative Garbage Collector (**Boehm GC**).

---

## 📐 Core Language Principles

1. **Unified Class-Only Type System (No Raw Primitive Types in User-Space):**
   - Eiwa has **NO raw primitive types** visible to the user (like Kotlin).
   - Everything visible to the user is a **`type`** (`Int`, `Double`, `Bool`, `String`, `Pointer`, etc.) defined and declared in `src/std/core.ei` (annotated with `@Primitive(...)` for internal C/LLVM backend layout representation).
   - User code interacts strictly with `type`, `contract`, `skill`, and `object`.

2. **Explicit Stdlib Declarations (No Magic Methods or Floating APIs):**
   - Every method, operator, type, or property accessible to the end user **MUST be explicitly declared** in `src/std/` (e.g. `src/std/core.ei`).
   - Compiler backend passes (C Transpiler / LLVM Emitter) **MUST NOT introduce magic methods** or hidden user-accessible APIs out of thin air without a matching declaration in the standard library.
   - If a standard feature or builtin method is backed by internal compiler intrinsics or backend instructions, it must still have its formal signature declared in `src/std/core.ei` (annotated with `@Primitive` or `@Alias` where appropriate) for documentation, IDE resolution, and architectural consistency.

---

## 🛠️ CLI & Build Commands Quick Reference
Always use these commands to build, run, and test the project:

```bash
# 1. Build the Eiwa compiler
zig build

# 2. Run the compiler's unit tests (written in Zig)
zig build test

# 3. Run an Eiwa program using the freshly built compiler
./bin/eiwac run samples/path_to_file.ei

# 4. Compile an Eiwa program to a static native binary
./bin/eiwac build samples/path_to_file.ei

# 5. Run the native Eiwa test suite (executes `test "name" {}` blocks)
./bin/eiwac test
```

---

## 🏛️ Codebase Map & Entry Points
* [src/main.zig](src/main.zig): CLI entry point. Parses commands (`run`, `build`, `test`) and drives the pipeline.
* [src/frontend/lexer.zig](src/frontend/lexer.zig): Tokenizer. Converts source into token streams.
* [src/frontend/parser.zig](src/frontend/parser.zig): Recursive Descent Parser. Generates the AST.
* [src/core/ast.zig](src/core/ast.zig): Defines AST data structures (`ASTNode`, `TokenType`). Tracks positions (`line`, `column`).
* [src/core/types.zig](src/core/types.zig): Type Checker and Scope Resolver. Resolves types, desugars operators (`+` to `.plus()`), and manages symbols.
* [src/backend/c_transpiler.zig](src/backend/c_transpiler.zig): Generates the C output.
* [src/backend/c_transpiler/eiwa_runtime.h](src/backend/c_transpiler/eiwa_runtime.h): Core runtime definitions, structures (e.g., `EiwaString`), and GC integration.
* [src/runtime/third_party/](src/runtime/third_party/): Vendored C libraries and Eiwa C wrappers. Each library's `lib` block points `@Header` directly at its own wrapper.
* [src/std/](src/std/): The Eiwa Standard Library package (written in Eiwa). Includes `std/core.ei` and `std/time.ei`.
* [samples/](samples/): Example scripts and syntax tests.
* [tests/](tests/): Automated toolchain test cases.

---

## 📚 Documentation Index
> Consult these files **on-demand**, not necessarily at the start of every session.

* [docs/architecture.md](docs/architecture.md): Compiler module layout and architectural decisions. Read when understanding the compilation pipeline or reorganizing modules.
* [docs/decisions.md](docs/decisions.md): ADRs (Architecture Decision Records). **Read before introducing new patterns or changing existing decisions** to avoid rework.
* [docs/language_tour.md](docs/language_tour.md): Full Eiwa syntax reference. Use when writing samples, tests, or `.ei` code examples.
* [docs/roadmap.md](docs/roadmap.md): Phase history, completed tasks, and pending features. Read to identify the current project state.
* [docs/tasks-backend-parity.md](docs/tasks-backend-parity.md): Operacional index of every remaining `TODO(emitter)` in the LLVM backend (GAPs, SPECIAL CASEs, WORKAROUNDs, runtime duplicates) with file:line references. Read before working on LLVM/C backend parity.
* [docs/setup.md](docs/setup.md): Dependency installation and environment setup. Only needed during initial setup.

---

## 🧱 Composition Type System Cheat-Sheet (ADR 25 / Phase 41)
Eiwa has **NO implementation inheritance** (`class`, `open`, `abstract`, and `override` are completely deleted). Reusability and polymorphism are composition-based:

| Eiwa | Closest Concept | Key Difference |
|--------|-----------------|----------------|
| **`type`** | `class` (Kotlin/Java/C#) | Holds state & identity. Cannot be extended (`no open`/no subclassing). Implements contracts (`:`), composes skills (`+`). |
| **`contract`** | `interface` (Java/C#), `trait` signature part (Rust) | Pure API signatures (no state, no impl, no constructors). Used for polymorphism and smart casting (`when (x) is Contract`). |
| **`skill`** | `trait` (Rust/Scala), `mixin` | Reusable behavior with method bodies (no state, no constructors). Borrows contracts (`:`) which are supplied by the consuming `type`. |
| **`object`** | `object` (Kotlin), static class (Java/C#) | True singleton with identity for static state & methods (`Object.member`). Bound to types via `} object {`. |

- **`implement`**: Mandatory keyword in `type` to implement contract methods or resolve skill method ambiguities.
- **Syntax Example:**
  ```kotlin
  contract Drawable { fun draw() }
  skill Shadow : Drawable { fun drawShadow() { draw() } }
  type Button : Drawable + Shadow {
      implement fun draw() { print("Button") }
  }
  ```

---

## ⚠️ Critical Rules & Gotchas for LLMs
1. **Zig Version:** Ensure compatibility with Zig `0.16.0`. Do not use deprecated API structures from older versions.
2. **Type Checking First:** Never generate code bypassing validations. All semantic checks, Null Safety, and Type Enforcements must happen in `src/core/types.zig` before calling the transpiler.
3. **Boehm GC Integration:** Memory allocation in the transpiled C code must use GC-managed hooks (like `GC_MALLOC` or `GC_MALLOC_ATOMIC`) via runtime definitions. Do not use raw malloc/free.
4. **Name Mangling:** Types, objects, skills, contracts, functions, and standard library methods use Name Mangling (e.g., `system_Int` instead of raw `Int`) in the C backend to avoid naming collisions.
5. **No Placeholders:** When writing Eiwa examples or test cases, write complete, working assertions.
6. **Task Status Tracking:** Refer to [docs/roadmap.md](docs/roadmap.md) for the historic roadmap, completed phases, and pending features.
7. **Composition Type System:** NEVER use `class`, `open`, `abstract`, or `override`. Always use `type`, `contract`, `skill`, `object`, and `implement`.

