#ifndef EIWA_FIBER_H
#define EIWA_FIBER_H

#define _XOPEN_SOURCE 600
#include <ucontext.h>
#include <stdbool.h>
#include <stddef.h>

typedef void (*EiwaFiberFunc)(void*);

typedef struct EiwaFiber {
    ucontext_t context;
    void* stack;
    bool finished;
    EiwaFiberFunc func;
    void* arg;
    struct EiwaFiber* next;
    struct EiwaFiber* calling_fiber;
} EiwaFiber;

typedef struct {
    EiwaFiber* fiber;
    void* context;
    volatile int done;
    void* result_ptr;
} EiwaTask;

EiwaFiber* eiwa_fiber_create(EiwaFiberFunc func, void* arg);
void eiwa_fiber_yield(void);
EiwaFiber* eiwa_fiber_current(void);
void eiwa_fiber_resume(EiwaFiber* fiber);
bool eiwa_fiber_done(EiwaFiber* fiber);
void eiwa_fiber_init(void);
void eiwa_task_init(EiwaTask* task, EiwaFiberFunc func, void* context, size_t result_size);

#endif
