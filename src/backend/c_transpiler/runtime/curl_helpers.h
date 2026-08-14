#ifndef EIWA_CURL_HELPERS_H
#define EIWA_CURL_HELPERS_H

#include <gc.h>
#include <string.h>
#include <curl/curl.h>

struct EiwaCurlBuffer {
    char* data;
    size_t size;
};

static inline size_t eiwa_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t realsize = size * nmemb;
    struct EiwaCurlBuffer* mem = (struct EiwaCurlBuffer*)userp;
    char* ptr = GC_REALLOC(mem->data, mem->size + realsize + 1);
    if(!ptr) return 0;
    mem->data = ptr;
    memcpy(&(mem->data[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->data[mem->size] = 0;
    return realsize;
}

static inline void* eiwa_get_write_callback_ptr() {
    return (void*)eiwa_curl_write_callback;
}

static inline char* eiwa_curl_buf_data(void* buf) {
    return ((struct EiwaCurlBuffer*)buf)->data;
}

static inline int eiwa_curl_buf_size(void* buf) {
    return (int)((struct EiwaCurlBuffer*)buf)->size;
}

static inline int eiwa_curl_get_status(CURL* curl) {
    long response_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    return (int)response_code;
}

#endif // EIWA_CURL_HELPERS_H
