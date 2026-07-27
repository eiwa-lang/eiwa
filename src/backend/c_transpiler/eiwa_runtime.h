#ifndef EIWA_RUNTIME_H
#define EIWA_RUNTIME_H

#include <stdint.h>
#include <time.h>
#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

static inline int eiwa_char_at(const char* str, int index) {
    return str[index];
}

static inline void eiwa_terminate(char *str, int index) {
    str[index] = '\0';
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
extern const EiwaTypeDescriptor core_Bool_descriptor;
extern const EiwaTypeDescriptor core_String_descriptor;

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

// POSIX Net Helpers
static inline int eiwa_tcp_bind(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 10) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static inline int eiwa_tcp_accept(int fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    return accept(fd, (struct sockaddr*)&addr, &addr_len);
}

static inline int eiwa_socket_read(int fd, char* buf, int max_len) {
    return read(fd, buf, max_len);
}

static inline int eiwa_socket_write(int fd, const char* data, int len) {
    return write(fd, data, len);
}

static inline int eiwa_tcp_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static inline void eiwa_socket_close(int fd) {
    close(fd);
}

// Curl Helpers
#ifdef EIWA_USE_CURL
#include <curl/curl.h>

struct EiwaCurlBuffer {
    char* data;
    size_t size;
};

static inline size_t eiwa_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t realsize = size * nmemb;
    struct EiwaCurlBuffer* mem = (struct EiwaCurlBuffer*)userp;
    char* ptr = GC_REALLOC(mem->data, mem->size + realsize + 1);
    if(!ptr) return 0;
    mem->data = ptr;
    memcpy(&(mem->data[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->data[mem->size] = 0;
    return realsize;
}

static inline void* eiwa_get_write_callback_ptr() {
    return (void*)eiwa_curl_write_callback;
}

static inline char* eiwa_curl_buf_data(void* buf) {
    return ((struct EiwaCurlBuffer*)buf)->data;
}

static inline int eiwa_curl_buf_size(void* buf) {
    return (int)((struct EiwaCurlBuffer*)buf)->size;
}

static inline int eiwa_curl_get_status(CURL* curl) {
    long response_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    return (int)response_code;
}

static inline int eiwa_curl_setopt_string(CURL* curl, CURLoption option, const void* value) {
    return curl_easy_setopt(curl, option, value);
}

static inline int eiwa_curl_setopt_ptr(CURL* curl, CURLoption option, void* value) {
    return curl_easy_setopt(curl, option, value);
}

static inline int eiwa_curl_setopt_int(CURL* curl, CURLoption option, int value) {
    return curl_easy_setopt(curl, option, (long)value);
}
#endif

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
core_String* core_Int_toString(int val);
int core_Bool_hashCode(bool val);
int core_Int_hashCode(int val);

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
    if (val < 0x10000) return core_Int_toString((int)val);
    const EiwaTypeDescriptor* desc = *(const EiwaTypeDescriptor**)ptr;
    if (desc == &core_String_descriptor) return (core_String*)ptr;
    return ((core_String*(*)(void*))eiwa_find_vtable(desc, &core_Stringable_contract)[0])(ptr);

}

static inline int eiwa_hash_code(void* ptr) {
    if (!ptr) return 0;
    uintptr_t val = (uintptr_t)ptr;
    if (val <= 1) return core_Bool_hashCode((bool)val);
    if (val < 0x10000) return core_Int_hashCode((int)val);
    return ((int(*)(void*))eiwa_find_vtable(*(const EiwaTypeDescriptor**)ptr, &core_Hashable_contract)[0])(ptr);
}

#endif // EIWA_RUNTIME_H
