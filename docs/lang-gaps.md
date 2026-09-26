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

### 2. `std.math.mod` does not infer a return type
- Status: OPEN (reported, no RED test — inference failure, not runtime)
- `fun mod(a: Int, b: Int) = a % b` + `mod(x, 2)` call site errors with
  `Unresolved property 'plus' on type Unknown`. The `%` overload
  (SRem/FRem) does not resolve without an expected type.
- Workaround in user code: use the `%` operator directly (typed operands).

### 3. `eiwa build -o` rejects absolute paths
- Status: OPEN (reported, no RED test yet)
- `eiwa build -o /out/worker` fails with `mkdir -p` empty operand;
  relative `-o worker` works. Suspect: dirname handling of absolute paths.
- Workaround in user code: build relative, then `mv` (see browser Dockerfile).

### 4. No `break` statement (unconfirmed whether intentional)
- Status: OPEN question — no `break` found in std, samples or arest;
  loops use flag conditions instead.
- Impact: low (flag pattern works); needs a yes/no from language owners.

## Fixed

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
