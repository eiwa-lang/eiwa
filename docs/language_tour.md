# The Eiwa Language Tour

Eiwa was born from a desire to write low-level systems code with the ergonomics of modern high-level languages like Kotlin. 

While Eiwa shares an almost identical baseline syntax with Kotlin, it operates in a fundamentally different environment: **there is no JVM, no massive standard library, and no runtime interpreter.** Everything is compiled directly to native code via LLVM (with a JIT for instant development loops and `-O3` optimization for production), backed by a highly optimized embedded Garbage Collector.

Because of this, some architectural decisions differ from Kotlin to provide extreme performance and absolute safety.

### Core Philosophy: Unified Type System & Explicit Declarations
- **No Primitive Types:** Eiwa has **no raw primitive types** visible to user code. Like Kotlin, every value is an instance of a `type` (`Int`, `Double`, `Bool`, `String`, `Pointer`, etc.). Built-in types are declared in `std.core` (`src/std/core.ei`) annotated with `@Primitive(...)` for backend layout mapping.
- **No Magic APIs:** Everything accessible to user code (methods, properties, operators) **must be explicitly declared in the standard library (`src/std/`)**. The compiler backend never invents "magic" floating methods without a corresponding `type`/`contract` signature in `src/std/core.ei`.

---

## 1. Module System (File-Based Namespaces)

Eiwa adopts a modern, lightweight module system inspired by ES6 and Go. Every `.ei` file is an implicit module. You don't need to define explicit `package com.x.y` declarations at the top of your files.

To use symbols from another file, you must explicitly declare exactly what you want to import using destructuring. This prevents polluting your namespace and makes dependencies crystal clear.

```kotlin
// Assumes a file named 'math.ei' exists in the same directory.
// The .ei extension is optional and will be inferred automatically.
import { add, Vector } from "math"

fun main() {
    val v = Vector(1, 1)
    val r = add(5, 5)
}
```

**Module path resolution.** Module paths use `.` as the separator — never `/`. There are exactly three resolution rules:

| Form | Resolves against | Example |
|------|------------------|---------|
| `.x` | the **project root** (directory of the entry file) | `import { ArestBuilder } from ".arest_builder"` |
| `x` / `x.y` | the **importing file's directory** | `import { McpCall } from "mcp_call"` |
| `std.x` | the standard library package | `import { Time } from "std.time"` |

- `.mcp.mcp_builder` = `<root>/mcp/mcp_builder.ei`; `mcp.mcp_builder` = `<file_dir>/mcp/mcp_builder.ei`.
- Filesystem separators (`/`) and parent-relative prefixes (`./`, `../`, `..`) are **compile errors**. If you need a file in a parent directory, import it from the project root: `import { ArestBuilder } from ".arest_builder"`.
- The project root is the directory containing the entry file passed to `eiwa run`/`build` (or the tested directory for `eiwa test`). This keeps module paths canonical, so moving a file never silently breaks imports, and circular imports resolve to the same path instead of growing `../../..` chains.
- The `.ei` extension is optional and inferred automatically.

**The Implicit Standard Library**
Eiwa comes with a core module named `system.ei` which contains fundamental types, C-bindings, and intrinsic functions (like `print`). The compiler automatically injects an `import {} from "system"` at the top of every file, making all standard functions globally available without explicitly requiring an import statement.

*(Note: the compiler automatically performs Name Mangling to prevent collisions across files, meaning `add` inside `math.ei` becomes `math_add` in the final native binary, ensuring absolute safety).*

---

## 2. Top-Level Statements & Side-Effects

Eiwa is designed to be highly fluid for quick scripts. Because of this, `fun main()` is **optional**. You can write statements directly at the root of your file.

```kotlin
// script.ei
import { add } from "math"

// This is perfectly valid Eiwa code
val a = 10
val b = 5
print(add(a, b))
```

If your code reaches the end of the file, it exits successfully (returning `0` to the OS). If you want to force an exit with an error code, you can use the built-in `exit(code)` function natively.

**The Golden Rule of Modules (No Side-Effects):**
Top-level execution is **only allowed in your root file** (the one you pass to `eiwa run`). If an *imported* file tries to run top-level statements (like calling `print`), the compiler will strictly block it and throw an `ImportSideEffectsNotAllowed` error. 

Imported files must be "passive libraries", meaning they should only **declare** things (Functions, Types, Tests, etc.). This ensures maximum code hygiene and predictable execution paths.

---

## 3. Arrays and Loops

Eiwa features a native type system for dynamic arrays and full-featured generic **collections**, along with ergonomic `for` and `while` loops.

### 3.1 Collections and `for` Loops

