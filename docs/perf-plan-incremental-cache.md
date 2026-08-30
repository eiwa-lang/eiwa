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
| A2 | Split `emitNativeBinary` into `emitObject(module) → .o` + `linkObjects([.o]) → bin` | ⬜ pending | | next task |
| A3 | Per-module emission: emit-all-bodies + linker dead-strip; `internal` helpers; `eiwa_runtime.o` (shared mutable state); `linkonce_odr` generics/coroutine trampolines; vtables in `llvm.used` | ⬜ pending | | see Decisions A/D/E |
| A4 | Per-module object cache wired into default build/run path (relink only changed modules) | ⬜ pending | | target: warm edit-run ≤ 0.3s |
| A5 | (optional) Serialized type-check cache for std/deps modules; export-data-based invalidation (comment-only changes don't rebuild dependents) | ⬜ pending | | measure first |

**Current focus:** A2 (split emit/link). Guardrail after each step:
`zig build && zig build test && ./bin/eiwac test` (must stay 95/95) +
benchmark on `example/home`.

### Resume checklist (next session)

1. `git checkout perf/incremental-cache && zig build`
2. Guardrail baseline: `./bin/eiwac test` (95/95, ~57s)
3. Continue from "Current focus" above.

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
| Shared **mutable** runtime state | `eiwa_exception_stack`, `eiwa_active_exception`, `eiwa_argc`/`eiwa_argv` | **`eiwa_runtime.o`** — emitted once, keyed by (compiler version + flags). `linkonce_odr` on mutable globals is unsafe (linker may pick any copy). |
| Pure helpers/intrinsics | `eiwa_to_string`, `eiwa_str_replace` | **`internal` linkage** per object — private copies, stripped by linker, zero collision risk. |
| `llvm.global_ctors` (GC init) | `__eiwa_gc_init_ctor` | Emitted **only in the entry module's object** (owns `main`). |

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

Register vtable globals in `llvm.used` (Mach-O `no_dead_strip`); the linker
keeps initializer-referenced methods transitively — no per-method marking
needed.

### E. Monomorphized generics & coroutine trampolines

Instantiations emitted in the using module's object with **`linkonce_odr`**
(LLVM maps to COMDAT on COFF/Windows) so duplicates across objects merge.

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
