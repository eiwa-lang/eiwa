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
- 🧪 **Native Test System:** First-class testing support. Write `test "name" {}` blocks directly and run `eiwa test` for an isolated and fast native testing suite.
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
Run it simply with `eiwa test`.

---

## 💻 Using Eiwa (For Developers)

Writing code in Eiwa is extremely lightweight. The Eiwa CLI comes with two main operational modes:

### `eiwa run` (Development)
Perfect for development. It compiles a temporary binary, executes it instantly, and cleans up the mess. You get sub-second feedback as if it were a dynamic scripting language.
```bash
eiwa run my_script.ei
```

### `eiwa build` (Production)
Perfect for distribution. Generates a standalone native binary locally with an incredibly low memory footprint, ready to be deployed to servers.
```bash
eiwa build my_script.ei
```

### `eiwa test` (Testing)
Eiwa has native test integration. Simply create files ending in `_test.ei` containing native `test "name" { }` blocks and run the test CLI.
The compiler will automatically find, group, and execute all tests locally, isolating them from your production binaries.
```bash
eiwa test
```
---

## 🛠️ Contributing to the Compiler (For Contributors)

If you want to hack on the Eiwa compiler itself, you will need to prepare your machine. The compiler is written in **Zig** and uses **Boehm GC** for the generated C code.

### 1. Install Dependencies
You need **Zig (0.13.0+)** and the Garbage Collector library.
```bash
# Ubuntu / Debian
sudo apt install libgc-dev

# macOS
brew install bdw-gc

# Windows (MSYS2 / vcpkg)
pacman -S mingw-w64-x86_64-gc
# or: vcpkg install bdw-gc
```

### 2. Build the Compiler
```bash
git clone https://github.com/your-username/eiwa.git
cd eiwa
zig build
```
This generates the `eiwa` binary inside `./zig-out/bin/`. *(For a more detailed breakdown, see our [Setup Guide](docs/setup.md)).*

---

## 🏗️ Architecture & Documentation

Eiwa's compiler is fully documented. If you are curious about how we process ASTs or why we chose certain architectural paths, check out the `docs/` folder:

- 🏛️ **[Architecture Overview](docs/architecture.md)**: How the Lexer, Parser, TypeChecker, and C Transpiler pipeline work.
- 🤖 **[AI Agent Guide](agents.md)**: Standard build commands, codebase mappings, and rules for LLM agents.
- ⚖️ **[Architectural Decisions (ADRs)](docs/decisions.md)**: Why we enforce operator modifiers and how we handle Null Safety.
- 📈 **[Roadmap & Progress](docs/roadmap.md)**: The historic evolution of the compiler, completed phases, and future checklists.
- 📖 **[Language Tour](docs/language_tour.md)**: Null Safety, Operator Overloading, Modules, Collections, and more.

---

## 🛣️ What's Next? (Roadmap)

The **composition type system** (Phase 41) just landed: `type`, `contract`, `skill` and `implement` replaced classes and inheritance entirely. The immediate next steps include:
- **Phase 42:** Null safety on contract receivers (`?.` dispatch on nullable contracts).
- **Phase 43:** Heterogeneous contract collections (`List<Drawable>` with dynamic dispatch per element).
- **Phase 44:** Composition test coverage hardening (cross-module skills, negative fixtures).
- **Phase 36:** Fiber-based concurrency & event loop runtime.
- **Phase 20:** LLVM IR Native Release Backend for maximum optimization (Production build transition).

*(See [docs/roadmap.md](docs/roadmap.md) for the full granular roadmap and historic evolution).*
