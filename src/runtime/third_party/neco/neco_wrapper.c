// Neco (coroutines) wrappers for linking with eiwa programs.

#include "eiwa_runtime.h"
#include "neco_wrapper.h"

// ---------------------------------------------------------------------------
// Boehm GC <-> neco coroutine integration
//
// Eiwa code runs on neco coroutine stacks (malloc'd through neco's env
// allocator, see NECO_USEHEAPSTACK). Boehm GC scans a thread stack from the
// current SP up to a fixed stackbottom; scanning from a coroutine SP to the
// OS main stack bottom crosses unmapped memory and segfaults. To keep
// collections safe and correct we:
//
//   1. Track every coroutine stack (allocated via neco's env allocator).
//   2. Register each stack as a GC root region, so the stacks of *suspended*
//      coroutines are scanned and keep the objects they reference alive.
//   3. Re-point the GC stackbottom to the top of the *current* coroutine
//      stack at every coroutine entry and right after every neco call that
//      may have switched coroutines, so the automatic [SP, stackbottom]
//      scan always stays inside mapped memory.
// ---------------------------------------------------------------------------

#define EIWA_MAX_TRACKED_STACKS 1024
#define EIWA_MIN_STACK_ALLOC 65536 // allocs >= this are treated as stacks

typedef struct {
    void *base;
    size_t size;
} EiwaStackRange;

static EiwaStackRange eiwa_stacks[EIWA_MAX_TRACKED_STACKS];
static int eiwa_stacks_len = 0;

static void eiwa_track_stack(void *base, size_t size) {
    if (eiwa_stacks_len >= EIWA_MAX_TRACKED_STACKS) {
        return;
    }
    eiwa_stacks[eiwa_stacks_len].base = base;
    eiwa_stacks[eiwa_stacks_len].size = size;
    eiwa_stacks_len++;
    GC_add_roots(base, (char *)base + size);
}

static void eiwa_untrack_stack(void *base) {
    for (int i = 0; i < eiwa_stacks_len; i++) {
        if (eiwa_stacks[i].base == base) {
            GC_remove_roots(base, (char *)base + eiwa_stacks[i].size);
            eiwa_stacks[i] = eiwa_stacks[--eiwa_stacks_len];
            return;
        }
    }
}

static void *eiwa_neco_malloc(size_t size) {
    void *ptr = malloc(size);
    if (ptr && size >= EIWA_MIN_STACK_ALLOC) {
        eiwa_track_stack(ptr, size);
    }
    return ptr;
}

static void *eiwa_neco_realloc(void *ptr, size_t size) {
    return realloc(ptr, size);
}

static void eiwa_neco_free(void *ptr) {
    if (ptr) {
        eiwa_untrack_stack(ptr);
    }
    free(ptr);
}

void eiwa_neco_runtime_init(void) {
    neco_env_setallocator(eiwa_neco_malloc, eiwa_neco_realloc, eiwa_neco_free);
}

void eiwa_gc_fix_stackbottom(void) {
    volatile int anchor;
    char *sp = (char *)&anchor;
    for (int i = 0; i < eiwa_stacks_len; i++) {
        char *base = (char *)eiwa_stacks[i].base;
        if (sp >= base && sp < base + eiwa_stacks[i].size) {
            struct GC_stack_base sb;
            sb.mem_base = base + eiwa_stacks[i].size;
            GC_set_stackbottom(NULL, &sb);
            return;
        }
    }
}

// Trampoline with the neco coroutine signature that invokes a `() -> Void`
// Eiwa closure. argv[0] is a heap-allocated EiwaClosure*.
static void eiwa_neco_closure_trampoline(int argc, void *argv[]) {
    (void)argc;
    eiwa_gc_fix_stackbottom();
    EiwaClosure *cl = (EiwaClosure *)argv[0];
    ((void (*)(void *))cl->fn_ptr)(cl->env);
}

int eiwa_neco_start_closure(EiwaClosure cl) {
    EiwaClosure *heap_cl = GC_MALLOC(sizeof(EiwaClosure));
    *heap_cl = cl;
    int ret = neco_start(eiwa_neco_closure_trampoline, 1, heap_cl);
    if (ret != NECO_OK) {
        eiwa_gc_fix_stackbottom();
        return -1;
    }
    int id = (int)neco_lastid();
    // Give the new coroutine a chance to start running right away
    // (Kotlin-style: `task {}` starts immediately, `await()` only blocks
    // until the result is ready).
    neco_yield();
    eiwa_gc_fix_stackbottom();
    return id;
}

int eiwa_neco_join(int id) {
    int ret = neco_join((int64_t)id);
    eiwa_gc_fix_stackbottom();
    return ret;
}

int eiwa_neco_yield(void) {
    int ret = neco_yield();
    eiwa_gc_fix_stackbottom();
    return ret;
}
