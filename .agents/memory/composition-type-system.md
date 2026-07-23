---
type: project
created: 2026-07-19
updated: 2026-07-19
---

# Composition Type System (Phase 41 / ADR 25) — IMPLEMENTED

## Status: COMPLETED (2026-07-19)
- All 10 plan tasks done on the current branch (user waived a dedicated branch).
- `zig build`, `zig build test`, and `eiwa test samples/tests` (88/88) all pass.
- Pre-existing bugs found AND FIXED: `eiwa_main` missing return (UB exit codes), circular-import phantom alias `_CircularGroup` (fallback `"{prefix}_{sym}"` with empty entry prefix), stdlib symbol shadowing (ADR 26: non-destructured imports no longer re-export transitive symbols via `local_symbols`; checker pins `resolved_c_name` on static object access), `exit_sample` used nonexistent top-level `exit` (added `fun exit` to std.core; also fixed sample's `System.print` → `print`).
- Blocking-by-design samples: `http_sample.ei` (server), `main_loop.ei` (stress loop), `hybrid_conflict.ei` (intentional error).

## Runtime representation (final)
- Every non-primitive `type` struct starts with `const EiwaTypeDescriptor* _desc`.
- Descriptor holds an impl table: `{contract_desc, vtable}` per implemented contract.
- Contract-typed values are `void*` in C; dispatch via `eiwa_find_vtable(desc, &Contract_contract)[idx]`.
- No fat-pointer struct was needed — object header + global vtables give the same semantics cheaper.

## Decisions (Socratic Gate, 2026-07-19)
- Hard break: `class`, `open`, `abstract`, `override` removed. No alias, no compat mode.
- Keyword is `implement`, NOT `override`.
- enum redesign deferred.
- Operator semantics: `:` = implements (type) / requires (skill); `+` = composes skill.
- Skill methods are cloned into consuming types and type-checked per consumer (like generics monomorphization).
- Skill conflicts: ambiguity error unless type has own method with same name; shadowed skill method cloned as `{Skill}_{method}` for qualified calls (`MouseInput.click()` rewrites to it).
- Multi-catch variables are typed as `Throwable` (dynamic dispatch); single-type catches keep the concrete type.
- Exceptions: `Throwable` contract in std.core replaces `Exception` base class.

## Key files
- Plan: `composition-type-system.md` (project root) — all tasks [x]
- ADR: `docs/decisions.md` ADR 25 (supersedes ADR 15, obsoletes Phase 33)
- Roadmap: Phase 41 COMPLETED in `docs/roadmap.md`
- Docs: Language Tour section 18 (+ sections 6/9/10.2/11/13 migrated)
- Samples: `samples/composition.ei`, `samples/composition_error.ei` (negative), `samples/tests/composition_test.ei`

