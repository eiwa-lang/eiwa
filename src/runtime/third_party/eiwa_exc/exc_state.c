#include "exc_state.h"
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

// Self-declared: libgc is always linked into Eiwa binaries (native + JIT).
extern void* GC_malloc(size_t size);

// Retained roots: a running task's block is referenced only from TLS
// (invisible to Boehm). Append-only: 32B per task; freeing on completion
// is unsafe (stale duplicate wakeups could UAF).
static void** live_blocks = NULL;
static size_t live_count = 0;
static size_t live_cap = 0;

static void retain_block(void* blk) {
    if (live_count == live_cap) {
        size_t ncap = live_cap == 0 ? 64 : live_cap * 2;
        // GC-managed (scanned): the registry itself must stay visible so
        // every block it points at is retained. Plain malloc would hide
        // the pointers from the collector.
        void** nblk = (void**)GC_malloc(ncap * sizeof(void*));
        if (nblk == NULL) {
            return;
        }
        if (live_blocks != NULL) {
            memcpy(nblk, live_blocks, live_count * sizeof(void*));
        }
        live_blocks = nblk;
        live_cap = ncap;
    }
    live_blocks[live_count++] = blk;
}

#ifndef _WIN32

#include <pthread.h>

static pthread_key_t tls_key;
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;

static void tls_make_key(void) {
    pthread_key_create(&tls_key, NULL);
}

// 3-word block: [0] stack top, [1] active data, [2] active vtable.
static void** cur_block(void) {
    pthread_once(&tls_once, tls_make_key);
    void* p = pthread_getspecific(tls_key);
    if (p == NULL) {
        p = GC_malloc(3 * sizeof(void*));
        if (p == NULL) {
            return NULL;
        }
        memset(p, 0, 3 * sizeof(void*));
        retain_block(p);
        pthread_setspecific(tls_key, p);
    }
    return (void**)p;
}

void* eiwa_exc_current_get(void) {
    pthread_once(&tls_once, tls_make_key);
    return pthread_getspecific(tls_key);
}

void eiwa_exc_current_set(void* st) {
    pthread_once(&tls_once, tls_make_key);
    pthread_setspecific(tls_key, st);
}

#else

#include <windows.h>

static DWORD tls_idx = TLS_OUT_OF_INDEXES;
static INIT_ONCE tls_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK tls_make_key(PINIT_ONCE once, PVOID param, PVOID* ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    tls_idx = FlsAlloc(NULL);
    return TRUE;
}

static void** cur_block(void) {
    InitOnceExecuteOnce(&tls_once, tls_make_key, NULL, NULL);
    void* p = FlsGetValue(tls_idx);
    if (p == NULL) {
        p = GC_malloc(3 * sizeof(void*));
        if (p == NULL) {
            return NULL;
        }
        memset(p, 0, 3 * sizeof(void*));
        retain_block(p);
        FlsSetValue(tls_idx, p);
    }
    return (void**)p;
}

void* eiwa_exc_current_get(void) {
    InitOnceExecuteOnce(&tls_once, tls_make_key, NULL, NULL);
    return FlsGetValue(tls_idx);
}

void eiwa_exc_current_set(void* st) {
    InitOnceExecuteOnce(&tls_once, tls_make_key, NULL, NULL);
    FlsSetValue(tls_idx, st);
}

#endif

void* eiwa_exc_top_get(void) {
    return cur_block()[0];
}

void eiwa_exc_top_set(void* p) {
    cur_block()[0] = p;
}

void* eiwa_exc_active_data_get(void) {
    return cur_block()[1];
}

void eiwa_exc_active_data_set(void* p) {
    cur_block()[1] = p;
}

void* eiwa_exc_active_table_get(void) {
    return cur_block()[2];
}

void eiwa_exc_active_table_set(void* p) {
    cur_block()[2] = p;
}
