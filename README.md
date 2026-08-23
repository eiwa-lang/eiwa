<div align="center">
  <h1>🌌 Eiwa Programming Language</h1>
  <p><strong>A pragmatic, statically typed, natively compiled systems language with a Kotlin-inspired syntax.</strong></p>
</div>

---

Eiwa is a modern, statically-typed programming language designed to combine the elegant expressiveness of Kotlin with the sheer performance and portability of native systems languages.

**Program exactly as you know Kotlin, but with even more pragmatic features.**

Instead of running inside a heavy JVM or relying on interpreted bytecode, Eiwa compiles directly into highly optimized, standalone executables. It provides developers with an incredibly fast and lightweight loop during development (acting almost like a script), and uncompromising speed in production, generating native binaries with a remarkably low memory footprint.

## ✨ Key Features

- 💎 **Kotlin Familiarity + Pragmatism:** If you know Kotlin, you already know Eiwa. Supports `val`/`var`, implicit instantiation, expression bodies, and more.
- 🧩 **Composition over Inheritance:** No classes, no `extends`. `type` owns state, `contract` defines behavioral APIs (like interfaces), and `skill` provides reusable implementation (like traits) — code reuse through composition, polymorphism through contracts.
- ⚡ **Top-Level Execution:** Start scripting immediately without boilerplate. No `fun main()` required unless you want it (Hybrid Main approach).
- 🛡️ **Compile-Time Null Safety:** Null is treated as a strict Union Type (`.String | .Null`). The compiler strictly forbids unsafe access, forcing the use of `?.`, `?:`, and `!!`.
- 📦 **File-Based Modules & Standard Library:** A modern module system with destructured imports (`import { fun1 } from "file.ei"`). Features an ever-growing Standard Library built natively (`std.core`, `std.math`, `std.time`).
- 🕒 **Epoch-First Time API:** Time handling done right, inspired by Go. Zero-overhead Time and Duration mathematics leveraging the language's native Operator Overloading.
- 🔁 **Native Collections:** First-class support for typed `List<T>`, `Map<K,V>`, and `Set<T>` literals — and their mutable counterparts. Write `[1, 2, 3]` for a list and `["key" of "value"]` for a map. Read and write with the familiar `collection[key]` bracket syntax.
- ⚙️ **Operator Overloading:** Overload math operators in types with explicit contracts via the `operator` modifier (e.g., `operator fun plus()`).
- 📦 **Package Manager & Projects:** The `eiwa` CLI manages projects and git dependencies out of the box — declare them in `eiwa.yaml` and `eiwa run` resolves, clones and wires everything automatically.
- 🧪 **Native Test System:** First-class testing support. Write `test "name" {}` blocks directly and run `eiwac test` for an isolated and fast native testing suite.
- 🗑️ **Memory Safe:** Native integration with a conservative Garbage Collector (Boehm GC) eliminates memory leaks without the overhead of reference counting or pausing VMs.

---

## 📖 Syntax & Language Tour

Eiwa code looks familiar and clean. If you want to deeply understand how Eiwa differs from Kotlin (Union Types, Modifiers, and File-based Imports), **[read the full Language Tour](docs/language_tour.md)**.

Here's a quick look at top-level statements, operator overloading, the native Time API, collections, and arrays:

```kotlin
// script.ei
import { date, hours, now, Time, Duration } from "std.time"
import { MutableList, MutableMap } from "std.collections"

type Flight(val destination: String, val departure: Time) {
    fun isDelayed() = now() > departure
    
    // Custom Operator Overloading
    operator fun plus(delay: Duration): Flight {
        return Flight(this.destination, this.departure + delay)
    }
}

// Top-Level execution (no `fun main()` required)

// Map literal using the 'of' infix syntax
val airports = [
    "GRU" of "São Paulo",
    "CDG" of "Paris",
    "NRT" of "Tokyo"
]

val flights = [
    Flight("Tokyo", date(2026, 12, 10)),
    Flight("Paris", now() + hours(2))
]

// Ergonomic loops over strictly typed arrays
for (f in flights) {
    if (f.isDelayed()) {
        val newFlight = f + hours(1) // Triggers `operator plus`
        print("Delayed to: " + newFlight.departure.format("HH:mm"))
    }
}
```

### 🧪 Built-in Testing
Testing is a first-class citizen in Eiwa. No external libraries or configurations required.

```kotlin
// script_test.ei
import { assert } from "std.core"
import { hours, now } from "std.time"
import { Flight } from "./script.ei"

test "adding duration to flight shifts departure" {
    val f = Flight("Tokyo", now())
    val delayed = f + hours(5)
    
    assert(delayed.departure > f.departure)
}
```
Run it with `eiwac test`.

---

## 💻 Using Eiwa (For Developers)

The **`eiwa` CLI** is the single entry point for the entire developer experience: projects, dependencies, compilation and execution. You rarely need to touch the compiler backend (`eiwac`) directly.

### Project Layout

