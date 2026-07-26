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

// Sleeps the current coroutine for nanosecs nanoseconds.
// Wraps neco_sleep + eiwa_gc_fix_stackbottom (same pattern as yield/join).
int eiwa_neco_sleep(int64_t nanosecs);

// Run the whole program inside the neco runtime: the generated `main`
// becomes the first coroutine. Without this, the first `neco_start` call
// would block until that coroutine and all of its children finish, making
// top-level tasks sequential. GC_init() must run on the real OS thread
// *before* entering the neco runtime (Boehm GC crashes if initialized on a
// coroutine stack).
#define main \
__eiwa_main(int argc, char *argv[]); \
static int __eiwa_main_ret; \
static void _eiwa_main_co(int _co_argc, void *_co_argv[]) { \
    (void)_co_argc; \
    eiwa_gc_fix_stackbottom(); \
    __eiwa_main_ret = __eiwa_main(*(int *)_co_argv[0], *(char ***)_co_argv[1]); \
} \
int main(int argc, char *argv[]) { \
    GC_init(); \
    eiwa_neco_runtime_init(); \
    int _neco_ret = neco_start(_eiwa_main_co, 2, &argc, &argv); \
    if (_neco_ret != NECO_OK) { \
        fprintf(stderr, "neco_start: %s (code %d)\n", neco_strerror(_neco_ret), _neco_ret); \
        return 1; \
    } \
    return __eiwa_main_ret; \
} \
int __eiwa_main

#endif
