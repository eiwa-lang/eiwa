# Plan: `@Embed` — general inlining + non-local `return`

> Status: COMPLETED (2026-10-06, merged to `main` as `531d5cd`, ADR 71,
> roadmap Phases 93–94). Replaced the `@Leaveable` / `@LoopDriver` /
> `throw`-desugar stack with one general mechanism.
> Decisions: non-local `return` allowed in inlined blocks (reverses ADR 53
> for this case); `ControlFlow` contract + bypass stay (channel for
> `LeaveValue<T>`/`EmbedReturn`); `return` outside inlining stays forbidden.

## 1. Semantics

- `@Embed` on a function declaration: calls paste the callee body at the
  call site. Free functions only in v1 (method/receiver = `TypeError` at
  definition); generic functions inline their monomorphized body.
- `return [v]` anywhere in pasted code (including pasted blocks) returns
  from the CALLER (non-local). Falls out of textual scoping — no special rule.
- `leave` in pasted code binds textually to the innermost enclosing loop
  (caller loops included, Kotlin-style). No loop and no lambda boundary:
  existing "only allowed inside a loop or lambda" error.
- `leave v` in a pasted block delivers `v` as the call's value (`T?`,
  `null` when no `leave` fires) and exits the pasted region, via
  `throw LeaveValue<T>()` caught by a `catch` emitted around the expansion
  (monomorphized per call site).
- Block passed as a function VALUE (`repeat(n, ::foo)`), not a literal:
  opaque closure call, local `return`/`leave` semantics (no inline).
- `retry` stays non-`@Embed`: `leave v` there keeps erroring (success-value
  semantics is a separate feature).

## 2. Deletions (the cleanup — landed in full, Phase 94)

- `@Leaveable` (param validation, `throw` rewrite + hooks) — DELETED:
  unknown parameter annotations are now a plain `TypeError` (locked by
  `embed_never_leaveable_xfail_test.ei`).
- `@LoopDriver` (superseded as trigger) — DELETED: validation removed,
  uses dropped from `std.system`/`embed_test`; the annotation stays inert
  for backward compatibility.
- `Leave` + `catch (e: Leave)` in `std.system` + `try` wrappers — DELETED:
  `repeat`/`loop` are back to plain `while` with zero annotations.
- Value-form desugar (`desugarRepeatLoopValue`) — DELETED. `eiwaTypeToRef`
  and block `is_value` + checker/emitter/clone arms stay: the delivery
  path reuses them (`LeaveValue<T>` typeref, `var __out: T?`, trailing
  read).
- Where the bare-break channel went: loop-driver bare `leave`s are
  converted to `throw EmbedReturn()` inside `@Embed` expansion, but ONLY
  when the callee body structurally loops around a block invocation
  (`driverLoopsAroundBlock` — the shape rule, no names). Non-loop drivers
  stay purely textual (`leave` binds caller loops or errors when unbound);
  non-inlined calls keep plan-specified opaque closure semantics. Tasks
  keep working because the state machine already handles the throw/catch
  exception path (raw `break` is what it bans). `retry` (non-`@Embed`)
  drops quiet-abort: `leave` finishes the attempt (observably equivalent
  — both discard pending `err` with a normal return).
- Keep: `ControlFlow` contract + emitter bypass (channel for `LeaveValue`/
  `EmbedReturn`; ~60 lines, zero cost when unused).

## 3. Architecture

- **Trigger:** post-`resolveCallArguments` (args aligned, free + generic
  paths), pre-lambda-inference — same hook points as today's value desugar.
  Only when the block argument is a lambda literal.
- **Core:** clone callee body per call site → substitute params
  (positional/named/defaults/varargs-collected, already aligned) →
  **hygiene**: rename callee locals/params to
  `__emb_<line>_<col>_<name>` (scope-tracking walker: crosses lambdas for
  references, respects shadowing) → per block-invocation site, paste body
  with args evaluated once into fresh `val`s (`it` synthesized for the
  single implicit param; arity checked) → `leave v` becomes
  `throw LeaveValue<T>()` (T unified from `leave v` types in
  `prepareValueDelivery`, same compatibility rule as the old desugar),
  caught per expansion with `var __out: T?` + trailing read yielding the
  call value.
- **Guards:** `from_embed_body` origin marking (definition-cloned nodes)
  turns direct/indirect inline recursion into a clean `TypeError` at depth
  2 — the 64-deep inline stack stays as backstop; `@Embed` + `@Leaveable`
  on the same function compose (bare `leave` → `throw Leave()` caught by
  the body wrapper; valued `leave` → `LeaveValue` delivery).
- **Compatible by construction:** suspend/task (pasted points are textual —
  also fixes "sleep only directly in task body" for embed helpers);
  coroutine detection post-inference sees direct calls; `is_value` slots
  (`val x = embedCall()`) work via the trailing expression.

## 4. Phases

