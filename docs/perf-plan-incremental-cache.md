# Plan: Incremental Cache & Fast `eiwa run` (Go-like)

> **Living document** — tracks implementation status so work can be resumed
> in a later session. Update the Status table and "Current focus" when
> stopping/continuing.

## Goal

`eiwa run` / `eiwa build` warm ≈ Go: **~0.01s when unchanged** (cache hit),
**link-floor (~0.2-0.3s) when only the entry module changed** (Phase A2+).

---

## Status Tracker

| ID | Task | Status | Branch | Notes |
|----|------|--------|--------|-------|
| B | ReleaseSafe default + token-indexed reachability | ✅ done | `perf/emitter-hotpaths` (merged into A branch) | 4x on build |
| A0 | Full-program binary cache in `eiwac` + `run --aot` (build-if-stale + exec) | ✅ done | `perf/incremental-cache` | hit = ~0.01-0.02s |
| A1 | Cache infra: sha256 key (closure sources + eiwac binary + flags), `~/.eiwa/cache/bin`, `EIWA_CACHE_DIR`, `--no-cache` | ✅ done | `perf/incremental-cache` | |
| A2 | Split `emitNativeBinary` into `emitObjectFile(module) → .o` + `linkObjects([.o]) → bin` | ✅ done | `perf/incremental-cache` (736b03b) | temp object unique per pid |
| A3 | Two-unit split emission: deps unit (std + `--module-path` deps, cached object) × entry unit (project code, always emitted) | 🔄 **in progress** | `perf/incremental-cache` (**uncommitted**) | see sub-tasks below |
| A4 | Per-module object cache wired into default build/run path (relink only changed modules) | ⬜ pending | | target: warm edit-run ≤ 0.3s |
| A5 | (optional) Serialized type-check cache for std/deps modules; export-data-based invalidation (comment-only changes don't rebuild dependents) | ⬜ pending | | measure first |

**Current focus:** A3 — **implementado e funcional**. Guardrail pegou **1 falha**
(`cli_integration_test`: build standalone `.ei`) → root cause = **deps.o instável**
(vtables de pool types). Corrigido com pool signature no hash. **Validando + commit pendente.**

### A3 sub-tasks

| # | Sub-task | Status |
|---|----------|--------|
| A3.1 | Emitter unit-ownership fields (`unit_modules`, `unit_is_entry`) + `unitOwns` | ✅ |
| A3.2 | Prologue gates: GC ctor entry-only; exception globals entry-defined/others-extern; helpers `internal` linkage | ✅ |
| A3.3 | `declareEnum`/`declareType`/Pass 1d: define own, declare extern others | ✅ |
| A3.4 | Reachability skip in split; body loops filtered by ownership + owned/foreign name sets | ✅ |
| A3.5 | Vtable pass: own defines, others extern-declared (whole-program vtable set visible in every unit for `when is` checks); `isRealVtable` accepts extern constant decls | ✅ |
| A3.6 | Stub pass: only stub own symbols (entry also stubs leftover synthetics) | ✅ |
| A3.7 | Epilogue gates: `emitArgvSupport`/`emitEntryShim` entry-only | ✅ |
| A3.8 | `main.zig` orchestration: module partition (`isDepModulePath`), deps object at `~/.eiwa/cache/objects/<hash>.o`, two-emitter flow + `linkObjects` | ✅ |
| A3.9 | `zig build` + fix compile errors | ✅ |
| A3.10 | **Link-collision fixes** (bugs encontrados ao validar): | ✅ |
| | ① use-after-free no pool loop (`owned_names.put(fname)` com `defer free`) | ✅ |
| | ② helpers `.N` renomeados ainda externos → sweep internaliza `base.N` | ✅ |
| | ③ `lambda_anon_N` colide entre units (contador global) → `internal` | ✅ |
| | ④ `main` duplicado: Pass 3 hybrid-main roda no deps unit → gated por ownership | ✅ |
| | ⑤ stub pass stubbava símbolos dos deps (`coroutines_StackTask`, métodos derivados `log_Logger_error_...`) → set `dep_owned_fns` | ✅ |
| | ⑥ dedupe `seen_types` (clones monomorfizados espalhados por módulos) | ✅ |
| | ⑦ types genéricos base (`List`, `StackTask`) — ctor de template também dep-owned | ✅ |
| | ⑧ **deps.o instável**: `is List<T>` no `equals` genérico referencia vtables de TODAS as instâncias do pool → **pool signature** (nomes ordenados de `classes_ast`) no hash do deps.o (invalida só quando o set de tipos instanciados muda) | ✅ |
| A3.11 | Functional test: `home` HTTP 200 ✅, `hello` HTML ✅, JIT-vs-AOT MATCH (`hello`, `arrays_and_loops`) ✅, `make build` ✅, `eiwa build app.ei` standalone ✅ (após ⑧) | ✅ |
| A3.12 | **Guardrail**: `zig build test` ✅; `eiwac test` **94/95** — a falha (`cli_integration_test`) foi DIAGNOSTICADA como o bug ⑧ e corrigida; **rerun pendente** | 🔄 |
| A3.13 | Benchmark entry-change rebuild = 0,27s (deps.o reutilizado quando pool estável) ✅; commit A3 | ⬜ |

> **Nota A3.12:** o guardrail `eiwac test` é JIT e não cobre o caminho split — a falha
> apareceu porque o teste invoca `eiwac build` do CLI (que usa split). A correção ⑧
> garante que o deps.o cache seja invalidado corretamente quando o pool muda.

### Resume checklist (next session)

1. `git checkout perf/incremental-cache && zig build`
2. A3 state is **uncommitted** in the working tree (`src/main.zig`, `src/backend/llvm_emitter/core.zig`, `expression.zig`, `docs/perf-plan-incremental-cache.md`) — continue from A3.12/A3.13.
3. Guardrail: `./bin/eiwac test` (95/95, ~57s) — JIT path, unaffected by A3; A3 needs its own AOT verification (A3.11) + benchmark (A3.13).

---

## Benchmarks (project `example/home`, Apple Silicon)

| Scenario | Before (Debug eiwac, no cache) | After B | After A0/A1 |
|----------|-------------------------------|---------|-------------|
| `eiwa build` (sources unchanged) | 2.78s | 0.65s | **0.02s** |
| `eiwac build` direct (unchanged) | 2.59s | 0.65s | **0.01s** |
| `eiwa run` → server responding | ~2.8s + JIT start | — | **≤0.1s to exec** (HTTP 200 verified) |
| `eiwa build` (entry source changed) | 2.78s | 0.65s | 0.52-0.65s (full re-emit; A2+ targets ~0.3s) |
| `eiwac test` (95-test guardrail) | 100.76s | 56.59s | 56.59s (JIT path untouched) |

Warm-breakdown after B (what A2+ still attacks): frontend+typecheck ~0.15s,
coroutines ~0.05s, `emitModule` ~0.15s, LLVM `.o` emit ~0.25s, `cc` link ~0.1s.

---

## Architecture decisions (validated in design review)

### A. Duplicate symbols under per-module emission — three-way split

| Category | Examples | Solution |
|----------|----------|----------|
| Shared **mutable** runtime state | `eiwa_exception_stack`, `eiwa_active_exception`, `eiwa_argc`/`eiwa_argv` | ~~`eiwa_runtime.o`~~ → **implemented as: owned by the entry unit** (it owns `main`); other units reference them as extern declarations. Same single-definition guarantee, one less object to version. |
| Pure helpers/intrinsics | `eiwa_to_string`, `eiwa_str_replace`, `GC_MALLOC`/`GC_REALLOC` wrappers | **`internal` linkage** per object — private copies, stripped by linker, zero collision risk. |
| `llvm.global_ctors` (GC init) | `__eiwa_gc_init_ctor` | Emitted **only in the entry unit** (owns `main`). |

> **A3 scope note:** the implementation splits into **two units** (deps+std ×
> project) instead of N per-module objects. The mechanisms are identical;
> two units capture ~90% of the win (deps dominate emitted code and rarely
> change) with far less link surface. N-way remains possible in A4 if
> benchmarks justify it.

### B. Transitive invalidation

Cache key covers **sources of the whole import closure** + eiwac binary
(embeds stdlib via `std_modules`) + target triple + flags + `EIWA_BASELINE_CPU`.
Transitive dep changes invalidate by construction. Known coarseness: any
byte change in a dep rebuilds dependents (Go pre-1.20 behavior); refining to
export-data hashing is A5.

### C. JIT (MCJIT) — retained for now, not for `eiwa run`

- `eiwa run` (projects): AOT cache path (build-if-stale + spawn). **Done (A0).**
- `eiwac test`: still JIT — it is the 95-test guardrail; migrating it to AOT
  is a separate decision after A3 proves the native path.
- `eiwac run file.ei` (standalone scripts): still JIT (fast for tiny files,
  no project context).

### D. Vtables under `-dead_strip` / `--gc-sections`

~~Register vtable globals in `llvm.used`~~ → **implemented as: whole-program
vtable protocol.** `when (x) is Contract` checks iterate every `_vtable`
global in the module, so each unit pre-declares the *complete* vtable set:
the owning unit defines it (`constant`, with initializer), other units
declare it extern (`constant`, no initializer — accepted as real by
`isRealVtable`). No dead-strip attributes needed because all vtables stay
referenced.

### E. Monomorphized generics & coroutine trampolines

~~`linkonce_odr`~~ → **implemented as: entry-unit ownership.** Pool types
(`classes_ast`) are defined only by the entry unit; dep units reference them
extern. No duplicates → no ODR merging needed. (If A4 goes N-way per-module,
this decision must be revisited — `linkonce_odr` becomes necessary again.)

### Linker strategy

Keep system `cc` driver. `lld`/`mold` detection is low priority (macOS `ld`
link floor measured ~0.1s); revisit only if Linux benchmarks show otherwise.

---

## Original design notes (per-module object cache, A2-A4)

- Cache dir: `~/.eiwa/cache/objects/<content-hash>.o` (+ `.meta` sidecar).
- Key: `sha256(eiwac_version | target_triple | opt_flags | module_source | transitive_dep_hashes)`.
- Per-module objects replace today's single-LLVM-module whole-program
  emission for the **build** path; the reachability pass
  (`markReachable`/`drainReachableWorklist`) stays for the JIT path only.
- Final link: all objects + `eiwa_runtime.o` + libgc + lib requirements via
  the existing `cc` driver; skip relink when the output binary is newer than
  every input object.

### Known limitations / follow-ups

- `temp_llvm.o` is written to the CWD during emission — concurrent `eiwac`
  processes in the same directory can collide (pre-existing; per-module
  emission should use per-object temp names).
- `argv[0]` seen by the program under `run --aot` is the cached binary path,
  not the entry file basename (JIT shows the basename). Cosmetic; revisit if
  it bites.
