#ifndef EIWA_ENV_HELPERS_H
#define EIWA_ENV_HELPERS_H

#include <stdint.h>

char* eiwa_getenv(const char* name);
int64_t eiwa_setenv(const char* name, const char* value, int64_t overwrite);
int64_t eiwa_unsetenv(const char* name);

#endif // EIWA_ENV_HELPERS_H
