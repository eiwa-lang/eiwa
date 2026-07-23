#include "fiber.h"
#include <ucontext.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define FIBER_STACK_SIZE (64 * 1024)

static __thread EiwaFiber* current_fiber = NULL;
static __thread EiwaFiber* ready_head = NULL;
static __thread EiwaFiber* ready_tail = NULL;
static __thread EiwaFiber main_fiber_storage;
static __thread bool scheduler_initialized = false;

static void enqueue(EiwaFiber* fiber) {
    fiber->next = NULL;
    if (ready_tail) {
        ready_tail->next = fiber;
        ready_tail = fiber;
    } else {
        ready_head = fiber;
        ready_tail = fiber;
    }
}

static EiwaFiber* dequeue(void) {
    if (!ready_head) return NULL;
    EiwaFiber* fiber = ready_head;
    ready_head = fiber->next;
    if (!ready_head) ready_tail = NULL;
    fiber->next = NULL;
    return fiber;
}

static void fiber_entry(int lo, int hi) {
    EiwaFiber* fiber = (EiwaFiber*)((uintptr_t)(uint32_t)hi << 32 | (uint32_t)lo);
    fiber->func(fiber->arg);
    fiber->finished = true;
    eiwa_fiber_yield();
}

void eiwa_fiber_init(void) {
    if (scheduler_initialized) return;
    scheduler_initialized = true;
    memset(&main_fiber_storage, 0, sizeof(main_fiber_storage));
    current_fiber = &main_fiber_storage;
}

EiwaFiber* eiwa_fiber_create(EiwaFiberFunc func, void* arg) {
    if (!scheduler_initialized) eiwa_fiber_init();

    EiwaFiber* fiber = (EiwaFiber*)malloc(sizeof(EiwaFiber));
    memset(fiber, 0, sizeof(EiwaFiber));

    fiber->stack = malloc(FIBER_STACK_SIZE);
    memset(fiber->stack, 0, FIBER_STACK_SIZE);

    fiber->func = func;
    fiber->arg = arg;
    fiber->finished = false;

    getcontext(&fiber->context);
    fiber->context.uc_stack.ss_sp = fiber->stack;
    fiber->context.uc_stack.ss_size = FIBER_STACK_SIZE;
    fiber->context.uc_link = NULL;

    uintptr_t ptr = (uintptr_t)fiber;
    int lo = (int)(uint32_t)ptr;
    int hi = (int)(uint32_t)(ptr >> 32);
    makecontext(&fiber->context, (void (*)(void))fiber_entry, 2, lo, hi);

    enqueue(fiber);
    return fiber;
}

void eiwa_fiber_yield(void) {
    EiwaFiber* prev = current_fiber;

    if (prev->finished) {
        if (prev->calling_fiber) {
            current_fiber = prev->calling_fiber;
            prev->calling_fiber = NULL;
            swapcontext(&prev->context, &current_fiber->context);
        }
        return;
    }

    enqueue(prev);

    EiwaFiber* next = dequeue();
    if (next && next != prev) {
        current_fiber = next;
        swapcontext(&prev->context, &next->context);
    }
}

EiwaFiber* eiwa_fiber_current(void) {
    return current_fiber;
}

void eiwa_fiber_resume(EiwaFiber* fiber) {
    if (!fiber || fiber->finished) return;
    EiwaFiber* prev = current_fiber;
    current_fiber = fiber;
    fiber->calling_fiber = prev;
    swapcontext(&prev->context, &fiber->context);
}

bool eiwa_fiber_done(EiwaFiber* fiber) {
    return fiber ? fiber->finished : true;
}

void eiwa_task_init(EiwaTask* task, EiwaFiberFunc func, void* context, size_t result_size) {
    task->context = context;
    task->done = 0;
    task->result_ptr = malloc(result_size);
    memset(task->result_ptr, 0, result_size);
    task->fiber = eiwa_fiber_create(func, task);
}
