# Plan: Incremental Object Cache (Go-like `eiwa run`)

> Status: **planned** — Phase B (hot paths) shipped in `perf/emitter-hotpaths`.
> This document is the implementation plan for Phase A.

## Goal

`eiwa run` / `eiwa build` on an unchanged project should cost **link-time only**
(~0.2–0.3s), like `go run`. Today every run recompiles the entry module, the
whole import closure (dependencies), and the stdlib from scratch.

## Baseline (after Phase B, Apple Silicon, `example/home`)

| Phase | Warm time | Share |
|-------|-----------|-------|
| eiwa CLI (deps already resolved via `~/.eiwa/resolutions`) | ~0.01s | ~2% |
| Frontend + type check (passes 1–3) | ~0.15s | ~23% |
| Coroutines detect/transform | ~0.05s | ~8% |
| `emitModule` (LLVM IR construction) | ~0.15s | ~23% |
| `emitNativeBinary` (LLVM → `temp_llvm.o` + `cc` link) | ~0.30s | ~46% |
| **Total** | **~0.65s** | |

Phase B already shipped: ReleaseSafe default build of `eiwac` (2.2x), token
index for `markReachable`/vtable lookups (O(F) scan → bucket lookup),
allocation-free related-name matching.

## Design

### Cache model (mirrors Go)

- Cache dir: `~/.eiwa/cache/objects/<content-hash>.o` (+ `.meta` sidecar).
- Cache key: `sha256(eiwac_version | target_triple | opt_flags | module_source | resolved_dep_hashes)`.
- On build: for each module in the import closure, compute key; hit → reuse
  `.o`; miss → emit that module's `.o` into the cache.
- Final step: link all objects (cached or fresh) + libgc + lib requirements
  via the existing `cc` driver (`emitNativeBinary`'s link half).

### The hard part: from one module to per-module emission

Today `emitModule` builds **one LLVM module** for the whole program and uses a
whole-program reachability fixpoint (`markReachable`/`drainReachableWorklist`)
to prune unreachable bodies (JIT-oriented). Per-module objects require:

1. **Emit-all-bodies per module** instead of whole-program reachability.
   Dead code is stripped by the linker: `-dead_strip` (macOS),
   `--gc-sections` with `-ffunction-sections` (Linux), `/OPT:REF` (Windows).
   Keep the reachability pass for `run` (JIT) only.
2. **Cross-module symbols**: functions/types referenced from other modules
   must be emitted with external linkage under their mangled names (already
   the convention). Module-private helpers get internal linkage.
3. **Monomorphized generics** are instantiated at the *use* site, not the
   declaration module. Emit them in the using module's object with
   `linkonce_odr` linkage so duplicate instantiations across objects merge
   at link time (C++ template model).
4. **Vtables / contract metadata**: emit alongside the implementing type's
   module (they are keyed by `{type}_{contract}` and already deterministic).
5. **Globals & init order**: object member globals and entry top-level
   statements keep the current single-entry emission in the entry module.

### Frontend sharing

Parsing/type-checking is ~25% of warm time and grows with project size. The
same content hash can gate a **serialized check-result cache**
(`<hash>.checked`) later; not required for A1 — measure first.

## Steps

| Step | Scope | Verification |
|------|-------|--------------|
| A1 | Cache infra: key computation, cache dir layout, `EIWA_CACHE_DIR` override, `--no-cache` escape hatch | unit test: key stability/invalidation |
| A2 | Split `emitNativeBinary` into `emitObject(module) → .o` + `linkObjects([.o]) → bin`; keep current single-object path as fallback | `eiwac test` 100% |
| A3 | Per-module emission (emit-all-bodies + section-based stripping) behind `--incremental` flag | `eiwac test` 100% + binary equivalence on samples |
| A4 | Wire cache into `eiwa build/run` default path; relink-skip when binary is newer than all inputs | benchmark: unchanged `home` run ≤ 0.3s |
| A5 | (optional) serialized type-check cache | benchmark |

## Risks / open questions

- **Link-time floor**: `cc` link of ~5–10 objects + libgc is ~0.1–0.15s; this
  is the floor for warm builds (Go pays the same).
- **`-dead_strip` correctness**: functions referenced only via fat-pointer
  vtables or trampolines must be marked `no_strip`/kept — the stub pass
  already solved the analogous problem for reachability; reuse its rules.
- **Debug info**: dev builds currently emit no `-g`; keep it that way for
  cache-hit speed (adding `-g` later changes the cache key only).
