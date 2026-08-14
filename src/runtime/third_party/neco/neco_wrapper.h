// Neco (coroutines) wrappers for linking with eiwa programs.
//
// Include order: this header requires EiwaClosure to be already defined
// (eiwa_runtime.h includes it after the EiwaClosure typedef).

#ifndef EIWA_NECO_WRAPPER_H
#define EIWA_NECO_WRAPPER_H

#include <gc.h>
#include <neco.h>
#include <stdio.h>

// --- GC/neco runtime glue (implemented in neco_wrapper.c) ---
void eiwa_neco_runtime_init(void);
void eiwa_gc_fix_stackbottom(void);

// --- Neco bindings callable from Eiwa `lib Neco` ---

// Starts a neco coroutine running a `() -> Void` Eiwa closure.
// Returns the coroutine id (truncated to int), or -1 on error.
int eiwa_neco_start_closure(EiwaClosure cl);

// Blocks the current coroutine until coroutine `id` finishes.
int eiwa_neco_join(int id);

// Yields the current coroutine to the scheduler.
int eiwa_neco_yield(void);

// Waits until file descriptor `fd` is readable (NECO_WAIT_READ) or writable
// (NECO_WAIT_WRITE) without blocking the OS thread. Yields the coroutine until
// the event occurs, then resumes it. Used by I/O drivers (e.g. PostgreSQL) to
// integrate non-blocking sockets with the neco scheduler.
int eiwa_neco_wait_readable(int fd);
int eiwa_neco_wait_writable(int fd);

// Sleeps the current coroutine for nanosecs nanoseconds.
// Wraps neco_sleep + eiwa_gc_fix_stackbottom (same pattern as yield/join).
int eiwa_neco_sleep(int64_t nanosecs);

// @MainWrapper entry (Phase 65): runs the real program main inside the neco
// runtime. Implemented in neco_wrapper.c. `int64_t` argc/return match Eiwa's
// `Int`; main_fn is invoked as `int(int, char**)`.
int64_t Neco_main_wrapper(void* main_fn, int64_t argc, char** argv);

// Run the whole program inside the neco runtime: the generated `main`
// becomes the first coroutine. Without this, the first `neco_start` call
// would block until that coroutine and all of its children finish, making
// top-level tasks sequential. GC_init() must run on the real OS thread
// *before* entering the neco runtime (Boehm GC crashes if initialized on a
// coroutine stack).
//
// Phase 65: the entry wrapping is now driven by the Eiwa `@MainWrapper`
// annotation on the `lib Neco` block, which makes the backend emit a `main`
// that calls `Neco_main_wrapper` (implemented in neco_wrapper.c). The
// `#define main` preprocessor hack was removed — it only worked on the C
// backend (which runs the C preprocessor) and is replaced by the portable
// annotation.

#endif
