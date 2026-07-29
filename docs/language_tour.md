# The Eiwa Language Tour

Eiwa was born from a desire to write low-level systems code with the ergonomics of modern high-level languages like Kotlin. 

While Eiwa shares an almost identical baseline syntax with Kotlin, it operates in a fundamentally different environment: **there is no JVM, no massive standard library, and no runtime interpreter.** Everything is compiled directly to native code with a highly optimized embedded Garbage Collector.

Because of this, some architectural decisions differ from Kotlin to provide extreme performance and absolute safety.

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

**The Implicit Standard Library**
Eiwa comes with a core module named `system.ei` which contains fundamental types, C-bindings, and intrinsic functions (like `print`). The compiler automatically injects an `import {} from "system"` at the top of every file, making all standard functions globally available without explicitly requiring an import statement.

*(Note: In the C backend, the compiler automatically performs Name Mangling to prevent collisions across files, meaning `add` inside `math.ei` becomes `math_add` in the final native binary, ensuring absolute safety).*

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

The `[Type]` syntax is syntactic sugar for an immutable **`List<T>`**. Read elements with `[index]` or `.get(index)`, check size with `.size()`. For mutation, call `.mut()` on any immutable collection to get a `MutableList<T>` (see [Section 7.5](#75-mutability-conversion----mut-and-freeze)).

```kotlin
fun main() {
    // Immutable list literal
    val numbers = [1, 2, 3, 4, 5]
    
    // Index access
    val first = numbers[0]
    
    // For-loops iterate seamlessly over lists
    var sum = 0
    for (item in numbers) {
        sum = sum + item
    }
    
    // While loops are also fully supported
    var i = 0
    while (i < 5) {
        // do something
        i = i + 1
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

`enum` declarations define strongly typed, closed sets of constant variants with zero-overhead C transpilation:

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

## 14. Default Parameters

Eiwa supports default values for parameters in functions, methods, and type constructors (both generic and non-generic). This reduces the need for overloading and simplifies constructor instantiations.

```kotlin
// Function with default parameters
fun greet(name: String, greeting: String = "Hello") = greeting + ", " + name + "!"

type Server(val tcpServer: TCPServer = TCPServer())

fun main() {
    // Uses the default greeting "Hello"
    print(greet("Alice")) // "Hello, Alice!"
    
    // Overrides the default greeting
    print(greet("Bob", "Hi")) // "Hi, Bob!"
    
    // Instantiates Server using default constructor parameter (which calls TCPServer())
    val server = Server()
}
```

Statically typed defaults are evaluated and type-checked during function and type declarations. If a caller omits an argument that has a default value, the type checker automatically clones and injects the default expression at the call-site.

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

Because Eiwa transpiles to C, integrating with native C libraries is seamless. You can declare a `lib` block to map C functions into Eiwa without writing any wrapper code.

Annotated `lib` blocks instruct the compiler and linker on how to process native C libraries:
- **`@Header` (Compile-Time Includes)**: Instructs the C Transpiler to inject the corresponding `#include` directives at the top of the generated C file so that the C compiler knows about function signatures, structs, and constants.
- **`@Link` (Smart Linker Resolution via `pkg-config`)**: Instructs the Eiwa compiler to dynamically resolve library paths and flags using system `pkg-config` (e.g. `@Link("pq")` or `@Link("curl")`). The compiler automatically queries `pkg-config --cflags --libs` (searching standard OS and Homebrew `PKG_CONFIG_PATH` paths on macOS and Linux) and injects the appropriate `-I`, `-L`, and `-l` flags alongside preprocessor macros (`-DEIWA_USE_<NAME>`). If `pkg-config` is not available or doesn't find the package, it gracefully falls back to `-l<name>`.
- **`@Include` (Extra Include Directories)**: Appends a `-I<dir>` flag to the C compiler. Relative paths starting with `./` or `../` (e.g. `@Include("./native")`) are automatically resolved relative to the directory containing the `.ei` file.
- **`@Source` (Vendored C Sources)**: Appends a C source file to the compilation, e.g. `@Source("src/runtime/third_party/neco/neco.c")`. Use for vendored C libraries compiled together with the program.
- **`@Define` (Preprocessor Definitions)**: Appends a `-D<NAME>` or `-D<NAME=value>` flag to the C compiler, e.g. `@Define("NECO_STACKSIZE=262144")`.
- **`@Alias` (Function Names Mapping)**: Placed on individual functions inside `lib` blocks to map Eiwa `camelCase` function names to the corresponding C `snake_case` library functions.

### 16.1 Self-Contained Library Bindings

A `lib` block is self-contained: everything the C toolchain needs to build the binding is declared next to it, with no hardcoded flags in the compiler:

```kotlin
// samples/postgres/native.ei
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

When building or running Eiwa applications, you can pass custom C compiler and linker flags directly to `eiwa run`, `eiwa build`, or `eiwa test`:

```bash
# Pass custom include (-I) and library (-L) search paths
eiwa run app.ei -I /opt/homebrew/opt/libpq/include -L /opt/homebrew/opt/libpq/lib

# Build a binary with custom C defines and linked libraries
eiwa build main.ei -I/usr/local/include -L/usr/local/lib -l custom -DDEBUG_MODE

# Run tests with custom C flags
eiwa test samples/tests/postgres_test.ei -I /opt/homebrew/opt/libpq/include
```

All C flags passed on the CLI are automatically collected and forwarded to `zig cc` during compilation.

*(Note: In the current phase, Annotations are structural compiler pragmas. In future phases, Eiwa will support declaring custom user-defined annotations natively).*

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

> **Nota:** Esta seção descreve a API pública de concorrência do Eiwa. O runtime subjacente usa fibras cooperativas sobre um event loop single-threaded (kqueue/epoll). Para detalhes da implementação, consulte o ADR 35.

Eiwa oferece concorrência leve e estruturada através de duas funções da stdlib: `task { }` e `.await()`. Não existem keywords especiais, threads expostas, ou callbacks — apenas lambdas e tipos genéricos.

### 20.1 Conceitos Básicos

- `task { expr }` — função da stdlib que recebe uma lambda e retorna `Task<T>`. A lambda é executada em uma fibra separada, concorrentemente à fibra atual.
- `task.await()` — método em `Task<T>` que suspende a fibra atual até o resultado da task estar disponível. É o **único ponto de suspensão** na linguagem.
- `Task<T>` — tipo genérico declarado na stdlib com tratamento especial pelo compilador.

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

Tasks são executadas concorrentemente. O scheduler alterna entre fibras quando uma delas suspende (via `await()` ou I/O).

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

Tasks podem conter outras tasks. O `await()` interno suspende apenas a fibra da task externa, não a thread principal.

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
    // Pausa ou cede o controle da fibra atual
    Coroutine.yield()
    Coroutine.sleep(1)

    // Aguarda prontidão de socket/FD de forma não-bloqueante
    EventLoop.waitReadable(fd)
    EventLoop.waitWritable(fd)
}
```

### 20.8 Limitações do MVP

- **Sem cancelamento** — `task.cancel()` fica para uma fase futura.
- **Single-threaded** — todas as tasks rodam em uma única thread OS (scheduler concorrente). Paralelismo real (Execution Contexts) é uma evolução futura documentada no roadmap.

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
