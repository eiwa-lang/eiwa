<p align="center">
  <a href="https://eiwa.dev" target="_blank" rel="noopener noreferrer">
    <img src="https://eiwa.dev/assets/owl-card.png" alt="Eiwa Mascot" width="160">
  </a>
</p>

<h1 align="center">Eiwa Programming Language</h1>

<p align="center">
  <strong>Build software with clarity.</strong><br>
  A modern, pragmatic, statically typed, natively compiled systems language with Kotlin-inspired ergonomics.
</p>

<p align="center">
  <a href="https://github.com/eiwa-lang/eiwa/actions/workflows/ci.yml"><img src="https://github.com/eiwa-lang/eiwa/actions/workflows/ci.yml/badge.svg" alt="CI Status"></a>
  <a href="https://github.com/eiwa-lang/eiwa/releases"><img src="https://img.shields.io/github/v/release/eiwa-lang/eiwa?color=00B4D8&style=flat-square" alt="Latest Release"></a>
  <a href="https://eiwa.dev"><img src="https://img.shields.io/badge/website-eiwa.dev-00B4D8?style=flat-square" alt="Website"></a>
  <a href="https://eiwa.dev/#mcp"><img src="https://img.shields.io/badge/MCP-eiwa.dev%2Fmcp-9B5DE5?style=flat-square" alt="Live MCP AI Endpoint"></a>
  <a href="https://eiwa.dev"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey?style=flat-square" alt="Cross Platform"></a>
</p>

---

Eiwa combines the elegant syntax of **Kotlin** with the sheer speed, small binaries, and portability of **native machine code**. 

Instead of running inside a heavy JVM or relying on interpreted bytecode, Eiwa compiles via **LLVM** directly into standalone executables. It delivers sub-second feedback during development (~0.01s warm runs) and uncompromising performance in production, coupled with a conservative Garbage Collector (**Boehm GC**) for leak-free memory safety without GC pause spikes or reference cycle headaches.

---

## ⚡ Quick Install

Install the latest prebuilt toolchain for your operating system in seconds:

### macOS & Linux
```bash
curl -fsSL https://eiwa.dev/install.sh | sh
```

### Windows (PowerShell)
```powershell
irm https://eiwa.dev/install.ps1 | iex
```

> **Prerequisites:** Eiwa links dynamically against LLVM 21+ and Boehm GC (`brew install llvm@21 bdw-gc` on macOS, or `sudo apt install llvm-21-dev libgc-dev` on Linux).

---

## 🚀 60-Second Quick Start

The **`eiwa` CLI** is your all-in-one developer command center. Scaffold, manage dependencies, test, and run your project with zero friction:

```bash
# 1. Create a new project
eiwa init my-app && cd my-app

# 2. Add an ecosystem library (e.g. declarative HTTP REST server)
eiwa add eiwa-lang/arest

# 3. Run with instant sub-second feedback
eiwa run

# 4. Run the native test suite
eiwa test

# 5. Build an optimized standalone native binary
eiwa build
```

---

## 🌟 Why Eiwa?

| Feature | Eiwa | Traditional Languages |
| :--- | :--- | :--- |
| **Execution** | **Native Machine Code (LLVM)** with instant AOT cache | Heavy JVM startup or slow interpreters |
| **Type Model** | **Composition over Inheritance** (`type`, `contract`, `skill`, `object`) | Fragile base classes, deep class hierarchies |
| **Null Safety** | **Strict Compile-Time Safety** (`Type?`, `?.`, `?:`, `!!`, smart casting) | Runtime NullPointerExceptions |
| **Concurrency** | **Stackless Coroutines** (`task {}` / `.await()`) + pure Scheduler | OS thread bloat or heavy coroutine runtimes |
| **Paradigms** | **Dual Paradigm** (OOP methods or decoupled receiver extensions) | Forced rigid OOP or procedural struct boilerplate |
| **Tooling** | **Git-First Decentralized Packages** + Built-in Testing | Centralized registry gatekeepers + external test runners |
| **AI Ready** | **Live MCP Endpoint (`eiwa.dev/mcp`)** for IDEs & LLMs | Hallucinating LLMs that confuse syntax with Kotlin |

---

## 💡 Code at a Glance

