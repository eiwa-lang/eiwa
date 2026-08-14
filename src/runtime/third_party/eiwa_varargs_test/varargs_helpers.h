#ifndef EIWA_VARARGS_TEST_HELPERS_H
#define EIWA_VARARGS_TEST_HELPERS_H

#include <stdarg.h>

// Sums `count` int varargs.
int eiwa_va_sum(int count, ...);

// Returns the number of varargs actually passed.
int eiwa_va_count(int count, ...);

#endif // EIWA_VARARGS_TEST_HELPERS_H
