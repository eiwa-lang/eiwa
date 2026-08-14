// C helpers used by samples/tests/ffi_varargs_test.ei to exercise the
// variadic FFI (`T...` in lib blocks, Phase 66). Compiled via @Source so the
// LLVM backend can resolve the externs, and declared in varargs_helpers.h so
// the C backend sees the `...` prototypes.
#include <stdarg.h>

int eiwa_va_sum(int count, ...) {
    va_list ap;
    va_start(ap, count);
    int total = 0;
    for (int i = 0; i < count; i++) {
        total += va_arg(ap, int);
    }
    va_end(ap);
    return total;
}

int eiwa_va_count(int count, ...) {
    (void)count;
    va_list ap;
    va_start(ap, count);
    int n = 0;
    while (va_arg(ap, int) != -1) {
        n++;
    }
    va_end(ap);
    return n;
}