### 1. Modern Web APIs (`arest`) & Stackless Coroutines
Declarative HTTP routes, JSON payloads, and cooperative asynchronous tasks:

```kotlin
import { arest } from "arest.arest"
import { MutableMap } from "std.collections"

arest(8080) {
    health()

    routing {
        get("/hello") {
            respondText("Hello from Eiwa!")
        }

        get("/async-data") {
            // Launch concurrent tasks without OS thread overhead
            val taskA = task { fetchRemoteScore("service-a") }
            val taskB = task { fetchRemoteScore("service-b") }

            val score = taskA.await() + taskB.await()
            respondJson("{\"totalScore\": $score}")
        }
    }
}
```

### 2. Composition Over Inheritance (No Classes, No Fragile Hierarchies)
Reusable behaviors via `skill`, pure polymorphic interfaces via `contract`, and concrete state via `type`:

```kotlin
contract Notifier {
    fun send(msg: String)
}

// A skill provides reusable behavior without carrying mutable state
skill EmailAlert : Notifier {
    fun alert(title: String) {
        send("[ALERT] $title")
    }
}

// Composes contract implementation and skill behavior
type User(val email: String) : Notifier + EmailAlert {
    implement fun send(msg: String) {
        println("Sending to $email: $msg")
    }
}

val user = User("alice@eiwa.dev")
user.alert("Deploy succeeded!") // "Sending to alice@eiwa.dev: [ALERT] Deploy succeeded!"
```

### 3. Your Syntax, Your Paradigm (OOP vs. Decoupled Extensions)
Both styles compile natively with zero abstraction cost and identical call syntax:

```kotlin
// Option A: Encapsulated OOP (Java / C# style)
type Member(val name: String, val role: String) {
    fun isModerator(): Bool = role == "admin" || role == "mod"
    fun greet(): String = "Welcome, $name"
}

// Option B: Decoupled Extensions (Go / Rust style)
type Customer(val name: String, val role: String)

fun Customer.isModerator(): Bool = this.role == "admin" || this.role == "mod"
fun Customer.greet(): String = "Welcome, ${this.name}"

// Both are invoked identically and statically dispatched:
val member = Member("Alice", "admin")
val customer = Customer("Bob", "mod")

println(member.greet())
println(customer.greet())
```

### 4. Epoch-First Time API, Native Collections & Built-in Testing
Time mathematics, literal collections (`[1, 2, 3]` and `["key" of "value"]`), and zero-dependency test suites:

```kotlin
import { date, hours, now, Time, Duration } from "std.time"
import { assert } from "std.core"

type Flight(val destination: String, val departure: Time) {
    fun isDelayed(): Bool = now() > departure

    // Operator Overloading
    operator fun plus(delay: Duration): Flight {
        return Flight(this.destination, this.departure + delay)
    }
}

// Literals: Lists and Maps ('of' infix operator)
val airports = ["GRU" of "São Paulo", "NRT" of "Tokyo"]
val flight = Flight("Tokyo", now() + hours(2))

// Native First-Class Test Suite
test "flight delay calculation" {
    val initial = Flight("Paris", now())
    val delayed = initial + hours(3)

    assert(delayed.departure > initial.departure)
}
```
Run tests instantly with:
```bash
eiwa test
```

---

## 🤖 AI & IDE Integration via MCP

Eiwa is built from the ground up for the AI generation. Connect **Antigravity**, **Cursor**, **VS Code**, or **Claude Code** to the live Model Context Protocol (MCP) server so your assistant has 100% native knowledge of Eiwa syntax, coroutines, and stdlib:

```json
{
  "mcpServers": {
    "eiwa": {
      "serverUrl": "https://eiwa.dev/mcp"
    }
  }
}
```

