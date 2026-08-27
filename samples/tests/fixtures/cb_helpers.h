#ifndef EIWA_CB_TEST_HELPERS_H
#define EIWA_CB_TEST_HELPERS_H

// Applies `cb` to `x` — exercises a C function pointer obtained via
// `cFunctionPtr(fn)` (Phase 66/65.9).
int eiwa_apply_cb(int (*cb)(int), int x);

#endif // EIWA_CB_TEST_HELPERS_H