The `[Type]` syntax is syntactic sugar for an immutable **`List<T>`**. Read elements with `[index]` or `.get(index)`, and check size with `.size()`. For mutation, call `.mut()` on any collection to get a `MutableList<T>` (see [Section 7.5](#75-mutability-conversion----mut-and-freeze)).

Eiwa uses an ergonomic **lambda-style `for` block** to iterate over `List<T>`, `MutableList<T>`, and native arrays:
- **Implicit parameter (`it`)**: When no parameter is specified, `it` is injected into the loop scope.
- **Explicit parameter (`name ->`)**: Define a custom parameter name.
- **Explicit typed parameter (`name: Type ->`)**: Optionally add type annotations.

```kotlin
fun main() {
    val numbers = [1, 2, 3, 4, 5]
    
    // Implicit 'it' parameter
    var sum = 0
    for (numbers) {
        sum = sum + it
    }
    assert(sum == 15)
    
    // Explicit named parameter
    var product = 1
    for (numbers) { n ->
        product = product * n
    }
    assert(product == 120)
}
```

### 3.2 `while` Loops

Classic condition-based loops are fully supported:

```kotlin
fun main() {
    var i = 0
    while (i < 5) {
        i = i + 1
    }
    assert(i == 5)
}
```

### 3.3 Loop Utility Functions (`repeat`, `loop`, `retry`)

Eiwa's standard library (`std.system`, implicitly imported into every program) provides higher-order loop helpers:

#### `repeat(count) { ... }`
Executes a block `count` times, passing the 0-indexed iteration count as `it` (or a named parameter):

```kotlin
fun main() {
    // Passes 0, 1, 2 as 'it'
    repeat(3) {
        println("Iteration: " + it.toString())
    }

    // Explicit parameter name
    repeat(4) { step ->
        println("Step " + step.toString())
    }
}
```

#### `loop { ... }`
Executes an infinite loop (convenient wrapper for continuous worker loops and server tasks):

```kotlin
fun main() {
    loop {
        println("Processing continuously...")
    }
}
```

#### `retry(times) { ... }`
Executes a block up to `times` attempts, catching any `Throwable` exceptions before retrying:

```kotlin
fun main() {
    retry(3) { attempt ->
        println("Attempt: " + attempt.toString())
        connectService()
    }
}
```

---

## 4. String Escape Sequences

Eiwa supports Kotlin-style backslash escape sequences inside double-quoted string literals. The following escape sequences are recognized and processed by the compiler:

* `\"` – Double quote
* `\\` – Backslash
* `\n` – Newline
* `\r` – Carriage return
* `\t` – Tab
* `\b` – Backspace
* `\'` – Single quote

```kotlin
fun main() {
    val escapedQuote = "Ele disse \"Ola\""
    val backslash = "C:\\eiwa\\bin"
    val multiline = "Primeira Linha\nSegunda Linha"
    
    assert(escapedQuote.length == 15) // counts exact characters (excluding the backslash escape character)
}
```

The compiler's Type Checker automatically calculates the correct length of string literals in bytes after resolving these escape sequences, ensuring complete compatibility with standard library functions and C runtime operations.

### 4.1 String Concatenation (`+`)

Strings can be directly concatenated with other `String`s, any primitive type (`Int`, `Double`, `Bool`), or any custom `type`/`object` implementing the `Stringable` contract:

```kotlin
type User(val id: Int, val name: String) : Stringable {
    implement fun toString(): String = "User(id=" + id + ", name=" + name + ")"
}

fun main() {
    val count: Int = 10
    val price: Double = 19.99
    val inStock: Bool = true
    val user = User(1, "Alice")

    // Automatic string coercion via Stringable
    val label = "Items: " + count
    val msg = "Total: $" + price + " (Available: " + inStock + ")"
    val info = "Customer: " + user
    
    assert(label == "Items: 10")
    assert(msg == "Total: $19.99 (Available: true)")
    assert(info == "Customer: User(id=1, name=Alice)")
}
```

---

## 5. Union Types & Compile-Time Null Safety

Eiwa provides first-class support for **Union Types** (`Type1 | Type2`). Union types allow a variable, parameter, or generic collection to hold values of multiple distinct types statically.

### 5.1 General Union Types (`T1 | T2`)

You can declare variables and generic containers with union types:

```kotlin
// Variable holding either a String or an Int
var payload: String | Int = "Eiwa"
assert(payload == "Eiwa")

// Re-assigning to another valid variant type of the union
payload = 42
assert(payload == 42)
```

**Multi-Type Maps (`Map<K, V1 | V2>`)**
Union types integrate natively with generic collections like `Map` and `MutableMap`:

```kotlin
import { MutableMap } from "std.collections"

fun main() {
    // Map with values that can be String or Int
    val map: MutableMap<String, String | Int> = MutableMap()
    map["name"] = "Eiwa"
    map["version"] = 1
    
    assert(map["name"] == "Eiwa")
    assert(map["version"] == 1)
}
```

### 5.2 Compile-Time Null Safety (`T | Null`)

Null Pointer Exceptions (NPEs) are the bane of native systems programming, often resulting in fatal `Segmentation Faults` in C/C++. Eiwa prevents this statically by modeling nullability as a Union Type (`T | Null` or `T?`).

In Eiwa, `null` is not a primitive value that can be assigned anywhere. It is a strictly enforced **Union Type**.

```kotlin
// 'admin' is strictly a User. It CANNOT be null.
val admin: User = User("Leo")

// 'guest' is a Union Type: (User | Null)
val guest: User? = null
val guest: User | Null // equally valid syntax 
```

If you try to access `guest.name`, the Eiwa compiler will **block the compilation**, because you are trying to access a property on something that might be `null`.

**Safe Calls:**
```kotlin
// The Elvis Operator (?:) unwraps the Union Type safely.
val finalName = guest?.name ?: "Unknown"

// The Bang-Bang Operator (!!) forces unwrap, trusting the developer.
// Use with caution!
val dangerousName = guest!!.name
```

---

## 6. Exception Handling (try-catch)

Eiwa features a native structured exception handling system using `try` and `catch` blocks. There is no exception hierarchy: any type that implements the built-in `Throwable` contract can be thrown:

```kotlin
type InvalidAgeException(val text: String) : Throwable {
    implement fun message(): String {
        return this.text
    }
}

fun checkAge(age: Int) {
    if (age < 18) {
        throw InvalidAgeException("Invalid age: " + age.toString())
    }
}
```

Exceptions propagate up function call frames until they encounter a matching handler.

### 6.1 Basic Usage
Eiwa supports two forms of `try`. The standard form catches specific exception types:
```kotlin
try {
    checkAge(15)
} catch (e: InvalidAgeException) {
    print("Error caught: " + e.message())
}
```

You can also write a bare `try` block **without any `catch` clause**. This is unique to Eiwa: any exception thrown inside is silently swallowed, making it ideal for optional or best-effort operations:
```kotlin
try {
    checkAge(15) // Exception is caught and ignored
}
```

### 6.2 Multi-Catch
You can catch multiple exceptions in a single block using the union syntax `|`. In this case, the caught exception `e` is statically typed as the `Throwable` contract (with dynamic dispatch):
```kotlin
try {
    checkAge(15)
} catch (e: InvalidAgeException | ConnectionException) {
    print("Exception caught: " + e.message())
}
```

You can also catch directly by the `Throwable` contract to handle any throwable value:
```kotlin
try {
    checkAge(15)
} catch (e: Throwable) {
    print("Exception caught: " + e.message())
}
```

### 6.3 Catch-All
If you omit the variable declaration in a `catch` block, it acts as a **catch-all** that intercepts any exception:
```kotlin
try {
    checkAge(15)
} catch {
    print("A generic error occurred.")
}
```

---

## 7. Collections (List, Map, Set)

Eiwa comes with a rich, generic standard library of collection types in `std.collections`. Collections fall into two categories: **immutable** (safe, read-only snapshots) and **mutable** (full read-write).

Import what you need:

```kotlin
import { List, MutableList, Map, MutableMap, Set, MutableSet } from "std.collections"
```

---

### 7.1 List & MutableList

`List<T>` is a **read-only** ordered sequence. Create one with a bracket literal — the same syntax as a native array:

```kotlin
val nums: List<Int> = [10, 20, 30]

// Index access with brackets
val first = nums[0]       // 10

// Size
val n = nums.size()       // 3

// Read by position
val second = nums.get(1)  // 20
```

`MutableList<T>` wraps a `List<T>` and allows mutation:

```kotlin
val items: List<Int> = [5]
val list: MutableList<Int> = MutableList(items)

list.add(10)
list.add(20)
list.set(0, 99)   // overwrite position 0
list.remove(1)    // remove by index

assert(list.size() == 2)
assert(list.get(0) == 99)
```

You can also get a `MutableList` from any existing `List` by calling `.mut()`, and convert back to an immutable `List` via `.freeze()` (see [Section 7.5](#75-mutability-conversion----mut-and-freeze)):

```kotlin
val frozen: List<Int> = [1, 2, 3]
val mutable = frozen.mut()   // MutableList<Int>
mutable.add(4)
val back = mutable.freeze()  // List<Int> again
```

**Type inference** works out-of-the-box. The compiler resolves the element type from the literal:

```kotlin
val list = MutableList([42])  // inferred: MutableList<Int>
list.add(100)
```

---

### 7.2 Map & MutableMap

Maps are associative containers. The cleanest way to create one is with the **`of` infix literal syntax** inside brackets:

```kotlin
// Immutable literal map (Map<String, String>)
val capitals = [
    "Brazil" of "Brasília",
    "France" of "Paris",
    "Japan"  of "Tokyo"
]

// Read by key using brackets (returns the value or null)
val capital = capitals["Brazil"]  // "Brasília"
val missing  = capitals["India"]  // null
```

The `of` keyword is a reserved **infix pair constructor**. Each `key of value` expression creates one entry. The compiler deduces `K` and `V` from the first pair.

`Map<K, V>` (immutable) exposes only `.get(key)` and `.containsKey(key)`.

---

### 7.3 Set & MutableSet

A `Set<T>` is an unordered collection of **unique** values backed by a `Map<T, Bool>`.

```kotlin
val tags = MutableSet(items)   // inferred: MutableSet<String>

tags.add("Eiwa")
tags.add("Zig")
tags.add("Eiwa")  // duplicate is silently ignored

assert(tags.contains("Eiwa") == true)
assert(tags.contains("Rust")   == false)
```

`Set<T>` (immutable) wraps a `Map<T, Bool>` and only exposes `.contains(element)`.

---

### 7.4 Literal Sugar Reference

| Syntax | Meaning |
|---|---|
| `[1, 2, 3]` | `List<Int>` literal |
| `["a", "b"]` | `List<String>` literal |
| `["k" of "v", ...]` | `Map<String, String>` literal (immutable) |
| `map["key"]` | read from `Map` or `MutableMap` |
| `map["key"] = val` | write to `MutableMap` |

> **Note:** The bracket literal `[x of y, ...]` always produces an **immutable** `Map`. For a mutable map you must use `MutableMap(...)` explicitly.

---

### 7.5 Mutability Conversion — `.mut()` and `.freeze()`

Eiwa collections are **immutable by default**. When you need to mutate a snapshot, call `.mut()` to get a mutable view. When you're done mutating and want to hand off a safe read-only handle, call `.freeze()`.

| Method | From | To | Description |
|---|---|---|---|
| `.mut()` | `List<T>` | `MutableList<T>` | Wraps the list for mutation |
| `.mut()` | `Map<K,V>` | `MutableMap<K,V>` | Wraps the map for mutation |
| `.mut()` | `Set<T>` | `MutableSet<T>` | Wraps the set for mutation |
| `.freeze()` | `MutableList<T>` | `List<T>` | Returns the immutable backing list |
| `.freeze()` | `MutableMap<K,V>` | `Map<K,V>` | Returns the immutable backing list |
| `.freeze()` | `MutableSet<T>` | `Set<T>` | Returns the immutable backing map |

**Pattern: build then freeze**

```kotlin
import { List } from "std.collections"

fun main() {
    // Start with an immutable snapshot
    val base: List<Int> = [10, 20]

    // Upgrade to mutable, mutate freely
    val builder = base.mut()
    builder.add(30)
    builder.set(0, 99)

    // Downgrade back to safe, immutable view
    val result = builder.freeze()
    assert(result.size() == 3)
    assert(result[0] == 99)
    assert(result[2] == 30)
}
```

**Pattern: collect into a mutable map, then share immutably**

```kotlin
import { Map } from "std.collections"

fun main() {
    val seed: Map<String, Int> = ["a" of 1]

    val m = seed.mut()
    m["b"] = 2
    m["c"] = 3

    val snapshot = m.freeze()  // safe to pass around
    assert(snapshot["b"] == 2)
}
```

> **Design note:** `.mut()` does not copy the underlying data — the mutable wrapper operates directly on the same internal storage. `.freeze()` returns a reference to that same storage as an immutable handle. This means both operations are **O(1)** regardless of collection size.

---

## 8. Ternary Operators

Eiwa provides standard ternary conditional expressions and a unique short ternary operator to simplify conditional value assignments.

### 8.1 Standard Ternary Operator

The standard ternary operator uses the classic `condition ? true_expr : false_expr` syntax:

```kotlin
fun max(a: Int, b: Int): Int {
    return (a > b) ? a : b
}
```

* **Type Safety:** The type of the ternary expression is inferred as the common compatible type of both branches. If the branches have incompatible types, the compiler will fail with a `TypeError`.
* **Right-Associativity:** The operator associates to the right, meaning nested ternaries parse naturally:
```kotlin
// In Eiwa, this evaluates as: a ? b : (c ? d : e)
val result = a ? b : c ? d : e
```

### 8.2 Short Ternary Operator

The short ternary operator `condition ? true_expr` omits the else branch. When the condition is false, it implicitly returns `null`:

```kotlin
fun getAdminRole(isAdmin: Bool): String? {
    return isAdmin ? "Administrator"
}
```

* **Nullable Union Return Type:** Because a short ternary returns `null` when false, its type is automatically promoted to a Union Type with `Null` (e.g. `String?`).
* **Nesting Flattening:** If the positive branch is already a nullable type (like `String?`), the return type is flattened to `String?` rather than nesting (e.g., `String??`).
* **Void Safety:** Since returning `null` implies a value payload, you cannot use expressions returning `Void` inside a short ternary.
```kotlin
// THIS IS A COMPILATION ERROR:
cond ? print("hello") 
```

---

## 9. Operator Overloading via Modifiers

Kotlin allows you to overload mathematical operators (like `+` and `-`) by naming a function `plus` or `minus`. Eiwa takes this a step further to prevent accidental overloads.

In Eiwa, naming a function `plus` is not enough. You **must** explicitly tag the function with the `operator` modifier. This acts as a clear contract to anyone reading the code that this function fundamentally alters the language's math operations for that type.

```kotlin
type Vector(val x: Int, val y: Int) {
    
    // The 'operator' modifier is MANDATORY.
    operator fun plus(other: Vector): Vector {
        return Vector(this.x + other.x, this.y + other.y)
    }
}

fun main() {
    val v1 = Vector(1, 2)
    val v2 = Vector(3, 4)
    val v3 = v1 + v2 // Automatically calls v1.plus(v2)
}
```

---

## 10. Pattern Matching (when Expressions)

Eiwa supports Kotlin-style `when` expressions for flexible conditional branching. It can act both as an expression (evaluating to a value) or as a statement (for side effects).

### 10.1 Basic Usage (With Subject)
You can match a subject expression against multiple values separated by commas:

```kotlin
val code = 404
val message = when (code) {
    200 -> "OK"
    401, 403 -> "Unauthorized Access"
    404 -> "Not Found"
    else -> "Unknown Error"
}
assert(message == "Not Found")
```

* **Exhaustiveness:** If `when` is used as an expression (to assign a value), the `else` branch is **mandatory**. If used as a statement, `else` is optional.

### 10.2 Smart Casting via Type Check
Eiwa integrates pattern matching with its contract-based polymorphism. If you match a stable variable against a type using `is Type`, the variable is automatically **smart-cast** inside that branch's scope:

```kotlin
contract Shape
type Circle(val radius: Int) : Shape
type Square(val side: Int) : Shape

fun printArea(shape: Shape) {
    when (shape) {
        is Circle -> {
            // 'shape' is smart-cast to Circle here
            print("Circle Area: " + (shape.radius * shape.radius).toString())
        }
        is Square -> {
            // 'shape' is smart-cast to Square here
            print("Square Area: " + (shape.side * shape.side).toString())
        }
        else -> print("Unknown shape")
    }
}
```

### 10.3 Subjectless when
If you omit the subject, the `when` expression acts as a cleaner alternative to `if-else if-else` chains. Each branch condition must evaluate to a `Bool`:

```kotlin
val x = 10
val y = 20

when {
    x > y -> print("x is greater")
    x < y -> print("y is greater")
    else -> print("they are equal")
}
```

---

## 11. The Composition Type System: `type`, `contract` & `skill`

> **Since Phase 41 / ADR 25:** Eiwa uses a composition-based type system. There are no classes — `class`, `open`, `abstract` and `override` were removed from the language.

Eiwa has **no implementation inheritance**: no superclasses, no abstract classes, no `extends`. Instead, the type system is built on five declaration types, each with a single responsibility:

| Declaration | Owns state? | Has implementation? | Can be instantiated? |
|-------------|:-----------:|:-------------------:|:--------------------:|
| `type`      | ✅ Yes       | ✅ Yes               | ✅ Yes                |
| `object`    | ✅ (static)  | ✅ Yes               | ❌ (singleton)        |
| `contract`  | ❌ No        | ❌ No                | ❌ No                 |
| `skill`     | ❌ No        | ✅ Yes               | ❌ No                 |
| `enum`      | —           | —                   | ✅ Yes                |

### 11.0 Coming from Other Languages

If you know Kotlin, Java, Rust or Scala, these concepts will feel familiar — but watch the differences:

| Eiwa | Closest concept | Key difference |
|--------|-----------------|----------------|
| `type` | `class` (Kotlin/Java/C#) | Cannot be extended. There is no `open`, no subclassing — ever. |
| `contract` | `interface` (Java/C#), `trait` signature part (Rust) | Pure signatures only. Contracts cannot require or extend other contracts — conformance is always flat. |
| `skill` | `trait` (Rust/Scala), `mixin` | A skill does **not** implement the contracts it requires. It only *borrows* them: required methods are supplied by the consuming `type`, not by the skill. |
| `object` | `object` (Kotlin), static-only class (Java/C#) | A true singleton with identity — it can hold mutable static state, not just static methods. |

The mental shift is small but important: in Eiwa you never ask *"what does this type inherit from?"* — you ask *"which contracts does it implement (`:`) and which skills does it compose (`+`)?"*

### 11.1 `type` — State and Identity

A `type` is the only declaration that holds instance state. It declares fields, constructors and methods, and composes behavior through two header operators:

* `:` — **implements** contracts
* `+` — **composes** skills

```kotlin
type Button
    : Drawable, Serializable
    + Clickable
    + Hoverable {
    // ...
}
```

#### Body Fields (`var` / `val` no corpo do `type`)

Besides the primary-constructor properties, a `type` may declare **body fields**: `var`/`val`
declared inside the type body (Kotlin-style). They are **not** constructor arguments — their
initializers run once at construction, in declaration order, with `this` available (so an
initializer can reference constructor params/properties and earlier fields).

```kotlin
type Counter(val base: Int) {
    var count: Int = 0              // mutable body field
    val label: String = "counter"   // immutable body field
    var doubled: Int = this.base * 2   // initializer references ctor property
    var note: String?               // nullable: initializer omitted → defaults to null

    fun inc() { this.count = this.count + 1 }
}

val c = Counter(10)   // fields are NOT ctor args
c.inc()               // c.count == 1, c.doubled == 20, c.note == null
```

Rules (Kotlin-inspired):
- `val` body fields **require** an initializer.
- `var` body fields of **non-nullable** type **require** an initializer.
- `var`/`val` of **nullable** type may omit the initializer → defaults to `null`.
- Assigning to a `val` body field is a compile-time error (`Cannot assign to constant property`).

### 11.2 `contract` — Behavioral Capabilities

A `contract` defines a pure API: method signatures only. No state, no constructors, no implementation, no instantiation. Contracts are how Eiwa does polymorphism.

```kotlin
contract Drawable {
    fun draw()
}
```

For empty **marker contracts** (used only for tagging and `is` checks), the braces are optional:

```kotlin
contract Shape

type Circle(val radius: Int) : Shape
```

A type implementing a contract must `implement` every method:

```kotlin
type Button : Drawable {
    implement fun draw() {
        println("drawing button")
    }
}
```

### 11.3 `skill` — Reusable Behavior

A `skill` contains implementation but no state and no identity. It cannot be instantiated. A skill may **require** contracts using `:`, but it does *not* implement them — the required methods are provided by the consuming type:

```kotlin
skill Shadow : Drawable {

    fun drawShadow() {
        // ...
    }

    fun render() {
        draw()       // provided by the consuming type
        drawShadow()
    }
}
```

A type may compose a skill **only if it implements every contract the skill requires**:

```kotlin
// ✅ Valid — Button implements Drawable, which Shadow requires
type Button : Drawable + Shadow {
    implement fun draw() {
        println("drawing button")
    }
}
```

```kotlin
// ❌ Invalid — missing the required contract
type Button + Shadow
// Compile error:
// Skill 'Shadow' requires contract 'Drawable'.
// Type 'Button' does not implement it.
```

### 11.4 Resolving Skill Conflicts

If two composed skills declare the same member, the compiler reports an ambiguity. The type resolves it explicitly with an `implement` and a qualified call:

```kotlin
skill MouseInput { fun click() { println("mouse") } }
skill TouchInput { fun click() { println("touch") } }

type Button + MouseInput + TouchInput {
    implement fun click() {
        MouseInput.click()
    }
}
```

### 11.5 Exceptions Without Hierarchy

There is no `Exception` base class. Any type that implements the `Throwable` contract can be thrown and caught:

```kotlin
contract Throwable {
    fun message(): String
}

type AssertionException(private val text: String) : Throwable {
    implement fun message(): String {
        return text
    }
}

throw AssertionException("Assertion failed")

catch (e: Throwable) {
    println(e.message())
}
```

### 11.6 System Contracts & Automatic Type Synthesis

Eiwa comes with core contracts and skills defined:

* `contract Stringable { fun toString(): String }`
* `contract Equatable { operator fun equals(other: Stringable): Bool }`
* `contract Hashable { fun hashCode(): Int }`
* `skill Echoable : Stringable { fun echo() { println(this.toString()) } }`

**Automatic Synthesized Implementations**
Every user-defined `type` and `object` automatically implements `Stringable`, `Equatable`, and `Hashable`. If a `type` does not supply custom implementations, the compiler synthesizes them automatically at compile-time:
* `toString()` — formats as `TypeName(prop1=val1, prop2=val2)`
* `equals(other)` — structural equality check comparing all non-closure properties
* `hashCode()` — combines hash codes across non-closure properties

```kotlin
type Person(val name: String, var age: Int)

fun main() {
    val p1 = Person("Alice", 30)
    val p2 = Person("Alice", 30)

    // Automatic toString synthesis
    assert(p1.toString() == "Person(name=Alice, age=30)")

    // Automatic equals synthesis
    assert(p1 == p2)

    // Automatic hashCode synthesis
    assert(p1.hashCode() == p2.hashCode())

    // Skill Echoable echo helper
    p1.echo()
}
```

### 11.7 Design Principles

1. **Types own state.** Only `type` declarations contain instance state.
2. **Contracts define capabilities.** Behavior only — never storage or implementation.
3. **Skills provide reusable behavior.** Implementation without state, depending on contracts supplied by the consuming type.
4. **Composition replaces inheritance.** Code reuse comes exclusively from skills; polymorphism comes exclusively from contracts.

### 11.8 Implicit `this` Member Access (Optional `this.`)

Inside `type` methods and receiver lambdas (`T.() -> Void`), the `this.` prefix is **optional** when reading properties, reassigning mutable fields, or calling sibling methods:

```kotlin
type ApplicationCall(val conn: ServerConnection, val request: Request) {
    fun respond(status: Int, contentType: String, body: String) {
        conn.writeResponse(status, contentType, body) // No 'this.' needed!
    }
    
    fun respondText(body: String, status: Int = 200) {
        respond(status, "text/plain", body) // Calling sibling method without 'this.'
    }
}
```

**Parameter Shadowing Rule:**
If a method parameter or local variable shares the same name as a property, the local variable takes precedence. Use explicit `this.name` to access the instance property:

```kotlin
type Counter(var count: Int = 0) {
    fun setCount(count: Int) {
        this.count = count // 'this.count' refers to property, 'count' to the parameter
    }
}
```

### 11.9 First-Class Enum Types (`enum`)

`enum` declarations define strongly typed, closed sets of constant variants with zero-overhead native compilation:

```kotlin
enum Direction { NORTH, EAST, SOUTH, WEST }
enum LogLevel { TRACE, DEBUG, INFO, WARN, ERROR, OFF }
```

**Synthesized Enum Members & Capabilities:**
Every `enum` variant automatically provides built-in properties and contracts synthesized by the compiler:
- `name: String`: The string identifier of the variant (e.g. `"NORTH"`).
- `ordinal: Int`: Zero-based integer index of the variant (e.g. `0`).
- `values(): List<EnumType>`: Returns a collection containing all enum instances.
- Conformance to `Stringable`, `Equatable`, and `Hashable`.
- Exhaustive pattern matching via `when (x)`.

```kotlin
val d = Direction.NORTH
assert(d.name == "NORTH")
assert(d.ordinal == 0)

when (d) {
    Direction.NORTH -> println("Heading North")
    Direction.EAST  -> println("Heading East")
    else            -> println("Other heading")
}
```

---

## 12. Objects & Boundless Namespaces

Objects allow grouping static variables and functions under a type namespace. In Eiwa, this is declared using the `object` keyword.

### 12.1 Named Standalone Objects (Singletons)
You can also declare standalone named `object` blocks which act as singletons or modules:

```kotlin
object Database {
    var queryCount = 0
    
    fun execute(query: String): String {
        this.queryCount = this.queryCount + 1
        return "Result of: " + query
    }
}

fun main() {
    assert(Database.queryCount == 0)
    val result = Database.execute("SELECT * FROM users")
    assert(Database.queryCount == 1)
}
```

### 12.2 Type-Bound Objects
An anonymous `object` block that immediately follows or precedes a `type` definition binds its members to the type namespace.

#### Same-Line Syntax Constraint
To emphasize that the type-bound object/type definition is a continuation of the type/object scope, Eiwa enforces that the anonymous block **must start on the same line** as the closing brace `}` of the sibling block. Separating them with a newline will trigger a compile-time syntax error.

#### Type-First Declaration
When the type is declared first, the anonymous `object` block is declared immediately after the type closing brace `} object {`:

```kotlin
type File(val path: String) {
    fun read(): String {
        return "Content of " + this.path
    }
} object {
    val defaultPath = "/tmp/eiwa.txt"
    
    fun create(path: String): File {
        return File(path)
    }
}

fun main() {
    // Access static members directly on the type name
    val path = File.defaultPath
    val file = File.create(path)
    
    // Access instance methods on the instantiated type
    assert(file.read() == "Content of /tmp/eiwa.txt")
}
```

#### Object-First Declaration (Vice-Versa)
Alternatively, you can declare the named `object` first, followed immediately by the anonymous `type` definition on the same line `} type(...) {`:

```kotlin
object Configuration {
    val defaultPrefix = "SYS_"
    var loadCount = 0
    
    fun createSystem(name: String): Configuration {
        Configuration.loadCount = Configuration.loadCount + 1
        return Configuration(Configuration.defaultPrefix + name)
    }
} type (val name: String) {
    fun getFormatted(): String {
        return "Config:" + this.name
    }
}

fun main() {
    // Access static members on the object/type namespace
    assert(Configuration.loadCount == 0)
    val config = Configuration.createSystem("DB")
    assert(Configuration.loadCount == 1)
    
    // Access instance methods on the created configuration instances
    assert(config.getFormatted() == "Config:SYS_DB")
}
```

---

## 13. Implicit Returns & Expression Bodies

Like Kotlin, Eiwa heavily favors expressions. If a function is simple enough, you don't need curly braces or a `return` keyword.

```kotlin
// Traditional block body
fun multiply(a: Int, b: Int): Int {
    return a * b
}

// Expression body (Type is inferred implicitly)
fun multiply(a: Int, b: Int) = a * b
```

---

## 14. Default Parameters & Named Arguments

Eiwa supports default values for parameters in functions, methods, and type constructors, as well as **Named Arguments** at call sites. This allows omitting unneeded arguments, passing arguments out of order, and crafting highly readable APIs and HTML/UI DSLs.

```kotlin
// Function with default parameters
fun greet(name: String, greeting: String = "Hello", punctuation: String = "!"): String {
    return greeting + ", " + name + punctuation
}

type Server(val host: String = "127.0.0.1", val port: Int = 8080)

fun main() {
    // 1. Positional call using default values
    print(greet("Alice")) // "Hello, Alice!"

    // 2. Named Arguments call (specifying only non-default parameters by name)
    print(greet(name = "Bob", punctuation = "!!!")) // "Hello, Bob!!!"

    // 3. Named Arguments out of order
    print(greet(greeting = "Welcome", name = "Charlie")) // "Welcome, Charlie!"

    // 4. Named Arguments with type constructors
    val s1 = Server(port = 3000) // host defaults to "127.0.0.1"
}
```

### 14.1 Combining Named Arguments with Trailing Lambdas

When creating Domain-Specific Languages (DSLs) like HTML or UI trees, Named Arguments combine seamlessly with Receiver Lambdas:

```kotlin
meta(charset = "UTF-8")
link(rel = "stylesheet", href = "/styles.css")

body(class = "bg-slate-900 text-white p-8") {
    div(class = "container mx-auto") {
        h1("Welcome to Eiwa!", class = "text-3xl font-bold")
    }
}
```

Statically typed defaults and named arguments are validated during type checking. If a caller omits an argument that has a default value, the type checker automatically clones and injects the default expression into the target parameter slot before code generation.

### 14.2 Varargs (`T...`)

A function or method can accept a variable number of trailing arguments by marking its **last** parameter with a `...` suffix on the type. Inside the body, the parameter is a `List<T>`; at the call site, every positional argument beyond the fixed ones is collected into that list.

```kotlin
fun sum(numbers: Int...): Int {
    var total = 0
    for (numbers) { n -> total = total + n }   // numbers: List<Int>
    return total
}

fun greet(greeting: String, names: String...): String {
    var out = greeting
    for (names) { name -> out = out + ", " + name }
    return out + "!"
}
```

**Call site** — pass any number of trailing values:

```kotlin
assert(sum() == 0)          // empty list
assert(sum(1, 2, 3) == 6)   // List<Int> = [1, 2, 3]

assert(greet("Hi", "Ana") == "Hi, Ana!")
assert(greet("Yo", "Leo", "Bob") == "Yo, Leo, Bob!")
```

**Rules:**
- `...` may only be on the **last** parameter, and the parameter must have a type.
- The element type `T` is what the compiler requires at each trailing call argument.
- Inside the body, the varargs parameter is an immutable `List<T>` — iterate, index, or call `.size()`.
- Calling with zero trailing arguments yields an empty list.
- Works on top-level functions, `type`/`object`/`skill` methods, and constructors.

```kotlin
// ❌ Invalid — `...` must be the last parameter
fun bad(a: Int..., b: Int) { }

// ❌ Invalid — each trailing argument must be compatible with T
sum("not a number") // TypeError
```

**Variadic FFI in `lib` blocks.** The same `T...` syntax on a `lib` declaration maps to a C **variadic function**: the trailing arguments are forwarded directly to the C `...` (no `List` wrapping), letting you call `curl_easy_setopt`, `printf` and friends natively:

```kotlin
@Link("curl")
@Header("<curl/curl.h>")
lib NativeHttp {
    @Alias("curl_easy_setopt")
    fun curlEasySetopt(curl: Pointer, option: Int, value: Pointer...): Int
}

NativeHttp.curlEasySetopt(curl, CURLOPT_URL, url.ptr)          // char* tail
NativeHttp.curlEasySetopt(curl, CURLOPT_FOLLOWLOCATION, 1)     // long tail
```

The compiler excludes the varargs parameter from the fixed signature and declares the function as variadic, matching the `...` prototype from the included header.

---

## 15. Lambda Expressions & Higher-Order Functions

Eiwa supports functional programming paradigms via lambdas (anonymous function literals) and Higher-Order Functions (functions that accept functions as arguments or return them).

### 15.1 Function Types
A function type represents a reference to a function. Its syntax is `(ParamType1, ParamType2, ...) -> ReturnType`.

```kotlin
// Declaring a variable holding a function that takes two Ints and returns an Int
val sum: (Int, Int) -> Int = { x: Int, y: Int -> x + y }

// Invocations are natural
val result = sum(10, 20)
assert(result == 30)
```

### 15.2 Lambda Literals & Implicit `it`
Lambdas are enclosed in curly braces `{}`. If a lambda has parameters, they are declared before the arrow `->`. If the lambda has only one parameter, you can omit its declaration and access it via the implicit name `it`.

```kotlin
// Explicit parameter
val double = { x: Int -> x * 2 }

// Implicit 'it' parameter (type inferred as Int from the context)
val triple: (Int) -> Int = { it * 3 }

assert(triple(5) == 15)
```

### 15.3 Scope Capturing (Closures)
Lambdas can capture variables from their surrounding lexical scope. If a captured variable is mutable (`var`), the Eiwa compiler automatically wraps it in a heap-allocated box so that changes are visible both inside the lambda and in the outer scope, even after the outer function exits.

```kotlin
fun makeCounter(): () -> Int {
    var count = 0
    return {
        count = count + 1
        count
    }
}

fun main() {
    val counter = makeCounter()
    assert(counter() == 1)
    assert(counter() == 2)
}
```

### 15.4 Trailing Lambdas & DSLs
If the last parameter of a function is a function type, the lambda expression can be passed outside of the function call parentheses. If it is the only parameter, the parentheses can be completely omitted. This is extremely powerful for building clean DSLs:

```kotlin
type HTMLBuilder {
    var content: String = ""
    fun body(init: () -> String) {
        this.content = this.content + "<body>" + init() + "</body>"
    }
}

fun html(init: HTMLBuilder.() -> Void): String {
    val builder = HTMLBuilder()
    init(builder)
    return "<html>" + builder.content + "</html>"
}

fun main() {
    // Parentheses are completely omitted for the trailing lambda
    val result = html {
        body {
            "Hello Eiwa DSL!"
        }
    }
    assert(result == "<html><body>Hello Eiwa DSL!</body></html>")
}
```

---

## 16. C Interoperability & Annotations

Eiwa compiles to native code through LLVM, so integrating with native C libraries is seamless. You can declare a `lib` block to map C functions into Eiwa without writing any wrapper code.

Annotated `lib` blocks instruct the compiler and linker on how to process native C libraries:
- **`@Header` (Compile-Time Includes)**: Instructs the compiler to inject the corresponding `#include` directives so the C toolchain knows about function signatures, structs, and constants.
- **`@Link` (Smart Linker Resolution via `pkg-config`)**: Instructs the Eiwa compiler to dynamically resolve library paths and flags using system `pkg-config` (e.g. `@Link("pq")` or `@Link("curl")`). The compiler automatically queries `pkg-config --cflags --libs` (searching standard OS and Homebrew `PKG_CONFIG_PATH` paths on macOS and Linux) and injects the appropriate `-I`, `-L`, and `-l` flags alongside preprocessor macros (`-DEIWA_USE_<NAME>`). If `pkg-config` is not available or doesn't find the package, it gracefully falls back to `-l<name>`.
- **`@Include` (Extra Include Directories)**: Appends a `-I<dir>` flag to the C compiler. Relative paths starting with `./` or `../` (e.g. `@Include("./native")`) are automatically resolved relative to the directory containing the `.ei` file.
- **`@Source` (Vendored C Sources)**: Appends a C source file to the compilation, e.g. `@Source("src/runtime/third_party/mylib/mylib.c")`. Use for vendored C libraries compiled together with the program.
- **`@Define` (Preprocessor Definitions)**: Appends a `-D<NAME>` or `-D<NAME=value>` flag to the C compiler, e.g. `@Define("MYLIB_BUFFER_SIZE=4096")`.
- **`@Alias` (Function Names Mapping)**: Placed on individual functions inside `lib` blocks to map Eiwa `camelCase` function names to the corresponding C `snake_case` library functions.

### 16.1 Self-Contained Library Bindings

A `lib` block is self-contained: everything the C toolchain needs to build the binding is declared next to it, with no hardcoded flags in the compiler:

```kotlin
// From the eiwa-lang/postgres package: src/native.ei
@Link("pq")
@Header("<libpq-fe.h>")
@Header("libpq/libpq_wrapper.h")
@Include("src/runtime/third_party/libpq")
lib NativePg {
    @Alias("PQconnectdb")
    fun connect(conninfo: Pointer): Pointer

    @Alias("PQfinish")
    fun finish(conn: Pointer): Void

    @Alias("PQstatus")
    fun status(conn: Pointer): Int
}
```

```kotlin
// http.ei (FFI declaration using Header, Link, and Alias)
@Link("curl")
@Header("<curl/curl.h>", "runtime/curl_helpers.h")
lib NativeHttp {
    @Alias("curl_easy_init")
    fun curlEasyInit(): Pointer
    
    @Alias("curl_easy_perform")
    fun curlEasyPerform(curl: Pointer): Int
    
    @Alias("curl_easy_cleanup")
    fun curlEasyCleanup(curl: Pointer): Void
}
```

### 16.2 Custom CLI C-Flags (`-I`, `-L`, `-l`, `-D`)

When building or running Eiwa applications, you can pass custom C compiler and linker flags directly to `eiwac run`, `eiwac build`, or `eiwac test`:

```bash
# Pass custom include (-I) and library (-L) search paths
eiwac run app.ei -I /opt/homebrew/opt/libpq/include -L /opt/homebrew/opt/libpq/lib

# Build a binary with custom C defines and linked libraries
eiwac build main.ei -I/usr/local/include -L/usr/local/lib -l custom -DDEBUG_MODE

# Run tests with custom C flags
eiwac test samples/tests/postgres_test.ei -I /opt/homebrew/opt/libpq/include
```

All C flags passed on the CLI are automatically collected and forwarded to `zig cc` during compilation.

*(Note: In the current phase, Annotations are structural compiler pragmas. In future phases, Eiwa will support declaring custom user-defined annotations natively).*

### 16.3 Compiler Options & Program Arguments

The compiler backend binary is **`eiwac`** (the `eiwa` command is the developer CLI, see Section 30).

```bash
eiwac <run|build|test> [options] [file.ei] [program args...]

Options:
  --backend=llvm     Use the LLVM backend (default)
  --release          Optimized build (-O3)
  -o <name>          Output binary name/path (build command)
  --module-path <d>  Extra directory to resolve imports (repeatable)
  -h, --help         Show help
```

**Program arguments.** Extra positional arguments after the file are forwarded to the program by `eiwac run`. Programs read them through `std.process` (Section 17.1) — this works whether the program defines `fun main()` or uses top-level statements:

```kotlin
import { Process } from "std.process"

fun main() {
    val args = Process.args() // List<String>
    for (args) {
        println(it)
    }
}
```

```bash
eiwac run app.ei -x 1 --verbose   # Process.args() -> ["-x", "1", "--verbose"]
```

`Process.args()` returns the extra arguments after the file. `run` executes the program through the LLVM JIT (in-process), so the list starts at the first argument after the file.

**Module search paths.** With `--module-path <dir>`, bare imports that do not resolve relative to the importing file are looked up in each module path (in order). Root-relative imports (`.x`) and `std.*` packages are never affected. This is how the `eiwa` CLI wires external dependencies (Section 30) without the compiler knowing about `~/.eiwa`.

### 16.4 Custom Main Wrappers (`@MainWrapper`) — REMOVIDO (2026-08)

> O mecanismo `@MainWrapper` foi **removido** junto com o runtime stackful (neco) — ver
> ADR 48 / `docs/tasks-coroutines-stackless.md`. Com coroutines stackless o entry point é
> sempre `main`/`eiwa_test_main` direto: o `Scheduler` de tasks é inicializado e drenado pelo
> próprio `main` (via `Scheduler.run()` no final), sem shims de entry. O uso de `@MainWrapper`
> no código agora é ignorado (annotation desconhecida é metadado inerte).

### 16.5 C Function Pointers (`funPointer { lambda }`)

Some C APIs take a callback as a function pointer (e.g. libcurl's write callback, `signal`, `qsort`). Eiwa builds a C function pointer from an inline lambda with `funPointer { ... }` — the Kotlin/Native `staticCFunction` equivalent. The lambda must:

- declare its parameter types explicitly (they become the C signature),
- **not capture** outer variables — a C function pointer has no context; keep state in the `user data` argument the C API provides.

```kotlin
fun writeCallback(contents: Pointer, size: Int, nmemb: Int, userp: Pointer): Int {
    // delegate a large body to a named top-level function
}

NativeHttp.curlEasySetopt(curl, CURLOPT_WRITEFUNCTION,
    funPointer { contents: Pointer, size: Int, nmemb: Int, userp: Pointer ->
        writeCallback(contents, size, nmemb, userp)
    })
```

The compiler lifts the lambda into a synthetic function, generates a C trampoline (`eiwa_cb_<name>`) that forwards to it, and the expression evaluates to the trampoline's address (`Pointer`). Large bodies can delegate to a named function from inside the lambda.

### 16.6 Native Memory Slots (`Memory.alloc<T>` & `IntVar`)

To call a C function that **writes through a pointer** (an out-parameter — e.g. `curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code)`), Eiwa allocates a small GC slot and passes its address. This is the Kotlin/Native `memScoped { alloc<IntVar>() }` pattern.

```kotlin
type IntVar(val ptr: Pointer) {
    fun get(): Int = Standard.loadInt64(this.ptr)
    fun set(value: Int): Void = Standard.storeInt64(this.ptr, value)
}

object Memory {
    fun alloc<T>(block: (T) -> Void): T {
        val v = T(Standard.gcMalloc(8))   // monomorphized to IntVar(ptr)
        block(v)
        return v
    }
}
```

`Memory.alloc<T>` runs `block` with a typed view of a fresh 8-byte slot and returns the slot; `T` is the **slot type**, so `alloc<DoubleVar>` will work once that slot exists. Usage with a C out-parameter:

```kotlin
status = Memory.alloc<IntVar> {
    NativeHttp.curlEasyGetInfo(curl, CURLINFO_RESPONSE_CODE, it.ptr)   // C writes through it.ptr
}.get()                                                                 // read the value back
```

The slot is allocated through the Boehm GC, so no manual `free` is required.

### 16.7 Struct Access (`Pointer as Type` & `Pointer is Type`)

C APIs often pass a pointer to a struct whose fields you must read or write — e.g. libcurl's write callback hands you a `user data` pointer to a buffer. Eiwa reinterprets a raw `Pointer` as a `type` with `as`; the value becomes a **memory view** and field access reads/writes at the type's C layout offsets (every Eiwa `type` carries an 8-byte `_desc` header before its fields).

```kotlin
// Layout matches the C struct: { _desc, ptr, length }
type CString(var ptr: Pointer, var length: Int)

fun writeCallback(contents: Pointer, size: Int, nmemb: Int, userp: Pointer): Int {
    val s = userp as CString          // reinterpret the pointer as the type
    val n = size * nmemb
    val newData = Standard.gcRealloc(s.ptr, s.length + n + 1)
    Standard.memcpy(newData + s.length, contents, n)
    s.ptr = newData                   // var fields are writable through the view
    s.length = s.length + n
    return n
}
```

- `Pointer as Type` reinterprets **without checking** (the pointer must already point to that layout) — useful when the C API guarantees the type (e.g. a `user data` you configured yourself).
- `Pointer is Type` **checks the runtime descriptor** at the address and smart-casts, so `when (ptr) { is SomeType -> ptr.field }` works.
- `as` also performs **numeric casts** between `Int` and `Double` (`d as Int` truncates, `i as Double` converts) — no separate `.toInt()`/`.toDouble()` helper needed.
- Combined with `funPointer { ... }` (§16.5) and `Memory.alloc` (§16.6), this lets you bind C libraries that use callbacks, structs and out-parameters with **zero glue C** — `std.http` now calls libcurl directly.

---

## 17. Standard Library Packages & Time API

Eiwa organizes its standard library into virtual packages starting with `std.`. The compiler automatically maps these to the language's internal SDK.

For example, manipulating Date and Time in Eiwa is done through the `std.time` package, which uses an ultra-fast **Epoch-First** architecture (inspired by Go). Instead of bloated objects containing Year/Month/Day properties, Eiwa's `Time` type is a zero-overhead wrapper around a simple Unix Epoch integer. 

```kotlin
import { Time, Duration, now, date, hours, minutes, seconds } from "std.time"

fun main() {
    // Current time (machine epoch)
    val today = now()
    
    // Creating specific dates directly
    val birthday = date(1990, 7, 20)
    
    // Time mathematics uses Eiwa's native Operator Overloading
    val dur = hours(48)
    val future = birthday + dur // Birthday + 48 hours
    
    // Time difference returns a Duration
    val diff = today - birthday 
    print(diff.hours().toString())
    
    // Formatting uses the traditional standard
    print(future.format("YYYY-MM-DD HH:mm:ss"))
}
```

Because time math is just adding integers (`epoch + seconds`), it avoids the historic timezone bugs that plague other languages when dealing with daylight savings and calendar math. The `std.time` package makes all duration math explicit (e.g., `hours(2)`) and heavily leverages Operator Overloading for ergonomics.

### 17.1 Process API (`std.process`)

Process execution, program arguments and working-directory utilities. All internal buffers are allocated through the Boehm GC — user code never touches raw `malloc`.

```kotlin
import { Process } from "std.process"

fun main() {
    // Run a shell command, returns the exit code
    val code = Process.exec("ls -la")

    // Run a command and capture stdout
    val commit = Process.capture("git rev-parse HEAD")

    // Program arguments (argv)
    val args = Process.args()
    for (args) {
        println(it)
    }

    // Working directory & path resolution
    Process.chdir("/tmp")
    val abs = Process.realpath("./file.txt") // String? (null if it doesn't exist)
}
```

---

## 18. Environment Variables (`std.env`)
The `std.env` module provides tools to load environment variables from `.env` files and interact with the process's environment. Like `std.core`, `std.io`, `std.system`, `std.exceptions`, `std.collections`, `std.time`, and `std.serde`, the `std.env` module is **implicitly imported** by the compiler into every program, so no `import` statement is required.

### 18.1 Loading `.env` files
Use `Env.load()` to load an environment configuration. If no path is provided, Eiwa looks for `.env` in the current directory. This returns `false` silently if the file is not found.

```kotlin
fun main() {
    // Loads .env from current directory (returns true if loaded, false if not found)
    Env.load()
    
    // Or specify a custom path
    Env.load("configs/local.env")
}
```

### 18.2 Reading Variables
You can query variables using `Env.get`. If a get/check is performed before `Env.load()` is explicitly invoked, Eiwa automatically attempts to load the default `.env` file first.

```kotlin
fun main() {
    // Nullable string retrieval
    val host: String? = Env.get("DB_HOST")
    
    // Retrieval with default fallback values (String, Int, Bool overloads)
    val port: Int = Env.get("DB_PORT", 5432)
    val database: String = Env.get("DB_NAME", "production")
    val isDebug: Bool = Env.get("DEBUG", false)
}
```

### 18.3 Global `env()` Helper
For fast, zero-boilerplate configuration lookup, Eiwa provides overloaded global `env()` helper functions (which delegate directly to `Env.get`):

```kotlin
fun main() {
    // Nullable string retrieval
    val host: String? = env("DB_HOST")
    
    // Retrieval with default fallback values (String, Int, Bool overloads)
    val port: Int = env("DB_PORT", 5432)
    val database: String = env("DB_NAME", "production")
    val isDebug: Bool = env("DEBUG", false)
}
```

### 18.4 Modifying and Checking Variables
Eiwa allows setting, unsetting, and checking for the existence of environment variables:

```kotlin
fun main() {
    // Check if variable exists
    if (Env.exists("API_KEY") == false) {
        Env.set("API_KEY", "default-secret-key")
    }
    
    // Unset a variable
    Env.unset("TEMP_TOKEN")
}
```

---

## 19. Native Testing

Eiwa has a first-class, built-in testing system. You don't need external libraries or complex test runners. Just create a file with the suffix `_test.ei`, write a `test` block, and use the `assert` macro.

```kotlin
// math_test.ei
import { add } from "math"

test "should add two numbers correctly" {
    val result = add(10, 5)
    assert(result == 15)
}
```

Then, run `eiwa test` in your terminal. The compiler will automatically discover, group, and run all your tests in an isolated native binary.

## 20. Concorrência Estruturada (`task` / `await`)

> **Nota:** Esta seção descreve a API pública de concorrência do Eiwa. O runtime subjacente é de
> **coroutines stackless** (estilo Kotlin): o compilador transforma corpos de `task { }` em **state
> machines** (objetos heap `Continuation`) dirigidos por um `Scheduler` escrito em Eiwa puro (fila
> FIFO + timer heap). Sem stack switching, sem threads expostas. Detalhes: ADR 48 e
> `docs/tasks-coroutines-stackless.md`.

Eiwa oferece concorrência leve e estruturada através de duas funções da stdlib: `task { }` e `.await()`. Não existem keywords especiais, threads expostas, ou callbacks — apenas lambdas e tipos genéricos.

### 20.1 Conceitos Básicos

- `task { expr }` — função da stdlib que recebe uma lambda e retorna `StackTask<T>` (declarada como `Task<T>` na stdlib). A lambda é agendada no `Scheduler` cooperativo e executada de forma lazy (no primeiro `await()`).
- `task.await()` — método em `StackTask<T>` que suspende a coroutine atual até o resultado da task estar disponível.
- `StackTask<T>` — tipo genérico declarado na stdlib (`src/std/coroutines.ei`), implementando o contrato `Awaitable<T>`.

```kotlin
import { Task } from "std.core"

fun fetchUsers(): List<String> {
    return ["Alice", "Bob"]
}

fun fetchConfig(): String {
    return "config-data"
}

fun main() {
    // Dispara duas tasks em paralelo
    val usersTask = task { fetchUsers() }
    val configTask = task { fetchConfig() }

    // Aguarda ambas — a fibra atual é suspensa, não a thread OS
    val users = usersTask.await()
    val config = configTask.await()

    println(users.toString())
    println(config)
}
```

### 20.2 Múltiplas Tasks

Tasks são executadas cooperativamente. O scheduler alterna entre continuations quando uma delas suspende (via `await()`, `sleep`/`yield` ou I/O).

```kotlin
fun main() {
    val t1 = task { 10 + 20 }
    val t2 = task { 30 + 40 }

    val r1 = t1.await()
    val r2 = t2.await()

    assert(r1 == 30)
    assert(r2 == 70)
}
```

### 20.3 Tasks Aninhadas

Tasks podem conter outras tasks. O `await()` interno suspende apenas a continuação da task externa, não a thread principal.

```kotlin
fun main() {
    val outer = task {
        val inner = task { 7 * 6 }
        inner.await() + 1
    }

    assert(outer.await() == 43)
}
```

### 20.4 Captura de Escopo

Assim como lambdas comuns, o bloco de `task { }` captura variáveis do escopo léxico externo.

```kotlin
fun main() {
    val multiplier = 10
    val t = task { multiplier * 5 }
    assert(t.await() == 50)
}
```

### 20.5 Task com Tipos Complexos

`Task<T>` funciona com qualquer tipo, incluindo coleções:

```kotlin
fun main() {
    val listTask = task { [1, 2, 3] }
    val mapTask = task { ["a" of 1, "b" of 2] }

    assert(listTask.await().size() == 3)
    assert(mapTask.await()["a"] == 1)
}
```

### 20.6 Structured Concurrency

O Eiwa segue o modelo de **structured concurrency**: uma função que cria tasks filhas só retorna quando todas as filhas completarem. Isso previne "tasks vazadas" que continuam rodando após o escopo pai terminar.

```kotlin
fun process() {
    val t = task { fetchData() }
    // process() só retorna quando t completar
    val data = t.await()
    // ...
}
```

### 20.7 Objetos de Concorrência e I/O (`Coroutine` & `EventLoop`)

A standard library expõe dois objetos estáticos em `std.coroutines` para operações de baixo nível de concorrência e I/O de forma agnóstica de engine:

```kotlin
import { Coroutine, EventLoop } from "std.coroutines"

fun example() {
    // Fora do corpo de um task: pausa a thread (nanosleep) ou cede (sched_yield).
    Coroutine.yield()
    Coroutine.sleep(1)

    // Aguarda prontidão de socket/FD (poll).
    EventLoop.waitReadable(fd)
    EventLoop.waitWritable(fd)
}
```

> **Dentro do corpo de um `task { }`**, `sleep`/`sleepMs`/`yield` viram **pontos de suspensão
> cooperativos de verdade** (o transform os reescreve em `Scheduler.sleep(this, ...)`/
> `Scheduler.yield(this)`): o corpo é compilado como state machine e o control volta ao scheduler,
> que retoma a task quando o timer dispara — sem bloquear a thread. `await()` dentro de um corpo
> state machine registra o caller como waiter da task aguardada e suspende (waiter-chain FIFO).

### 20.8 Limitações do MVP

- **Sem cancelamento** — `task.cancel()` fica para uma fase futura.
- **Single-threaded** — todas as tasks rodam em uma única thread OS (scheduler cooperativo). Paralelismo real (Dispatchers / thread pool) é uma proposta adiada (Fase I do plano stackless).
- **`await()` no root** (main/test/top-level) é blocking-poll — o root é o driver e não tem continuation; suspensão cooperativa acontece **dentro** dos corpos de task.
- **Gaps do transform:** `for`/`try` com `sleep`/`yield` dentro do corpo do task, e `await` como operando dentro de `assignment`, ainda não suspendem cooperativamente (erro `file:line` ou chamada direta bloqueante).

---

## 21. Serialization (JSON & YAML)

Eiwa offers compile-time serialization without runtime reflection (ADR 27). You opt in by implementing the `Serializable` contract, then compose format skills (`+ Json`, `+ Yaml`) to add `toJson()`/`toYaml()` methods.

### 21.1 Basic Usage

```kotlin
import { Json } from "std.json"
import { Yaml } from "std.yaml"

type User(val name: String, val age: Int) : Serializable + Json + Yaml

fun main() {
    val u = User("Ana", 30)
    print(u.toJson())   // {"name": "Ana", "age": 30}
    print(u.toYaml())   // name: "Ana"\nage: 30
}
```

### 21.2 Nested Objects

Any field whose type also implements `Serializable` is wrapped and serialized recursively.

```kotlin
import { Json } from "std.json"

type Address(val city: String) : Serializable + Json
type Person(val name: String, val addr: Address) : Serializable + Json

fun main() {
    val p = Person("Bob", Address("SP"))
    print(p.toJson())
    // {"name": "Bob", "addr": {"city": "SP"}}
}
```

### 21.3 Fields with Lists

`List<T>` fields where `T` is serializable are serialized as JSON arrays / YAML sequences.

```kotlin
import { Json } from "std.json"

type Team(val name: String, val members: List<String>) : Serializable + Json

fun main() {
    val t = Team("A-Team", ["Alice", "Bob"])
    print(t.toJson())
    // {"name": "A-Team", "members": ["Alice", "Bob"]}
}
```

### 21.4 Fields Are Filtered

Only serializable types (primitives, `: Serializable` types, and `List<T>` of these) appear in the output. Other fields are silently skipped — no annotations needed.

```kotlin
import { Json } from "std.json"

type NotSerializable(val x: Int)
type WithIgnored(val label: String, val ignored: NotSerializable) : Serializable + Json

fun main() {
    val w = WithIgnored("visible", NotSerializable(42))
    print(w.toJson())
    // {"label": "visible"}    -- ignored field is absent
}
```

### 21.5 Custom `serdeFields()`

You can override `serdeFields()` manually to rename, reorder, or omit fields — no annotation system needed.

```kotlin
import { Json } from "std.json"

type User(val fullName: String, val age: Int) : Serializable + Json {
    implement fun serdeFields(): List<SerdeField> = [
        SerdeField("name", SerdeString(fullName)),
        SerdeField("age", SerdeInt(age)),
    ]
}
```

### 21.6 Adding a New Format

New formats (Toml, XML, binary) are skills written in pure Eiwa — zero compiler changes.

```kotlin
skill Toml : Serializable {
    fun toToml(): String = writeToml(this.serdeFields())
}

// Then use: type Config : Serializable + Toml
```

### 21.7 Limitations (v1)

- **Serialization only** — deserialization (`fromJson`/`fromYaml`) is a future phase.
- **No `Map<K,V>` support** — only primitive fields, nested `: Serializable` objects, and `List<T>`.
- **No nullable field support** — nullable fields are skipped.
- **No field customization** — rename/skip/format annotations are future work (override `serdeFields` as a workaround).
- **Boxing overhead** — each field is boxed into `SerdeInt`/`SerdeString`/etc. at the point of `serdeFields()` construction. This is a one-time cost per call; the encoders themselves are pure function calls that walk the list with contract dispatch.

---

## 22. Standard Library Logging (`std.log`)

Eiwa includes a native, structured logging package in `std.log` featuring lazy message evaluation, custom formatters, contextual key-value logging, and `Throwable` exception support.

### 22.1 Basic Facade (`Log`)

The global `Log` object provides standard logging functions across all log levels:

```kotlin
import { Log, LogLevel } from "std.log"

fun main() {
    Log.info { "Application started" }
    Log.debug { "Debug info" }
    Log.warn { "Warning message" }
}
```

### 22.2 Log Levels (`LogLevel` Enum)

Log levels are defined using the native `LogLevel` enum:

- `LogLevel.TRACE` (ordinal 0)
- `LogLevel.DEBUG` (ordinal 1)
- `LogLevel.INFO` (ordinal 2)
- `LogLevel.WARN` (ordinal 3)
- `LogLevel.ERROR` (ordinal 4)
- `LogLevel.OFF` (ordinal 5)

You can set the minimum log level globally or on individual `Logger` instances:

```kotlin
Log.setLevel(LogLevel.WARN)
Log.info { "This will NOT be printed" }
Log.warn { "This WILL be printed" }
```

### 22.3 Lazy Evaluation via Lambdas

All log functions accept a message closure (`() -> String`) instead of a raw string. If a log level is filtered out by the logger, **the closure is never executed**, eliminating string allocation and formatting overhead when logging is disabled:

```kotlin
Log.setLevel(LogLevel.INFO)
Log.trace { 
    // Heavy string calculation - NEVER executed when log level is INFO!
    "Complex calculation: " + heavyComputation().toString() 
}
```

### 22.4 Throwable Exception Logging

Pass a `Throwable` exception as the first argument to `warn` or `error` to include exception details:

```kotlin
try {
    throw Exception("Connection failed")
} catch (e: Throwable) {
    Log.error(e) { "Failed to connect to server" }
}
```

### 22.5 Contextual Key-Value Logging (`with`)

Create child loggers enriched with contextual fields using `Log.with(key, value)` or `Log.withFields(map)`:

```kotlin
val reqLogger = Log.with("req_id", "abc-123").with("user", "alice")
reqLogger.info { "Processing request" }
// Output: [2026-07-22 22:00:00] [INFO] Processing request {req_id=abc-123, user=alice}
```

### 22.6 Log Formatters (`TextFormatter` and `JsonFormatter`)

The library includes two built-in formatters:
- `StandardLogFormatter` (using `TextFormatter` skill): Human-readable terminal output with ANSI colors.
- `JsonLogFormatter` (using `JsonFormatter` skill): Single-line structured JSON logs for log aggregators (Elasticsearch, Datadog).

```kotlin
import { Log, JsonLogFormatter } from "std.log"

fun main() {
    Log.setFormatter(JsonLogFormatter())
    Log.info { "User logged in" }
    // Output: {"timestamp":"2026-07-22 22:00:00","level":"INFO","message":"User logged in"}
}
```

---

## 23. Generics & Monomorphization

Eiwa supports generic functions, methods, and types using a **monomorphization** strategy: for every unique combination of concrete type arguments, the compiler generates a dedicated copy of the function or type (like C++ templates and Rust generics). This gives zero-cost abstraction — no boxing, no vtable dispatch for monomorphized calls.

### 23.1 Generic Function Declarations

Generic parameters are declared with `<T>` after the function name:

```kotlin
fun identity<T>(x: T): T {
    return x
}

fun main() {
    assert(identity(42) == 42)           // inferred: identity<Int>
    assert(identity("hello") == "hello") // inferred: identity<String>
}
```

Multiple type parameters are comma-separated:

```kotlin
fun pair<A, B>(a: A, b: B): Pair<A, B> {
    return Pair(a, b)
}
```

### 23.2 Explicit Type Arguments

You can specify type arguments explicitly with `<Type>` immediately after the function name (before the argument parentheses):

```kotlin
fun main() {
    val x = identity<Int>(42)
    val y = identity<String>("hello")
    val z = identity<String | Int>(42) // union type parameter
}
```

### 23.3 Generic Methods on Types

Methods on `type` declarations can also have their own generic parameters:

```kotlin
type Util {
    fun wrap<T>(value: T): Pair<String, T> {
        return Pair("wrapped", value)
    }
}

fun main() {
    val util = Util()

    // Explicit type args
    val p1 = util.wrap<Int>(42)
    assert(p1.first == "wrapped")
    assert(p1.second == 42)

    // Inferred type args (from argument type)
    val p2 = util.wrap("hello")
    assert(p2.first == "wrapped")
    assert(p2.second == "hello")
}
```

### 23.4 Generic Types (`type Task<T>`)

Types can declare generic parameters, and the monomorphizer generates a dedicated C struct per concrete instantiation:

```kotlin
type Box<T>(val value: T)

fun main() {
    val intBox = Box(42)     // type: Box<Int>
    val strBox = Box("eiwa") // type: Box<String>

    assert(intBox.value == 42)
    assert(strBox.value == "eiwa")
}
```
---

## 24. Scope Functions (`let`, `run`, `also`, `apply`, `takeIf`, `takeUnless`, `with`)

Kotlin-style scope functions are available on **every type** — primitives included — via the auto-injected `Scope<T>` skill from `std.core` (ADR 40). The lambda receives the receiver as the implicit `it` parameter.

### 24.1 `let` — Transform a Value

`let` returns the lambda's result:

```kotlin
val doubled = 5.let { it * 2 }        // 10
val name = person.let { it.name }     // extracts a property
val chained = 5.let { it * 2 }.let { it + 1 }  // 11
```

### 24.2 `run` — Execute and Return

`run` behaves like `let` (returns the lambda result); use it for grouping operations:

```kotlin
val greeting = person.run { it.name + "!" }
```

### 24.3 `also` / `apply` — Side Effects, Return the Receiver

Both return the receiver itself, useful for configuration or mutation chains. Note that a lambda whose last statement is an assignment returns the assigned value, so end the lambda with a `Void` expression (e.g. `println`) when the expected type is `(T) -> Void`:

```kotlin
val p = Person("Leo", 30).also {
    it.age = it.age + 1
    println(it.age.toString())   // last expression is Void
}
// p.age == 31

val q = person.apply {
    it.name = "Ana"
    println(it.name)
}
```

### 24.4 `takeIf` / `takeUnless` — Nullable Filtering

Returns the receiver (`T?`) when the predicate holds (`takeIf`) or fails (`takeUnless`), otherwise `null`:

```kotlin
val adult = person.takeIf { it.age > 18 }       // Person | Null
val kid   = person.takeUnless { it.age > 18 }   // Person | Null

if (adult != null) {
    println(adult!!.name)
}
```

### 24.5 `with` — Top-Level Function

Unlike the others, `with` is a top-level generic function (not a method):

```kotlin
val summary = with(person) { it.name + " is " + it.age.toString() }
val answer  = with(20) { it + 22 }   // 42
```

### 24.6 Name Conflicts

If a type declares its own `let`, `run`, etc., the type's explicit method wins; the scope function remains available qualified as `Scope_let`, `Scope_run`, etc. (same rule as `toString` vs `Stringable` — see 11.6).

---

## 25. Database Contracts & Connection Pooling (`std.db`)

Eiwa provides provider-independent database contracts in `std.db` alongside a generic, cooperative connection pool (`ConnectionPool<C>`). Application code should depend only on `std.db` contracts (`Connection`, `Statement`, `Result`, `Row`) rather than driver-specific implementations.

### 25.1 Core Database Contracts

* **`Row`**: Extracted query row with type-safe accessors (`.int("col")`, `.string("col")`, `.bool("col")`, `.isNull("col")`).
* **`Result`**: Result of a query (`.rows()`) or DDL/DML statement (`.rowsAffected()`).
* **`Statement`**: Prepared statement interface (`.query()`, `.execute()`).
* **`Connection`**: Core database connection interface (`.query(sql, params)`, `.execute(sql, params)`, `.prepare(sql)`, `.close()`).

### 25.2 Generic Cooperative Connection Pool (`ConnectionPool<C>`)

The `ConnectionPool<C>` type is generic over any connection type `C` implementing `Connection` and `Closeable`. It manages connections non-blockingly by yielding the current coroutine via `Coroutine.yield()` when the pool reaches its maximum connection limit.

```kotlin
import { ConnectionPool, Connection } from "std.db"
import { Postgres } from "std.postgres"

fun main() {
    // Instantiate a Postgres pool with a max of 10 connections
    val pool = Postgres.pool("postgres://user:pass@localhost/mydb", maxConnections = 10)

    // Execute queries transparently through the pool
    val res = pool.query("SELECT * FROM users WHERE id = $1", ["1"])
    for (res.rows()) { row ->
        print(row.string("name"))
    }

    // Execute transactions safely
    pool.transaction { conn ->
        conn.execute("INSERT INTO audit_logs (action) VALUES ($1)", ["LOGIN"])
    }

    // Fluent Parameter Binding via BoundStatement
    pool.prepare("INSERT INTO users (name, age) VALUES ($1, $2)")
        .bind("Ana")
        .bind(25)
        .execute()

    pool.close()
}
```

---

## 26. Unique Identifiers (`std.uuid` & `std.ulid`)

Eiwa provides built-in support for 128-bit unique identifiers through the standard packages `std.uuid` and `std.ulid`.

### 26.1 `std.uuid` — UUID v7 (Time-Ordered) & UUID v4 (Random)

`Uuid` is an immutable 128-bit structure representing a Universally Unique Identifier.

* **UUID v7 (Default / Recommended)**: Combines a 48-bit Unix millisecond timestamp with 74 bits of CSPRNG entropy. Time-ordered, ideal for database primary keys (index-friendly).
* **UUID v4**: Fully random CSPRNG UUID.
* **RFC String Format**: Standard 36-character format (`8-4-4-4-12` hex characters with hyphens).

```kotlin
import { Uuid, Identifier } from "std.uuid"

fun main() {
    // Generate UUID v7 (time-ordered, default)
    val id7 = Uuid.generate() // or Uuid.v7()
    println(id7.toString())   // e.g. "018f6c52-7b2a-7123-8abc-123456789abc"
    assert(id7.version() == 7)

    // Generate UUID v4 (random)
    val id4 = Uuid.v4()
    println(id4.toString())   // e.g. "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    assert(id4.version() == 4)

    // Parse existing UUID string (returns null if invalid)
    val parsed = Uuid.parse("018f6c52-7b2a-7123-8abc-123456789abc")
    if (parsed != null) {
        assert(parsed == id7)
    }

    // Contract polymorphism
    val genericId: Identifier = Uuid.generate()
    println(genericId.toString())
}
```

### 26.2 `std.ulid` — ULID (Universally Unique Lexicographically Sortable Identifier)

`Ulid` is a 128-bit identifier encoded as a 26-character Crockford Base32 string (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`).

* **Structure**: 48-bit Unix millisecond timestamp (10 chars) + 80 bits of CSPRNG entropy (16 chars).
* **Sortable**: Lexicographically sortable across systems.
* **Timestamp Extraction**: Direct access to the embedded 48-bit Unix millisecond timestamp.

```kotlin
import { Ulid } from "std.ulid"

fun main() {
    // Generate ULID
    val ulid = Ulid.generate()
    println(ulid.toString()) // e.g. "01KYR9VPX561EXNHG95R8REG8R" (26 chars)

    // Access embedded timestamp in milliseconds
    val ts = ulid.timestamp()
    println("Created at millis: " + ts.toString())

    // Parse Crockford Base32 ULID string (returns null if invalid)
    val parsed = Ulid.parse("01KYR9VPX561EXNHG95R8REG8R")
    if (parsed != null) {
        assert(parsed == ulid)
    }
}
```

---

## 27. Random Number Generation (`std.random`)

Eiwa provides random generation functionality via `std.random`, which offers both system entropy (`Random`) and deterministic seedable generation (`SeededRandom`).

### 27.1 System Random (`Random`)

* **`nextInt(min, max)`**: Returns a random integer in the range `[min, max]`.
* **`nextDouble()`**: Returns a random `Double` in the range `[0.0, 1.0)`.
* **`nextDouble(min, max)`**: Returns a random `Double` in the range `[min, max)`.
* **`nextPercent()`**: Returns a random integer between `0` and `100`.
* **`nextBool()`**: Returns a random boolean.
* **`choice(list)`**: Returns a random element from a list (or `null` if empty).
* **`shuffle(list)`**: Returns a new list with elements randomly permuted.

```kotlin
import { Random } from "std.random"

fun main() {
    val roll = Random.nextInt(1, 6)
    val pct = Random.nextPercent()
    val d = Random.nextDouble() // Double between 0.0 and 1.0
    val dRange = Random.nextDouble(10.5, 20.5) // Double between 10.5 and 20.5
    
    val items = ["apple", "banana", "cherry"]
    val picked = Random.choice(items) // String?
    
    val numbers = [1, 2, 3, 4, 5]
    val shuffled = Random.shuffle(numbers) // List<Int>
}
```

### 27.2 Seeded Random (`SeededRandom`)

`SeededRandom` is a deterministic Linear Congruential Generator (LCG) useful for games, simulations, and reproducible testing.

```kotlin
import { SeededRandom, Random } from "std.random"

fun main() {
    // Create seeded generator directly or via Random.seeded(seed)
    val rng = SeededRandom(12345)
    // or: val rng = Random.seeded(12345)

    val n1 = rng.nextInt(1, 100)
    val n2 = rng.nextInt(1, 100)
}
```

---

## 28. Primitive Numerical Types (`Int` & `Double`) and Standard Math (`std.math`)

Eiwa provides two core primitive numerical types for high-performance systems programming and numerical computation: `Int` and `Double`.

### 28.1 The `Int` Type (64-bit Signed Integer)

`Int` represents a 64-bit signed integer (mapped directly to LLVM `i64`).

* **Literals**: `42`, `-10`, `0`.
* **Conversions**:
  * `.toDouble()`: Converts `Int` to a 64-bit `Double`.
  * `.toInt()`: Returns `this` (`Int`).
  * `.toString()`: Converts the integer to its string representation.
* **Contracts**: Implements `Stringable`, `Equatable`, and `Hashable`.

```kotlin
val a: Int = 42
val d: Double = a.toDouble() // 42.0
val s: String = a.toString() // "42"
```

### 28.2 The `Double` Type (64-bit IEEE 754 Floating Point)

`Double` represents a 64-bit IEEE 754 double precision floating point number (mapped directly to LLVM `double`).

* **Literals**: Decimal numbers such as `3.14159`, `0.0`, `-15.5`, `123.456`.
* **Arithmetic & Comparisons**: Supports `+`, `-`, `*`, `/`, `<`, `>`, `<=`, `>=`, `==`, `!=`.
* **Automatic Promotion**: Mixing `Int` and `Double` in binary arithmetic (`+`, `-`, `*`, `/`) automatically promotes the operation and result to `Double`.
* **Conversions**:
  * `.toInt()`: Truncates and converts `Double` to 64-bit `Int`.
  * `.toDouble()`: Returns `this` (`Double`).
  * `.toString()`: Formats the floating point number as a string.
* **String Conversion**: `String` provides `.toDouble()` (via `Standard.atof`) to parse numbers from strings.
* **Contracts**: Implements `Stringable`, `Equatable`, and `Hashable`.

```kotlin
val pi: Double = 3.14159
val radius: Double = 2.5

// Mixed Int and Double arithmetic (promotes to Double)
val area = pi * radius * radius // 19.6349375...

// Conversions
val roundedInt: Int = area.toInt() // 19
val parsedDouble: Double = "12.34".toDouble() // 12.34
```

### 28.3 Standard Math Library (`std.math`)

The `std.math` package provides mathematical functions and utilities. Floating point math functions are bound natively to `<math.h>` double precision routines via the `Math` object.

```kotlin
import { Math, mod } from "std.math"

fun main() {
    // Trigonometry
    val s = Math.sin(1.570796) // ~1.0
    val c = Math.cos(0.0)      // 1.0
    val t = Math.tan(0.785398) // ~1.0

    // Roots & Powers
    val root = Math.sqrt(16.0)     // 4.0
    val power = Math.pow(2.0, 3.0) // 8.0

    // Rounding & Absolute Value
    val absVal = Math.abs(-15.5) // 15.5
    val fl = Math.floor(4.9)     // 4.0
    val cl = Math.ceil(4.1)      // 5.0
    val rd = Math.round(4.6)     // 5.0

    // Integer Modulo Helper
    val remainder = mod(10, 3) // 1
}
```

#### Summary of `Math` Methods

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Math.sin(x)` | `(Double) -> Double` | Returns the sine of $x$ (in radians). |
| `Math.cos(x)` | `(Double) -> Double` | Returns the cosine of $x$ (in radians). |
| `Math.tan(x)` | `(Double) -> Double` | Returns the tangent of $x$ (in radians). |
| `Math.sqrt(x)` | `(Double) -> Double` | Returns the square root of $x$. |
| `Math.pow(base, exp)` | `(Double, Double) -> Double` | Returns $base^{exp}$. |
| `Math.abs(x)` | `(Double) -> Double` | Returns the absolute value of $x$. |
| `Math.floor(x)` | `(Double) -> Double` | Returns the largest integer $\le x$. |
| `Math.ceil(x)` | `(Double) -> Double` | Returns the smallest integer $\ge x$. |
| `Math.round(x)` | `(Double) -> Double` | Returns $x$ rounded to the nearest integer. |
| `mod(a, b)` | `(Int, Int) -> Int` | Returns the integer remainder of $a / b$. |

---

## 29. Money & Financial Calculations (`std.money`)

Eiwa provides built-in support for exact financial calculations through the standard package `std.money`, based on Martin Fowler's Money Pattern and minor unit integer representation.

### 29.1 Standard Currencies & Money Type

`Money` encapsulates an integer amount of minor units (`cents: Int`) and a `Currency` instance (`code`, `name`, `symbol`, `decimals`, `decimalSeparator`, `thousandSeparator`). This guarantees zero floating point rounding errors.

```kotlin
import { brl, usd, eur, jpy, Currencies, Money, Currency } from "std.money"

fun main() {
    val m1 = brl(1050) // R$ 10,50 (1050 cents)
    val m2 = usd(2500) // $ 25.00 (2500 cents)
    val m3 = jpy(1000) // ¥ 1000 (0 decimal sub-units)

    println(m1.format()) // "R$ 10,50"
    println(m2.format()) // "$ 25.00"
    println(m3.format()) // "¥ 1,000"
}
```

### 29.2 Mathematical Operators & Currency Safety

Mathematical operations (`+`, `-`, `*`, `==`) are overloaded on `Money`. Addition and subtraction enforce strict currency matching and throw an exception if currencies differ.

```kotlin
val a = brl(1500)
val b = brl(500)

val sum = a + b    // R$ 20.00
val diff = a - b   // R$ 10.00
val mult = b * 3   // R$ 15.00
assert(sum == brl(2000))
```

### 29.3 Fowler Allocation Engine (`allocate` & `split`)

Splitting money across installments or percentages avoids fractional cent loss by allocating remainder cents 1-by-1 to the first buckets.

```kotlin
val tenReais = brl(1000) // R$ 10.00

// Split equally into 3 parts: R$ 3.34, R$ 3.33, R$ 3.33
val parts = tenReais.split(3)
assert(parts[0].cents == 334)
assert(parts[1].cents == 333)
assert(parts[2].cents == 333)
assert(parts[0] + parts[1] + parts[2] == tenReais) // Exact sum preserved!

// Weighted allocation (70% and 30%)
val allocated = tenReais.allocate([7, 3])
assert(allocated[0].cents == 700)
assert(allocated[1].cents == 300)
```


```

---

## 30. Developer CLI (`eiwa`)

`eiwa` is the official developer CLI (project and dependency management). It is written in Eiwa itself (`cli/`) and drives the `eiwac` compiler backend. See `docs/plan_package_manager.md` for the full specification.

```bash
eiwa <command> [project-dir|file.ei] [options]

Commands (implemented):
  init         Create a new project (eiwa init [dir])
  add          Add a dependency (eiwa add <name> <source> [--branch|--tag|--commit <ref>])
  remove       Remove a dependency (eiwa remove <name>)
  build        Compile the project (src/main.ei) to a native binary
  run          Compile and execute the project
  test         Run all test blocks (*_test.ei) found in the project
  freeze       Pin resolved dependency commits into eiwa.freeze
  update       Re-resolve dependencies (or one: eiwa update <name>)
  -h, --help   Show help

Arguments:
  project-dir  Project directory (default: current directory)
  file.ei      Standalone Eiwa source file (delegated to eiwac)

Options:
  -o <name>       Output binary name/path (build)
  --backend=<b>   Backend for delegated files (c | llvm)
  --release       Optimized build (delegated files)
  --frozen        Fail if eiwa.freeze does not exist (for CI)
```

### 30.1 Standalone Files (Delegation to `eiwac`)

`eiwa run`, `eiwa build` and `eiwa test` also accept a standalone `.ei` file. When any argument after the command ends with `.ei`, the CLI skips project mode entirely and forwards the full command line to the `eiwac` backend (no `eiwa.yaml` required):

```bash
eiwa run app.ei                  # compile + execute via JIT
eiwa build app.ei -o my_tool     # native binary
eiwa test app_test.ei            # run test "name" {} blocks in the file
eiwa run app.ei -- arg1 arg2     # forward args to the program after `--`
```

Flags (`--release`, `--backend=llvm`, ...) and key-value options (`-o`, `--module-path`, ...) can appear before or after the file — they are forwarded verbatim. Project commands (`init`, `add`, `remove`, `freeze`, `update`) and `run`/`build`/`test` on a directory still use the project flow.

The same flags work in **project mode**: `eiwa build --release`, `eiwa run --backend=llvm`, extra `--module-path` entries and program args after `--` (`eiwa run -- arg1 arg2`) are forwarded to the `eiwac` invocation. `-o` overrides the `output:` manifest field on `build`.

### 30.2 Project Layout & Manifest

A project is a directory with an `eiwa.yaml` manifest and a fixed `src/main.ei` entry point. `eiwa init [dir]` scaffolds it (manifest, `src/main.ei` hello world and `test/`):

```text
my-project/
├── src/
│   └── main.ei
├── test/
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

### 30.3 Git Dependencies

Dependencies come exclusively from git hosts — there is no central registry. Sources: `github:` and `gitlab:` (`org/repo` shorthand) or `git:` (any git URL), each with optional `branch`, `tag`, or `commit` (default: HEAD of the default branch).

Dependencies are resolved with `git ls-remote`, cloned once into the shared local repository `~/.eiwa/repository/<name>/<commit>`, and passed to `eiwac` as `--module-path <repo>/src`. `eiwa build` never upgrades dependencies by itself — only `eiwa update` re-resolves refs.

```bash
eiwa add orm github:eiwa-lang/orm --branch main
eiwa add pg gitlab:eiwa-lang/postgres --tag v1.0.0
eiwa add util https://git.example.com/util.git --commit 84d2ab3
eiwa remove orm
```

```kotlin
// src/main.ei
import { html } from "html"
```

### 30.4 Freeze & Reproducible Builds

The first resolution is recorded in `~/.eiwa/resolutions/<manifest-hash>.yaml` and reused without network access. `eiwa freeze` writes `eiwa.freeze` with every dependency pinned to its exact resolved commit (`branch`/`tag` are replaced by `commit`). If `eiwa.freeze` exists, it overrides the local resolution; commit it for reproducible builds. `eiwa build --frozen` fails when no freeze file exists (intended for CI). `eiwa update [name]` re-resolves from `eiwa.yaml` and refreshes both the resolution cache and the freeze file.

```yaml
# eiwa.freeze
dependencies:
  html:
    github: eiwa-lang/html
    commit: 84d2ab3
```

### 30.5 Compiler Location

The CLI locates `eiwac` in this order:

1. `EIWAC` environment variable
2. An `eiwac` binary next to the `eiwa` executable
3. `eiwac` on `PATH`

### 30.6 Not Yet Implemented

Transitive dependency resolution (MVS). The manifest parser is currently a minimal indentation parser (marked with a TODO in the code) to be replaced by a typed DTO.
