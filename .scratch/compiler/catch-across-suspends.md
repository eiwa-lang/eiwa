# Compiler: catch in task misses throws across 2+ suspend boundaries

**What to build:** make the existing try/catch-in-task pattern (see
coop_try_catch_repeated_test.ei) work when the throw happens after more
than one suspend point in the same task machine — or document the
restriction and fail loudly at compile time instead of an unhandled throw
at runtime.

**Blocked by:** None (reproduces on host today, no ESP needed).

**Status:** ready-for-agent

- [ ] Repro 1 (fails today): task with a suspend call before try, then a
      call to a transitively-suspending helper that throws inside try —
      the throw escapes (`unhandled ... reached the top level`).
- [ ] Repro 2 (fails today): task with two suspend calls inside one try
      before the throw — same escape. (`/tmp/probe11.ei`, `/tmp/probe12.ei`
      shapes; single-suspend variants pass.)
- [ ] Same shapes in plain (non-task) functions pass today
      (`/tmp/probe13.ei` shape) — the bug is specific to task state
      machines (likely excState/label bookkeeping across resumes, same
      family as the documented "label BEFORE enqueuing" fix).
- [ ] Full host suite (`eiwac test`) stays green.
