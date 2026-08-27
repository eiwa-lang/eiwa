// C helper for samples/tests/c_function_ptr_test.ei, exercising a C function
// pointer obtained via `cFunctionPtr(fn)`.
#include "cb_helpers.h"

int eiwa_apply_cb(int (*cb)(int), int x) {
    return cb(x);
}
