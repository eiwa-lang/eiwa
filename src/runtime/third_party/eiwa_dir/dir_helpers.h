#ifndef EIWA_DIR_HELPERS_H
#define EIWA_DIR_HELPERS_H

void* eiwa_opendir(const char* path);
const char* eiwa_readdir_name(void* dir);
int eiwa_closedir(void* dir);
int eiwa_mkdir(const char* path);
int eiwa_is_dir(const char* path);
int eiwa_rmdir(const char* path);

#endif // EIWA_DIR_HELPERS_H
