// Non-static implementations of the curl helpers so the LLVM backend can
// resolve the `lib NativeHttp` externs as real symbols. The C backend inlines
// the `static inline` versions from curl_helpers.h instead (no conflict: this
// TU never includes that header).
#include <stdlib.h>
#include <string.h>
#include <gc.h>
#include <curl/curl.h>

struct EiwaCurlBuffer {
    char* data;
    size_t size;
};

static size_t eiwa_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t realsize = size * nmemb;
    struct EiwaCurlBuffer* mem = (struct EiwaCurlBuffer*)userp;
    char* ptr = GC_REALLOC(mem->data, mem->size + realsize + 1);
    if (!ptr) return 0;
    mem->data = ptr;
    memcpy(&(mem->data[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->data[mem->size] = 0;
    return realsize;
}

void* eiwa_get_write_callback_ptr(void) {
    return (void*)eiwa_curl_write_callback;
}

char* eiwa_curl_buf_data(void* buf) {
    return ((struct EiwaCurlBuffer*)buf)->data;
}

int eiwa_curl_buf_size(void* buf) {
    return (int)((struct EiwaCurlBuffer*)buf)->size;
}

int eiwa_curl_get_status(CURL* curl) {
    long response_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    return (int)response_code;
}

int eiwa_curl_setopt_string(CURL* curl, CURLoption option, const void* value) {
    return curl_easy_setopt(curl, option, value);
}

int eiwa_curl_setopt_ptr(CURL* curl, CURLoption option, void* value) {
    return curl_easy_setopt(curl, option, value);
}

int eiwa_curl_setopt_int(CURL* curl, CURLoption option, int value) {
    return curl_easy_setopt(curl, option, (long)value);
}
