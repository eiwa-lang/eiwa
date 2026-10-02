#include "poll_helpers.h"

#ifndef _WIN32

#include <poll.h>
#include <errno.h>

int eiwa_poll_retry(void* fds, int nfds, int timeout) {
    int r;
    do {
        r = poll((struct pollfd*)fds, (nfds_t)nfds, timeout);
    } while (r < 0 && errno == EINTR);
    return r;
}

#else

int eiwa_poll_retry(void* fds, int nfds, int timeout) {
    (void)fds;
    (void)nfds;
    (void)timeout;
    return -1;
}

#endif
