// Freestanding compat: symbols referenced by emitted-but-sometimes-idle host
// code paths (thread trampolines). The firmware owns fault handling; if one
// of these ever executes on device, spinning is louder than returning.
#include <stdint.h>

void eiwa_install_crash_handler(void) {}

// poll() is declared by the IDF <sys/poll.h> port header but implemented
// nowhere for lwIP sockets, so provide it over select() (universally
// available via VFS). Covers the POLLIN/POLLOUT/ERR surface the runtime's
// nonblocking connect/write paths need; NVAL/HUP nuances stay with select.
#include <sys/poll.h>
#include <sys/select.h>
#include <stddef.h>

int poll(struct pollfd *fds, nfds_t nfds, int timeout) {
    if (fds == NULL) {
        return -1;
    }
    fd_set rfds;
    fd_set wfds;
    fd_set efds;
    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    FD_ZERO(&efds);
    int maxfd = -1;
    for (nfds_t i = 0; i < nfds; i++) {
        int fd = fds[i].fd;
        if (fd < 0) {
            continue;
        }
        if (fds[i].events & POLLIN) {
            FD_SET(fd, &rfds);
        }
        if (fds[i].events & POLLOUT) {
            FD_SET(fd, &wfds);
        }
        FD_SET(fd, &efds);
        if (fd > maxfd) {
            maxfd = fd;
        }
    }
    struct timeval tv;
    tv.tv_sec = timeout / 1000;
    tv.tv_usec = (timeout % 1000) * 1000;
    int r = select(maxfd + 1, &rfds, &wfds, &efds, timeout < 0 ? NULL : &tv);
    if (r <= 0) {
        return r;
    }
    int nready = 0;
    for (nfds_t i = 0; i < nfds; i++) {
        int fd = fds[i].fd;
        short rev = 0;
        if (fd >= 0) {
            if (FD_ISSET(fd, &rfds)) {
                rev |= POLLIN;
            }
            if (FD_ISSET(fd, &wfds)) {
                rev |= POLLOUT;
            }
            if (FD_ISSET(fd, &efds)) {
                rev |= POLLERR;
            }
        } else {
            rev |= POLLNVAL;
        }
        fds[i].revents = rev;
        if (rev != 0) {
            nready++;
        }
    }
    return nready;
}

// newlib on IDF has no nanosleep; the scheduler's waitMs lowers to it.
// Implement over FreeRTOS ticks (ms granularity is all firmware needs;
// sub-ms remainders are dropped, EINTR never occurs).
#include <time.h>
#include <errno.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

int nanosleep(const struct timespec *req, struct timespec *rem) {
    if (req == NULL) {
        return 0;
    }
    vTaskDelay(pdMS_TO_TICKS((TickType_t)req->tv_sec * 1000 + (TickType_t)req->tv_nsec / 1000000));
    if (rem != NULL) {
        rem->tv_sec = 0;
        rem->tv_nsec = 0;
    }
    return 0;
}
