/* Fatal-signal handler for native binaries. Signal-safe only. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dbghelp.h>
#include <string.h>
#include <stdlib.h>

static void eiwa_write_raw(const void *buf, size_t n) {
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), buf, (DWORD)n, &written, NULL);
}
#else

#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <execinfo.h>
#include <dlfcn.h>

static void eiwa_write_raw(const void *buf, size_t n) {
    write(STDERR_FILENO, buf, n);
}
#endif

#define EIWA_MSG(s) eiwa_write_raw(s, sizeof(s) - 1)
#define EIWA_NULL_HINT ": attempted to access a member or method on a null reference"
#define EIWA_HELP " check `!!` and native pointers near the crash; safe-only code (?., ?:, try) crashing is a compiler bug: https://github.com/eiwa-lang/eiwa/issues\n"
#define EIWA_OMITTED_TAIL " frames omitted (EIWA_FULL_TRACE=1 for full trace) ...\n"

static int eiwa_full_trace(void) {
    const char *v = getenv("EIWA_FULL_TRACE");
    return v != NULL && v[0] != 0 && strcmp(v, "0") != 0;
}

static void eiwa_write_hex(uintptr_t v) {
    char buf[18];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        unsigned d = (unsigned)((v >> (60 - 4 * i)) & 0xF);
        buf[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    int start = 2;
    while (start < 17 && buf[start] == '0') start++;
    eiwa_write_raw(buf, 2);
    eiwa_write_raw(buf + start, 18 - start);
}

static void eiwa_write_ulong(unsigned long v) {
    char buf[24];
    int n = 0;
    if (v == 0) {
        eiwa_write_raw("0", 1);
        return;
    }
    while (v > 0 && n < 24) {
        buf[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    for (int i = n - 1; i >= 0; i--) eiwa_write_raw(buf + i, 1);
}

static void eiwa_write_str(const char *s) {
    eiwa_write_raw(s, strlen(s));
}

#ifdef _WIN32

static const char *eiwa_seh_name(DWORD code) {
    switch (code) {
        case EXCEPTION_ACCESS_VIOLATION: return "EXCEPTION_ACCESS_VIOLATION";
        case EXCEPTION_STACK_OVERFLOW: return "EXCEPTION_STACK_OVERFLOW";
        case EXCEPTION_ILLEGAL_INSTRUCTION: return "EXCEPTION_ILLEGAL_INSTRUCTION";
        case EXCEPTION_INT_DIVIDE_BY_ZERO: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
        default: return "exception";
    }
}

static LONG WINAPI eiwa_vectored_handler(EXCEPTION_POINTERS *info) {
    DWORD code = info->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_STACK_OVERFLOW &&
        code != EXCEPTION_ILLEGAL_INSTRUCTION && code != EXCEPTION_INT_DIVIDE_BY_ZERO)
        return EXCEPTION_CONTINUE_SEARCH;
    void *fault = NULL;
    if (code == EXCEPTION_ACCESS_VIOLATION && info->ExceptionRecord->NumberParameters >= 2)
        fault = (void *)info->ExceptionRecord->ExceptionInformation[1];
#if defined(_M_X64) || defined(__x86_64__)
    void *pc = (void *)(uintptr_t)info->ContextRecord->Rip;
#elif defined(_M_IX86) || defined(__i386__)
    void *pc = (void *)(uintptr_t)info->ContextRecord->Eip;
#elif defined(_M_ARM64) || defined(__aarch64__)
    void *pc = (void *)(uintptr_t)info->ContextRecord->Pc;
#else
    void *pc = NULL;
#endif
    EIWA_MSG("\nerror: runtime crash (");
    eiwa_write_str(eiwa_seh_name(code));
    EIWA_MSG(")");
    if (code == EXCEPTION_ACCESS_VIOLATION && (fault == NULL || (uintptr_t)fault < 4096))
        EIWA_MSG(EIWA_NULL_HINT);
    EIWA_MSG("\n  --> fault address: ");
    eiwa_write_hex((uintptr_t)fault);
    EIWA_MSG("\n  = help:");
    EIWA_MSG(EIWA_HELP);
    EIWA_MSG("Stack trace (native):\n");
    EIWA_MSG("  0: ");
    eiwa_write_hex((uintptr_t)pc);
    EIWA_MSG("\n");
    void *frames[64];
    int n = (int)CaptureStackBackTrace(1, 64, frames, NULL);
    int cut = -1;
    int resume = -1;
    if (!eiwa_full_trace() && n > 10) {
        cut = 6;
        resume = n - 4;
    }
    for (int i = 0; i < n; i++) {
        if (i == cut) {
            EIWA_MSG("  ... ");
            eiwa_write_ulong((unsigned long)(resume - cut));
            EIWA_MSG(EIWA_OMITTED_TAIL);
            i = resume - 1;
            continue;
        }
        EIWA_MSG("  ");
        eiwa_write_ulong((unsigned long)(i + 1));
        EIWA_MSG(": ");
        eiwa_write_hex((uintptr_t)frames[i]);
        EIWA_MSG("\n");
    }
    EIWA_MSG("\n");
    return EXCEPTION_CONTINUE_SEARCH;
}

void eiwa_install_crash_handler(void) {
    AddVectoredExceptionHandler(1, eiwa_vectored_handler);
}

#else

static const char *eiwa_sig_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGILL: return "SIGILL";
        case SIGBUS: return "SIGBUS";
        case SIGFPE: return "SIGFPE";
        case SIGABRT: return "SIGABRT";
        default: return "signal";
    }
}

extern const char eiwa_symbol_table[];
extern const char eiwa_symbol_table_deps[];

static int eiwa_streq(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

static const char *eiwa_lookup_in(const char *table, const char *name) {
    size_t n = strlen(name);
    const char *p = table;
    for (int guard = 0; guard < 1000000 && *p; guard++) {
        size_t i = 0;
        while (i < n && p[i] == name[i]) i++;
        if (i == n && p[n] == ' ') return p + n + 1;
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    return NULL;
}

static const char *eiwa_lookup_symbol(const char *name) {
    const char *r = eiwa_lookup_in(eiwa_symbol_table, name);
    if (r != NULL) return r;
    return eiwa_lookup_in(eiwa_symbol_table_deps, name);
}

static void eiwa_write_pretty(const char *pretty) {
    size_t n = 0;
    while (n < 256 && pretty[n] && pretty[n] != '\n') n++;
    eiwa_write_raw(pretty, n);
}

static int eiwa_is_trampoline(const char *s) {
    return eiwa_streq(s, "_sigtramp") || eiwa_streq(s, "__restore_rt") || eiwa_streq(s, "__restore");
}

static int eiwa_is_thread_root(const char *s) {
    return eiwa_streq(s, "thread_start") || eiwa_streq(s, "start") ||
        eiwa_streq(s, "__libc_start_main") || eiwa_streq(s, "__libc_start_call_main") ||
        eiwa_streq(s, "clone") || eiwa_streq(s, "__clone");
}

static void eiwa_crash_handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    int colors = getenv("NO_COLOR") == NULL && isatty(STDERR_FILENO) != 0;
    const char *term = getenv("TERM");
    if (term != NULL && strcmp(term, "dumb") == 0) colors = 0;
    const char *red = colors ? "\x1b[1;31m" : "";
    const char *cyan = colors ? "\x1b[36m" : "";
    const char *bold = colors ? "\x1b[1m" : "";
    const char *green = colors ? "\x1b[1;32m" : "";
    const char *rst = colors ? "\x1b[0m" : "";
    void *fault = info != NULL ? info->si_addr : NULL;

    EIWA_MSG("\n");
    eiwa_write_str(red);
    EIWA_MSG("error");
    eiwa_write_str(rst);
    EIWA_MSG(": runtime crash (");
    eiwa_write_str(eiwa_sig_name(sig));
    EIWA_MSG(")");
    eiwa_write_str(bold);
    if (sig == SIGSEGV && (fault == NULL || (uintptr_t)fault < 4096))
        EIWA_MSG(EIWA_NULL_HINT);
    eiwa_write_str(rst);
    EIWA_MSG("\n  ");
    eiwa_write_str(cyan);
    EIWA_MSG("-->");
    eiwa_write_str(rst);
    EIWA_MSG(" fault address: ");
    eiwa_write_hex((uintptr_t)fault);
    EIWA_MSG("\n  ");
    eiwa_write_str(cyan);
    EIWA_MSG("=");
    eiwa_write_str(rst);
    EIWA_MSG(" ");
    eiwa_write_str(green);
    EIWA_MSG("help:");
    eiwa_write_str(rst);
    EIWA_MSG(EIWA_HELP);

    EIWA_MSG("Stack trace (native):\n");
    void *frames[64];
    int depth = backtrace(frames, 64);
    const char *names[64];
    for (int i = 0; i < depth; i++) {
        Dl_info dli;
        names[i] = (dladdr(frames[i], &dli) != 0) ? dli.dli_sname : NULL;
    }
    int lo = 0;
    while (lo < depth && names[lo] != NULL &&
        (eiwa_streq(names[lo], "eiwa_crash_handler") || eiwa_is_trampoline(names[lo]))) lo++;
    int hi = depth;
    while (hi - 1 > lo && names[hi - 1] != NULL && eiwa_is_thread_root(names[hi - 1])) hi--;
    int full = eiwa_full_trace();
    int cut = -1;
    int resume = -1;
    if (!full && hi - lo > 10) {
        cut = lo + 6;
        resume = hi - 4;
    }
    for (int i = lo; i < hi; i++) {
        if (i == cut) {
            EIWA_MSG("  ... ");
            eiwa_write_ulong((unsigned long)(resume - cut));
            EIWA_MSG(EIWA_OMITTED_TAIL);
            i = resume - 1;
            continue;
        }
        EIWA_MSG("  ");
        eiwa_write_ulong((unsigned long)i);
        EIWA_MSG(": ");
        eiwa_write_hex((uintptr_t)frames[i]);
        if (names[i] != NULL) {
            const char *pretty = eiwa_lookup_symbol(names[i]);
            EIWA_MSG(" in ");
            if (pretty != NULL) eiwa_write_pretty(pretty);
            else eiwa_write_str(names[i]);
        }
        EIWA_MSG("\n");
    }
    EIWA_MSG("\n");

    /* Re-raise with default disposition: keeps 128+signo exit status + core dumps. */
    signal(sig, SIG_DFL);
    raise(sig);
}

void eiwa_install_crash_handler(void) {
    struct sigaction act;
    memset(&act, 0, sizeof(act));
    act.sa_sigaction = eiwa_crash_handler;
    sigemptyset(&act.sa_mask);
    act.sa_flags = SA_SIGINFO | SA_RESTART | SA_RESETHAND | SA_ONSTACK;
    sigaction(SIGSEGV, &act, NULL);
    sigaction(SIGILL, &act, NULL);
    sigaction(SIGBUS, &act, NULL);
    sigaction(SIGFPE, &act, NULL);
    sigaction(SIGABRT, &act, NULL);
}

#endif /* _WIN32 */
