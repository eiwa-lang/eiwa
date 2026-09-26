# Language gaps found while building eiwa-browser

Central log for `eiwa-lang` bugs, missing features and checker quirks hit
from real user code. Each entry: status, repro, impact. Fixed entries stay
as regression record with the version that fixed them.

## Open

### 1. `for` over Map with generic value type fails to compile
- Status: OPEN — RED test `samples/tests/for_map_generic_value_test.ei`
- Error: `Unresolved property 'list' on type MutableMap_String_...`
- `for` over `MutableMap<String, Int>` works; `MutableMap<String, MutableList<String>>` does not.
- Impact: `PluginRegistry` keeps a parallel names list instead of iterating.

## Fixed

### 2. `std.math.mod` does not infer a return type
- Status: FIXED — annotated explicit return type `: Int` (`src/std/math.ei`).
  `fun mod(a: Int, b: Int) = a % b` + `mod(x, 2)` call site errored with
  `Unresolved property 'plus' on type Unknown`: the `%` overload
  (SRem/FRem) does not resolve without an expected type, so single-expression
  inference still requires the annotation. Bare `= a % b` without `: Int`
  remains unsupported by design.
- Workaround no longer needed (was: use the `%` operator directly).

### 3. `eiwa build -o` rejects absolute paths
- Status: FIXED (`cli/src/main.ei`) — dirname now uses the LAST `/`
  (loop over `indexOfFrom`) and skips `mkdir` when there is no parent dir
  (`slash <= 0`). Previously `indexOf("/")` took the FIRST slash, so
  `-o /out/worker` produced `mkdir -p ""` and `-o a/b/c` only created `a`.
- Workaround no longer needed (was: build relative, then `mv`).

### 4. No `break` statement — intentional, use `leave`
- Status: CLOSED, works as documented — ADR 69 renamed `break` → `leave`
  (hard break, `break` is a plain identifier again). `leave` / `leave v`
  exits the innermost `while`/`for` (no `continue`); see
  `docs/language_tour.md` (`leave` section) and `samples/tests/leave_test.ei`.
  There is no `break` keyword by design.

### 5. `String.substring` corrupted bytes after the first NUL (strncpy)
- Status: FIXED — memcpy-based, same contract as `String.slice`.
- RED test `samples/tests/socket_binary_test.ei` went green.
- Same class untouched: `replace` (`string.ei`), `strstr`-based `indexOf`,
  `strcmp`-based `equals` on binary content.

### 6. `MutableMap`/`MutableSet` had no `remove`
- Status: FIXED in `v0.0.67` — `remove(key): V?` / `remove(element): Bool`.

### 7. Background process spawn missing from `std.process`
- Status: FIXED in `v0.0.67` — `spawn/alive/kill/wait/terminate` + `Shell`.

### 8. SHA-1 / standard base64 missing (WebSocket handshake)
- Status: FIXED in crypto lib — `sha1Base64`, `base64`, `randomBase64`.

## Checker notes (work as documented, no change requested)

- `val` narrows after early-return null checks on simple calls, but NOT
  on member-access chains (`this.values.get(..)`) and NOT through `||`
  chains — `!!` after explicit guards is the working pattern.
- Unused imports are hard errors (keep imports minimal).
- Single-file `eiwa test file.ei` does not resolve package dependencies;
  full `eiwa test` does.
