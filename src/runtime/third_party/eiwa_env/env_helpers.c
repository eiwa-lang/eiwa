#include "env_helpers.h"
#include <stdlib.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

char* eiwa_getenv(const char* name) {
    return getenv(name);
}

int64_t eiwa_setenv(const char* name, const char* value, int64_t overwrite) {
    if (!overwrite && getenv(name) != NULL) return 0;
    SetEnvironmentVariableA(name, value);
    return _putenv_s(name, value) == 0 ? 0 : -1;
}

int64_t eiwa_unsetenv(const char* name) {
    SetEnvironmentVariableA(name, NULL);
    return _putenv_s(name, "") == 0 ? 0 : -1;
}

#else

char* eiwa_getenv(const char* name) {
    return getenv(name);
}

int64_t eiwa_setenv(const char* name, const char* value, int64_t overwrite) {
    return setenv(name, value, (int)overwrite);
}

int64_t eiwa_unsetenv(const char* name) {
    return unsetenv(name);
}

#endif