- **P0 (plumbing, DONE 2026-10-05):** parse/validate `@Embed` (free-only;
  method/receiver/object-member = `TypeError`), no inlining yet (calls
  behave as today). Tests: green `@Embed`-free-call in `embed_test.ei`;
  `embed_method/object/extension_xfail_test.ei` lock the rejection.
  (Recursion negatives need the P1 inline stack — land there.)
- **P1a (DONE 2026-10-06):** inline core as above; `repeat`/`loop` →
  `@Embed`; `embed_inline/return_test.ei` promoted (break, hygiene,
  non-local return fall out textually).
- **P1b (DONE 2026-10-06):** callee-own bare `return` → `throw
  EmbedReturn()` + per-expansion `catch (e: EmbedReturn)` (`std.exceptions`,
  `ControlFlow`-only so the existing coerce/match picks it up); valued
  callee returns keep bailing to normal calls; `retry` → `@Embed` (keeps
  `@Leaveable` + internal `Leave` catch: quiet-abort preserved).
  Tests: retry success path + custom region exit in `embed_test.ei`.
- **P2 (value, DONE 2026-10-06):** generic `LeaveValue<T> : ControlFlow` +
  per-site catch inside `@Embed` expansion (`prepareValueDelivery` unifies
  `T`, `leave v` becomes `throw LeaveValue(v)`, `var __out: T?` + trailing
  read yields the call value); old value desugar deleted; delivery keys off
  `@Embed` alone (`@LoopDriver` retired: validation removed, uses dropped
  from `std.system`/`embed_test`, stays inert); `retry` de-`@Embed`ed
  (normal call, valued `leave` rejected); non-inlined valued `leave`
  rejected explicitly by `rejectValuedLeaves` (no more lambda-mismatch
  confusion); custom `@Embed`-only driver promoted
  (`embed_valued_test.ei`); snippet
  `val x = repeat(5) { leave "Get it!" }` + all negatives green.
- **P3 (harden, DONE 2026-10-06):** valued `leave` in opaque closures is
  always a `TypeError` (declared non-`Void` early-return preserved);
  block-forwarded-as-value rejected at definition (`checkEmbedBlockUses`);
  inline recursion is a clean error via `from_embed_body` origin marking
  (was a `cloneNode` segfault; 64-cap stays as backstop); named/defaults/
  varargs, function-value fallback, nested embeds, `task` + `sleep`
  interplay, generic drivers, caller-loop `leave` binding locked in
  `embed_harden_test.ei` (7 green); 3 new permanent xfails (`forward`,
  `detached`, `recursive`); docs (tour value + `@Embed`, ADR
  71, roadmap Phase 93) + merge to `main`.

## 5. No hardcoded loop helpers

Verified on merge: zero references to `repeat`/`loop`/`retry`
(`system_repeat`, …) in Zig compiler code — only their declarations in
`src/std/system.ei` (where they belong) plus one unrelated LLVM block
label. Shape decisions read generic annotations (`@Embed`, `@Leaveable`),
never callee names. This invariant is part of
the design: new loop drivers work with zero compiler changes.

## 6. TDD suite (final state — all green / red-as-expected)

- `embed_test.ei` (14 tests, green): migration locks — statement break
  (`repeat`/`loop`/custom driver), value form (snippet, null-completion,
  `loop`, custom, annotated), plain-HOF block-exit, named/defaults,
  nested statement + nested value, `@Embed` free call, retry path,
  callee region exit.
- `embed_inline_test.ei` (2, green — promoted P1a): custom driver break
  count + caller/driver hygiene collision.
- `embed_return_test.ei` (1, green — promoted P1a): non-local return.
- `embed_valued_test.ei` (1, green — promoted P2): `@Embed`-only custom
  driver value delivery (no `@Leaveable`, no `@LoopDriver`).
- `embed_harden_test.ei` (7, green — P3): nested drivers, varargs tail,
  function-value fallback, task bodies, suspend-in-helper, generic
  drivers, caller-loop `leave` binding.
- Permanent negatives (compile-error forever, all verified): `embed_never_
  retry/plain/mixed/forward/detached/recursive_xfail_test.ei` +
  `embed_method/object/extension_xfail_test.ei`.
- Rule: no unbounded-`loop{}` break expectations in xfail files (a
  continue-semantics run would hang the harness, not fail cleanly).

## 7. Risks
- Hygiene walker is the highest-risk piece (missed capture = wrong program,
  silent). Mitigation as landed: `embed_inline_test.ei` hygiene-collision
  lock + `checkEmbedBlockUses` definition check + full-suite green on
  every commit (no dedicated Zig unit tests; the walker is exercised
  through the `.ei` suite instead).
- Non-local `return` reopens ADR 53 deliberately and only under `@Embed`;
  everywhere else the ban and its tests stand.
- Code bloat per inlined call (documented in the tour, Kotlin has the same
  trade-off).
- Labeled break (G6) stays out: region exit goes through `LeaveValue` /
  textual loops, never needing labels.
