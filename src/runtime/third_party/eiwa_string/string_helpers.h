#ifndef EIWA_STRING_HELPERS_H
#define EIWA_STRING_HELPERS_H

#include <stdint.h>

// Widening wrapper over libc `strcmp` (returns C `int`): Eiwa `Int` is
// 64-bit, so calling `strcmp` directly would declare one symbol with two
// conflicting LLVM types depending on who declares first.
int64_t eiwa_strcmp(const char* a, const char* b);

#endif // EIWA_STRING_HELPERS_H
