# Plan: Lambda-Style `for` Loop Syntax (`for (iterable) { it -> ... }`)

## 1. Overview & Motivation
Transform the `for` loop syntax in Eiwa to adopt a Kotlin-like lambda block style:
- Explicit parameter: `for (numbers) { n -> println(n) }`
- Implicit single parameter (`it`): `for (numbers) { println(it) }`

This aligns the control-flow construct syntax with Eiwa's idiomatic lambda and higher-order function ergonomics while retaining zero-cost loop execution and native coroutine suspension points without heap-allocated closures.

---

## 2. Syntax Specifications

### 2.1 Explicit Parameter
```kotlin
val numbers = [1, 2, 3]
for (numbers) { n ->
    println(n)
}
```

### 2.2 Implicit Parameter (`it`)
```kotlin
val numbers = [1, 2, 3]
for (numbers) {
    println(it)
}
```

### 2.3 Multiple Statements in Block
```kotlin
for (users) { user ->
    val name = user.name
    println("User: " + name)
}
```

---

## 3. Architecture & Affected Modules

| Component | File | Responsibility |
|---|---|---|
| **Parser** | `src/frontend/parser/statement.zig` | Parse `for (iterable) { [param ->] ... }` instead of `for (item in iterable)`. Lookahead for `->` to detect explicit param vs implicit `it`. |
| **AST** | `src/core/ast.zig` | Maintain or adapt `for_stmt` (`item_name: []const u8`, `iterable: *ASTNode`, `body: *ASTNode`). Defaults `item_name = "it"` when omitted. |
| **Type Checker** | `src/core/type_checker/infer_stmt.zig` | Register `item_name` (or `"it"`) in the inner loop scope with element type `T` of `Array<T>` / `List<T>`. |
| **Coroutines Pass** | `src/core/coroutines.zig`, `src/core/coroutines_transform.zig` | Ensure `for_stmt` suspend detection and continuation state-machine generation work seamlessly with the new AST nodes. |
| **LLVM Emitter** | `src/backend/llvm_emitter/statement.zig` | Generate indexed loop basic blocks (`for.cond`, `for.body`, `for.after`) binding the loop iteration variable to the loaded element. |
| **Stdlib & Samples** | `samples/`, `docs/language_tour.md` | Migrate all existing `for (x in list)` occurrences to the new lambda-style syntax. |

---

## 4. Detailed Task Breakdown

### Task 1: Parser Implementation
- **File**: `src/frontend/parser/statement.zig`
- **Action**:
  - Update `forStatement`:
    1. Parse `for` + `(` + `iterable_expression` + `)`.
    2. Expect `{`.
    3. Lookahead inside block for `->`:
       - If `param ->` found: consume parameter identifier and `->`.
       - If no `->` found: set `item_name = "it"`.
    4. Parse body statements until `}`.
  - Return `for_stmt` AST node.

### Task 2: Type Checker Scope & Validation
- **File**: `src/core/type_checker/infer_stmt.zig`
- **Action**:
  - Infer type of `iterable`.
  - Extract element type `T`.
  - Bind `item_name` (either custom name or `"it"`) in `for_scope` as immutable `val`.
  - Infer body node with `for_scope`.

### Task 3: LLVM Code Generator & Coroutines AST Transforms
- **Files**: `src/backend/llvm_emitter/statement.zig`, `src/core/coroutines_transform.zig`
- **Action**:
  - Verify variable symbol binding maps `item_name` to the LLVM alloca / register slot.
  - Test coroutine state machine transformation when suspension calls (`await()`, `sleep()`) exist inside lambda-style `for`.

### Task 4: Samples, Tests & Documentation Update
- **Files**: `docs/language_tour.md`, `samples/arrays_and_loops.ei`, `samples/varargs_sample.ei`, `samples/tests/*`
- **Action**:
  - Update `docs/language_tour.md` section on loops and varargs.
  - Update sample programs and add unit tests verifying both explicit `n ->` and implicit `it` forms.

---

## 5. Verification Checklist (Phase X)

- [ ] Compiler builds cleanly with `zig build`.
- [ ] Compiler test suite passes with `zig build test`.
- [ ] `./bin/eiwac run samples/arrays_and_loops.ei` runs and outputs correct values.
- [ ] New test file with `for (list) { it }` and `for (list) { item -> item }` succeeds.
- [ ] Suspension inside `for (list) { task.await() }` passes coroutines test suite.