An Eiwa project is just a directory with an `eiwa.yaml` manifest and a `src/main.ei` entry point:

```text
my-project/
├── src/
│   └── main.ei
└── eiwa.yaml
```

```yaml
name: my-project
version: 1.0.0
output: bin/my-tool   # optional, default: bin/<name>

dependencies:
  html:
    github: eiwa-lang/html
    branch: main
```

### `eiwa run` (Development)
Compiles the project (resolving and cloning git dependencies into the shared local repository on first use) and executes it instantly. Sub-second feedback, as if it were a dynamic scripting language.
```bash
eiwa run              # inside the project directory
eiwa run my-project/  # or pointing to a project directory
```

### `eiwa build` (Production)
Generates a standalone native binary with an incredibly low memory footprint, ready to be deployed. Output defaults to `bin/<name>` and is configurable via `output:` in the manifest.
```bash
eiwa build my-project/
```

### Dependencies
Declare git dependencies in `eiwa.yaml` and that's it — `eiwa` clones them once into `~/.eiwa/repository/` and wires the imports for the compiler:

```kotlin
// src/main.ei
import { html } from "html"
```

### Single-file scripts & tests
For quick scripts and the native test suite, the compiler backend `eiwac` is available directly:
```bash
eiwac run my_script.ei    # run a standalone script
eiwac test                # run test "name" {} blocks
```

---

## 🛠️ Contributing to the Compiler (For Contributors)

If you want to hack on the Eiwa compiler itself, you will need to prepare your machine. The compiler is written in **Zig** and compiles through **LLVM**, with **Boehm GC** providing memory safety.

### 1. Install Dependencies
You need **Zig (0.16.0+)**, **Boehm GC**, and **LLVM 21+** (for the native in-memory LLVM backend).
```bash
# Ubuntu / Debian
sudo apt install libgc-dev llvm-21-dev

# macOS
brew install bdw-gc llvm@21

# Windows (MSYS2 / vcpkg)
pacman -S mingw-w64-x86_64-gc mingw-w64-x86_64-llvm
# or: vcpkg install bdw-gc
```

### 2. Build the Compiler
```bash
git clone https://github.com/your-username/eiwa.git
cd eiwa
zig build
```
This generates the `eiwac` compiler binary in `./bin/`. To also build the `eiwa` CLI (written in Eiwa itself):
```bash
./bin/eiwac build -o bin/eiwa cli/src/main.ei
```
*(For a more detailed breakdown, see our [Setup Guide](docs/setup.md)).*

---

## 🏗️ Architecture & Documentation

Eiwa's compiler is fully documented. If you are curious about how we process ASTs or why we chose certain architectural paths, check out the `docs/` folder:

- 🏛️ **[Architecture Overview](docs/architecture.md)**: How the Lexer, Parser, TypeChecker, and native LLVM backend pipeline work.
- 🤖 **[AI Agent Guide](AGENTS.md)**: Standard build commands, codebase mappings, and rules for LLM agents.
- ⚖️ **[Architectural Decisions (ADRs)](docs/decisions.md)**: Why we enforce operator modifiers and how we handle Null Safety.
- 📈 **[Roadmap & Progress](docs/roadmap.md)**: The historic evolution of the compiler, completed phases, and future checklists.
- 📖 **[Language Tour](docs/language_tour.md)**: Null Safety, Operator Overloading, Modules, Collections, and more.

---

## 🛣️ What's Next? (Roadmap)

The **package manager** (`eiwa` CLI) just landed: projects with `eiwa.yaml`, git dependencies cloned into a shared local repository, and `build`/`run` commands. Next steps for it: `init`/`add`/`update`/`freeze` commands, registry dependencies and transitive resolution (MVS) — see [docs/plan_package_manager.md](docs/plan_package_manager.md).

The **composition type system** (Phase 41) also landed recently: `type`, `contract`, `skill` and `implement` replaced classes and inheritance entirely. The **native LLVM backend** (Phase 20) is the **only** backend — Eiwa compiles directly to LLVM IR, using a JIT for instant development loops and `-O3` optimization for production binaries. Concurrency is **cooperative stackless coroutines** (Phase 68): `task {}`/`await()` compiled into state machines driven by an Eiwa-pure Scheduler (timer heap + waiter chains). Other next steps include:
- **Phase 42:** Null safety on contract receivers (`?.` dispatch on nullable contracts).
- **Phase 43:** Heterogeneous contract collections (`List<Drawable>` with dynamic dispatch per element).
- **Phase 44:** Composition test coverage hardening (cross-module skills, negative fixtures).
- **Coroutines:** incremental gaps (single-shot awaits, `try`/`for` with suspension, I/O waiters) and **Phase 69 — Dispatchers/thread pool** (parallelism real, Kotlin `Dispatchers`-style) as a planned proposal in the roadmap.

*(See [docs/roadmap.md](docs/roadmap.md) for the full granular roadmap and historic evolution).*
