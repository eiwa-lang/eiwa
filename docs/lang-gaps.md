# Language gaps found while building eiwa-browser

Central log for `eiwa-lang` bugs, missing features and checker quirks hit
from real user code. Only open work stays here; resolved items live in git
history. Each entry: status, repro, impact.

## Open

### 1. `for` over Map with generic value type fails to compile
- Status: OPEN — RED test `samples/tests/for_map_generic_value_test.ei` (XFAIL: fails to compile as expected)
- Error: `Unresolved property 'list' on type MutableMap_String_...`
- `for` over `MutableMap<String, Int>` works; `MutableMap<String, MutableList<String>>` does not.
- Impact: `PluginRegistry` keeps a parallel names list instead of iterating.

### 2. Narrowing futures: `var`, heap-boxed scalars, `while` conditions
- Status: OPEN, deferred by design — `val` narrows after early-return null
  checks through `&&`/`||` chains, but these do not: `var` (needs mutation
  analysis), heap-boxed scalars (`Int?`/`Bool?`/`Double?` need unbox
  plumbing), `while` conditions. Member chains stay explicit-bind by
  design (impure re-evaluation): `val v = this.values.get(..)` first.
- Repro: identical guard shape warns (redundant `!!`) on `val` but
  hard-errors inside the guard on `var` (`Only safe (?.)... narrows vals
  only`).
- RED test `samples/tests/var_guard_xfail_test.ei` (XFAIL: fails to
  compile as expected). Contract: `samples/tests/smartcast_var_xfail_test.ei`
  (v1 `val`-only rule); baseline `samples/tests/smartcast_logic_test.ei`
  (10 tests, green).
