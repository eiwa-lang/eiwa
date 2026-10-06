# Plan: `@Embed` — general inlining + non-local `return`

> Status: PLANNED (approved 2026-10-05). Replaces the `@Leaveable` /
> `@LoopDriver` / `throw`-desugar stack with one general mechanism.
> Decisions: non-local `return` allowed in inlined blocks (reverses ADR 53
> for this case); `ControlFlow` contract + bypass stay (channel for
> `LeaveValue<T>`); `return` outside inlining stays forbidden.

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

## 2. Deletions (the cleanup)

- `@Leaveable` (param validation, `throw` rewrite + hooks).
- `@LoopDriver` (superseded as trigger; shape rule moves into `@Embed` validation).
- `Leave` + `catch (e: Leave)` in `std.system` + `try` wrappers (loops go
  back to plain `while`).
- Value-form desugar (`desugarRepeatLoopValue`, `eiwaTypeToRef`,
  block `is_value` + checker/emitter/clone arms for it).
- Keep: `ControlFlow` contract + emitter bypass (channel for `LeaveValue`;
  ~60 lines, zero cost when unused).

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
  `{ __res = v; throw LeaveValue<T>() }` (T unified from `leave v` types,
  same compatibility rule as today).
- **Guards:** inline stack (direct/indirect recursion = error);
  `@Embed` + `@Leaveable` on the same param is redundant (allowed, ignored).
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
  interplay locked in `embed_harden_test.ei` (5 green); 3 new xfails
  (`forward`, `detached`, `recursive`); docs (tour value + `@Embed`, ADR
  71, roadmap Phase 93) + merge to `main`.

## 5. No hardcoded loop helpers

Verified 2026-10-05: zero references to `repeat`/`loop`/`retry`
(`system_repeat`, …) in Zig compiler code — only their declarations in
`src/std/system.ei` (where they belong) plus one unrelated LLVM block
label. Shape decisions read generic annotations (`@Embed`, `@Leaveable`)
and arity (1 vs 2 params), never callee names. This invariant is part of
the design: new loop drivers work with zero compiler changes.

## 6. TDD suite (RED now, promotes per phase)

- `embed_test.ei` (11 tests, green): migration locks that must stay green
  — statement break (`repeat`/`loop`/custom `@LoopDriver`), value form
  (snippet, null-completion, `loop`, custom, annotated), plain-HOF
  block-exit, named/defaults, nested statement + nested value.
- `embed_inline_xfail_test.ei` (2 runtime-RED → P1): custom `@Embed`
  driver break count + caller/driver hygiene collision.
- `embed_return_xfail_test.ei` (compile-RED → P1): non-local return.
- `embed_valued_xfail_test.ei` (compile-RED → P2): custom `@Embed`
  driver value delivery. NOTE: P2 desugar must find the block by function
  type, not only `@Leaveable` (test drivers carry both, but `@Embed`
  alone must work).
- Permanent negatives (compile-error forever): `embed_never_retry_`,
  `embed_never_plain_`, `embed_never_mixed_xfail_test.ei`.
- P0 adds: `@Embed`-on-method and `@Embed`-recursion negatives (can't
  land now — `@Embed` is inert metadata today, so they'd XPASS).
- Rule: no unbounded-`loop{}` break expectations in xfail files (a
  continue-semantics run would hang the harness, not fail cleanly).

## 7. Risks
- Hygiene walker is the highest-risk piece (missed capture = wrong program,
  silent). Mitigation: dedicated unit tests (shadowing, nested lambdas,
  boxed captures) before P1 lands.
- Non-local `return` reopens ADR 53 deliberately and only under `@Embed`;
  everywhere else the ban and its tests stand.
- Code bloat per inlined call (documented, Kotlin has the same trade-off).
- Labeled break (G6) stays out: region exit goes through `LeaveValue` /
  textual loops, never needing labels.
