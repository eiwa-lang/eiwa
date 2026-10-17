#include "dir_helpers.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <direct.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    HANDLE handle;
    WIN32_FIND_DATAA data;
    int first;
    int done;
} EiwaDir;

void* eiwa_opendir(const char* path) {
    size_t len = strlen(path);
    char* pattern = (char*)malloc(len + 3);
    if (!pattern) return NULL;
    memcpy(pattern, path, len);
    pattern[len] = '\\';
    pattern[len + 1] = '*';
    pattern[len + 2] = '\0';
    EiwaDir* dir = (EiwaDir*)malloc(sizeof(EiwaDir));
    if (!dir) {
        free(pattern);
        return NULL;
    }
    dir->handle = FindFirstFileA(pattern, &dir->data);
    free(pattern);
    if (dir->handle == INVALID_HANDLE_VALUE) {
        free(dir);
        return NULL;
    }
    dir->first = 1;
    dir->done = 0;
    return (void*)dir;
}

static int is_dot_entry(const char* name) {
    return name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}

const char* eiwa_readdir_name(void* dir) {
    EiwaDir* d = (EiwaDir*)dir;
    if (!d || d->done) return NULL;
    for (;;) {
        if (d->first) {
            d->first = 0;
        } else if (!FindNextFileA(d->handle, &d->data)) {
            d->done = 1;
            return NULL;
        }
        if (!is_dot_entry(d->data.cFileName)) {
            return d->data.cFileName;
        }
    }
}

int eiwa_closedir(void* dir) {
    EiwaDir* d = (EiwaDir*)dir;
    if (!d) return -1;
    FindClose(d->handle);
    free(d);
    return 0;
}

int eiwa_mkdir(const char* path) {
    if (!path) return -1;
    return _mkdir(path);
}

int eiwa_is_dir(const char* path) {
    if (!path) return 0;
    DWORD attrs = GetFileAttributesA(path);
    if (attrs == INVALID_FILE_ATTRIBUTES) return 0;
    return (attrs & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
}

int eiwa_rmdir(const char* path) {
    if (!path) return -1;
    return _rmdir(path);
}

#else

#include <dirent.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

void* eiwa_opendir(const char* path) {
    return (void*)opendir(path);
}

const char* eiwa_readdir_name(void* dir) {
    DIR* d = (DIR*)dir;
    if (!d) return NULL;
    for (;;) {
        struct dirent* entry = readdir(d);
        if (!entry) return NULL;
        const char* name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        return name;
    }
}

int eiwa_closedir(void* dir) {
    DIR* d = (DIR*)dir;
    if (!d) return -1;
    return closedir(d);
}

int eiwa_mkdir(const char* path) {
    if (!path) return -1;
    return mkdir(path, 0755);
}

int eiwa_is_dir(const char* path) {
    if (!path) return 0;
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

int eiwa_rmdir(const char* path) {
    if (!path) return -1;
    return rmdir(path);
}

#endif