> **What your AI agent learns instantly:**
> - Full Composition Type System rules (`type`, `contract`, `skill`, `object`, `implement`).
> - Stackless coroutine patterns (`task {}`, `.await()`, pure `Scheduler`).
> - Complete standard library definitions (`std.time`, `std.collections`, `std.fs`, `std.env`).
> - All 29 interactive language tour lessons directly from [https://eiwa.dev](https://eiwa.dev).

---

## 📦 Package Management (`eiwa.yaml`)

Eiwa uses a **git-first, decentralized package model**. No centralized registry approval queues or vendor lock-in. Reference any GitHub repository, GitLab URL, tag, branch, or commit hash:

```yaml
name: my-app
version: 0.1.0
output: bin/app

dependencies:
  arest:
    github: eiwa-lang/arest
    branch: main
  html:
    github: eiwa-lang/html
    tag: v1.0.0
  postgres:
    github: eiwa-lang/postgres
    branch: main
```

### CLI Commands Reference

| Command | Action |
| :--- | :--- |
| `eiwa init <name>` | Scaffolds a new project with `src/main.ei` and `eiwa.yaml` |
| `eiwa add <pkg>` | Adds a git dependency (e.g. `eiwa add eiwa-lang/arest`) |
| `eiwa remove <pkg>` | Removes a dependency from `eiwa.yaml` |
| `eiwa run [args]` | Executes project instantly using the cached AOT binary engine |
| `eiwa build` | Compiles project to a standalone optimized native executable |
| `eiwa test` | Automatically discovers and executes all native `test` blocks |
| `eiwa freeze` | Generates an immutable lockfile with pinned commit hashes for deterministic CI/CD |
| `eiwa update` | Updates cached repositories to their latest remote git commits |

---

## 🏛️ Ecosystem & Standard Library

Eiwa includes a rich set of native libraries:

- **`std.core`**: Primitives, assertions, printing, string manipulation, formatting.
- **`std.collections`**: Monomorphized generic `List<T>`, `Map<K, V>`, `Set<T>`, and mutable equivalents.
- **`std.time`**: Epoch-first zero-overhead `Time`, `Duration`, and calendar operations.
- **`std.fs`**: Native POSIX file system I/O, path utilities, and directory traversal.
- **`std.env`** & **`std.process`**: Environment variables, `.env` file loading, CLI argument parsing, subprocess control.
- **`std.thread`** & **`std.atomic`**: Thread pools, atomic primitives, and synchronization primitives.
- **`std.json`**: Reflection-free fast compile-time JSON encoding & decoding.
- **`std.crypto`**, **`std.uuid`**, **`std.ulid`**, **`std.money`**: Production utilities.
- **Ecosystem Packages**:
  - [eiwa-lang/arest](https://github.com/eiwa-lang/arest): High-throughput native HTTP/REST server framework.
  - [eiwa-lang/html](https://github.com/eiwa-lang/html): Declarative type-safe HTML template DSL.
  - [eiwa-lang/postgres](https://github.com/eiwa-lang/postgres): Native PostgreSQL driver.

---

## 🛠️ Contributing & Building from Source

The Eiwa compiler (`eiwac`) is written in **Zig (0.16.0)** and compiles via **LLVM 21+**.

```bash
# 1. Clone the repository
git clone https://github.com/eiwa-lang/eiwa.git
cd eiwa

# 2. Build the compiler backend (eiwac)
zig build

# 3. Build the developer CLI (written in Eiwa itself)
./bin/eiwac build -o bin/eiwa cli/src/main.ei

# 4. Run compiler unit tests
zig build test

# 5. Run the native Eiwa test suite
./bin/eiwac test
```

For more details on building across macOS, Linux, and Windows, consult the **[Setup Guide](docs/setup.md)**.

---

## 📚 Documentation & Community

- 🌐 **Official Website & Interactive Tour:** [https://eiwa.dev](https://eiwa.dev)
- 📖 **[Language Tour](docs/language_tour.md):** Full syntax reference, union types, null safety, and modules.
- 🏛️ **[Architecture Guide](docs/architecture.md):** Compiler pipeline, AST design, and LLVM emission.
- ⚖️ **[Architectural Decision Records (ADRs)](docs/decisions.md):** The engineering rationale behind Eiwa.
- 📈 **[Roadmap & Evolution](docs/roadmap.md):** Phase tracker, completed milestones, and upcoming proposals.
- 🤖 **[AI Agent Guide](AGENTS.md):** Architecture map and operational instructions for AI agents.

---

<p align="center">
  <sub>Designed with care. "Eiwa sees what others don't."</sub><br>
  <sub>© 2026 Eiwa Language Contributors.</sub>
</p>
