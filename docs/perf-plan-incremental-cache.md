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
| B | ReleaseSafe default + token-indexed reachability | ✅ done | `perf/emitter-hotpaths` | 4x on build |
| A0 | Full-program binary cache in `eiwac` + `run --aot` (build-if-stale + exec) | ✅ done | `perf/incremental-cache` | hit = ~0.01-0.02s |
| A1 | Cache infra: sha256 key (closure sources + eiwac binary + flags), `~/.eiwa/cache/bin`, `EIWA_CACHE_DIR`, `--no-cache` | ✅ done | `perf/incremental-cache` | |
| A2 | Split `emitNativeBinary` into `emitObjectFile(module) → .o` + `linkObjects([.o]) → bin` | ✅ done | `perf/incremental-cache` (736b03b) | temp object unique per pid |
| A3 | Two-unit split emission: deps unit (std + `--module-path` deps, cached object) × entry unit (project code, always emitted) | ✅ **done** | `perf/incremental-cache` (0ad2430) | see sub-tasks below |
| A4 | N-way per-module object cache (granular relink) | ⬜ pending | | **revisited** — 2-units já é default (ver nota); N-way só se benchmark justificar |
| A5 | (optional) Serialized type-check cache for std/deps modules; export-data-based invalidation (comment-only changes don't rebuild dependents) | ⬜ pending | | measure first |

**Current focus:** A4 — avaliar se N-way granular vale a pena vs o split 2-units já
entregue. O split **já é o caminho default** para `eiwac build` e `run --aot`
(qualquer compilação host com cache usa deps.o + entry.o).

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
| | ⑧ **deps.o instável**: `is List<T>` no `equals` genérico referencia vtables de TODAS as instâncias do pool → **pool signature** (nomes ordenados de `classes_ast`) no hash do deps.o | ✅ |
| A3.11 | Functional test: `home` HTTP 200 ✅, `hello` HTML ✅, JIT-vs-AOT MATCH (`hello`, `arrays_and_loops`) ✅, `make build` ✅, `eiwa build app.ei` standalone ✅ | ✅ |
| A3.12 | **Guardrail**: `zig build test` ✅; `eiwac test` **95/95 PASSED** (56.47s) após correção ⑧ | ✅ |
| A3.13 | Benchmark entry-change rebuild = 0,27s ✅; **commit A3 = `0ad2430`** | ✅ |

### Resume checklist (next session)

1. `git checkout perf/incremental-cache && zig build`
2. Working tree **clean** (A3 + docs committed: `53215fd`, `736b03b`, `0ad2430`; user commits `a99bfc0`).
3. Guardrail: `./bin/eiwac test` (95/95, ~57s) + `zig build test`.
4. Continue from **A4** (below).

---

## Benchmarks (project `example/home`, Apple Silicon)

| Scenario | Before (Debug eiwac, no cache) | After B | After A0/A1 | **After A3 (split)** |
|----------|-------------------------------|---------|-------------|----------------------|
| `eiwa build` (sources unchanged) | 2.78s | 0.65s | **0.02s** | **0.01-0.02s** (binary cache hit) |
| `eiwac build` direct (unchanged) | 2.59s | 0.65s | **0.01s** | **0.01s** |
| `eiwa run` → server responding | ~2.8s + JIT start | — | ≤0.1s to exec | **≤0.1s** (HTTP 200 verified) |
| `eiwa build` (**entry source changed**) | 2.78s | 0.65s | 0.52-0.65s | **0.27s** (deps.o reusado, entry re-emitido) |
| `eiwac test` (95-test guardrail) | 100.76s | 56.59s | 56.59s | **56.47s** (JIT path untouched) |

Warm-breakdown after A3 (what A5 still attacks): frontend+typecheck ~0.15s,
coroutines ~0.05s, entry `emitModule` + LLVM codegen ~0.05s, `cc` link ~0.1s.

---

## A4 — N-way per-module (revisited)

O split 2-units **já é default** (todo `eiwac build`/`run --aot` host usa deps.o +
entry.o). A4 granular (um `.o` por módulo) traria ganho marginal: o entry unit
re-emite TODO o código do projeto a cada mudança, mas o código do projeto é
pequeno comparado a deps+std (que ficam cacheados). O custo real restante no
dev-loop é **frontend + typecheck** (~0.15s, atacado pela A5), não a emissão.

**Decisão A4:** N-way **adiado**. Fazer só se o projeto crescer o suficiente
para o entry unit dominar o tempo (medir: `time eiwac build --no-cache` num
projeto grande). A A5 (cache de typecheck) tem prioridade — é o próximo
gargalo fixo.

### A5 — Cache de typecheck (próximo)

Serializar o resultado do type-check de módulos de std/deps (AST resolvida +
símbolos) keyed por hash de source, reutilizando entre builds. Meta: derrubar
o `~0.15s` de frontend+typecheck do entry-change rebuild (0,27s → ~0,12s).

---

## Architecture decisions (validated in design review)

### A. Duplicate symbols under per-module emission — three-way split

| Category | Examples | Solution |
|----------|----------|----------|
| Shared **mutable** runtime state | `eiwa_exception_stack`, `eiwa_active_exception`, `eiwa_argc`/`eiwa_argv` | ~~`eiwa_runtime.o`~~ → **implemented as: owned by the entry unit** (it owns `main`); other units reference them as extern declarations. Same single-definition guarantee, one less object to version. |
| Pure helpers/intrinsics | `eiwa_to_string`, `eiwa_str_replace`, `GC_MALLOC`/`GC_REALLOC` wrappers | **`internal` linkage** per object — private copies, stripped by linker, zero collision risk. |
| `llvm.global_ctors` (GC init) | `__eiwa_gc_init_ctor` | Emitted **only in the entry unit** (owns `main`). |

> **A3 scope note:** implemented as **two units** (deps+std × project) — the
> mechanisms are identical to N-way; two units capture ~90% of the win (deps
> dominate emitted code and rarely change) with far less link surface. See A4
> for the N-way reconsideration.

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

## Known limitations / follow-ups

- `argv[0]` seen by the program under `run --aot` is the cached binary path,
  not the entry file basename (JIT shows the basename). Cosmetic; revisit if
  it bites.
- `temp_llvm.o` name is now unique per pid (A2) — concurrent `eiwac` builds
  in the same directory no longer collide.
