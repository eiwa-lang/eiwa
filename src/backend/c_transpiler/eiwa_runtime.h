#ifndef EIWA_RUNTIME_H
#define EIWA_RUNTIME_H

#include <stdint.h>
#include <time.h>
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

static inline int eiwa_char_at(const void* str, int index) {
    return ((const uint8_t*)str)[index];
}

static inline void eiwa_write_byte(void* str, int index, int value) {
    ((uint8_t*)str)[index] = (uint8_t)value;
}

static inline void eiwa_random_bytes(void* buf, int len) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    arc4random_buf(buf, len);
#else
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) {
        size_t r = fread(buf, 1, len, f);
        (void)r;
        fclose(f);
    } else {
        uint8_t* p = (uint8_t*)buf;
        for (int i = 0; i < len; i++) p[i] = (uint8_t)(rand() & 0xFF);
    }
#endif
}

static inline int64_t eiwa_now_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

typedef struct EiwaContractDescriptor {
    const char* name;
} EiwaContractDescriptor;

typedef struct EiwaContractImpl {
    const EiwaContractDescriptor* contract;
    void** vtable;
} EiwaContractImpl;

typedef struct EiwaTypeDescriptor {
    const char* name;
    const EiwaContractImpl* impls;
    int impl_count;
} EiwaTypeDescriptor;

extern const EiwaTypeDescriptor core_Int_descriptor;
extern const EiwaTypeDescriptor core_Double_descriptor;
extern const EiwaTypeDescriptor core_Bool_descriptor;
extern const EiwaTypeDescriptor core_String_descriptor;

static inline int64_t eiwa_double_to_int(double val) {
    return (int64_t)val;
}

static inline double eiwa_int_to_double(int64_t val) {
    return (double)val;
}

static inline bool eiwa_implements(const EiwaTypeDescriptor* desc, const EiwaContractDescriptor* target) {
    if (!desc || !target) return false;
    for (int i = 0; i < desc->impl_count; i++) {
        if (desc->impls[i].contract == target) return true;
    }
    return false;
}

static inline void** eiwa_find_vtable(const EiwaTypeDescriptor* desc, const EiwaContractDescriptor* target) {
    if (!desc || !target) return 0;
    for (int i = 0; i < desc->impl_count; i++) {
        if (desc->impls[i].contract == target) return desc->impls[i].vtable;
    }
    return 0;
}

#include <setjmp.h>

typedef struct EiwaExceptionFrame {
    jmp_buf buf;
    struct EiwaExceptionFrame* next;
} EiwaExceptionFrame;

extern __thread EiwaExceptionFrame* eiwa_exception_stack;
extern __thread void* eiwa_active_exception;

static inline void eiwa_push_exception_frame(EiwaExceptionFrame* frame) {
    frame->next = eiwa_exception_stack;
    eiwa_exception_stack = frame;
}

static inline void eiwa_pop_exception_frame() {
    if (eiwa_exception_stack) {
        eiwa_exception_stack = eiwa_exception_stack->next;
    }
}

static inline void eiwa_throw(void* exception) {
    if (!eiwa_exception_stack) {
        const char* name = "UnknownException";
        if (exception) {
            const EiwaTypeDescriptor* desc = *(const EiwaTypeDescriptor**)exception;
            if (desc) name = desc->name;
        }
        fprintf(stderr, "Unhandled exception: %s occurred!\n", name);
        exit(1);
    }
    eiwa_active_exception = exception;
    longjmp(eiwa_exception_stack->buf, 1);
}

typedef struct EiwaClosure {
    void* fn_ptr;
    void* env;
    void* _pad;
} EiwaClosure;

#include "neco/neco_wrapper.h"

struct core_String;
typedef struct core_String core_String;
extern const EiwaContractDescriptor core_Stringable_contract;
extern const EiwaContractDescriptor core_Hashable_contract;
core_String* core_Bool_toString(bool val);
core_String* core_Int_toString(int64_t val);
int64_t core_Bool_hashCode(bool val);
int64_t core_Int_hashCode(int64_t val);

static inline core_String* eiwa_to_string(void* ptr) {
    if (!ptr) {
        typedef struct { const void* _desc; const char* ptr; int length; } Str;
        Str* s = (Str*)GC_MALLOC(sizeof(Str));
        s->_desc = NULL;
        s->ptr = "null";
        s->length = 4;
        return (core_String*)s;
    }
    uintptr_t val = (uintptr_t)ptr;
    if (val <= 1) return core_Bool_toString((bool)val);
    if (val < 0x10000) return core_Int_toString((int64_t)val);
    const EiwaTypeDescriptor* desc = *(const EiwaTypeDescriptor**)ptr;
    if (desc == &core_String_descriptor) return (core_String*)ptr;
    return ((core_String*(*)(void*))eiwa_find_vtable(desc, &core_Stringable_contract)[0])(ptr);
}

static inline int64_t eiwa_hash_code(void* ptr) {
    if (!ptr) return 0;
    uintptr_t val = (uintptr_t)ptr;
    if (val <= 1) return core_Bool_hashCode((bool)val);
    if (val < 0x10000) return core_Int_hashCode((int64_t)val);
    return ((int64_t(*)(void*))eiwa_find_vtable(*(const EiwaTypeDescriptor**)ptr, &core_Hashable_contract)[0])(ptr);
}

#endif // EIWA_RUNTIME_H
