#include "net_helpers.h"

#ifdef _WIN32
#define EIWA_LISTEN_BACKLOG 128
#else
#include <sys/socket.h>
#define EIWA_LISTEN_BACKLOG SOMAXCONN
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <string.h>
#include <stdio.h>

static void ensure_winsock_initialized(void) {
    static int initialized = 0;
    if (!initialized) {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
        initialized = 1;
    }
}

int64_t eiwa_tcp_bind(int64_t port) {
    ensure_winsock_initialized();
    SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET) return -1;
    char opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        closesocket(fd);
        return -1;
    }
    if (listen(fd, EIWA_LISTEN_BACKLOG) == SOCKET_ERROR) {
        closesocket(fd);
        return -1;
    }
    return (int64_t)fd;
}

int64_t eiwa_tcp_connect(const char* host, int64_t port) {
    ensure_winsock_initialized();
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%lld", (long long)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo* list = NULL;
    if (getaddrinfo(host, port_str, &hints, &list) != 0 || list == NULL) {
        if (list != NULL) freeaddrinfo(list);
        return -1;
    }
    SOCKET fd = INVALID_SOCKET;
    for (struct addrinfo* ai = list; ai != NULL; ai = ai->ai_next) {
        SOCKET s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == INVALID_SOCKET) continue;
        // Bounded connect: a blocking connect() to an unroutable address
        // (e.g. ::1 with broken IPv6) can stall for minutes, hanging the
        // whole test suite on the 120s harness timeout. Go non-blocking and
        // cap each candidate address at 2s via WSAPoll + SO_ERROR.
        u_long mode = 1;
        if (ioctlsocket(s, FIONBIO, &mode) != 0) {
            closesocket(s);
            continue;
        }
        int cr = connect(s, ai->ai_addr, (int)ai->ai_addrlen);
        if (cr == SOCKET_ERROR) {
            if (WSAGetLastError() != WSAEWOULDBLOCK) {
                closesocket(s);
                continue;
            }
            WSAPOLLFD pfd;
            pfd.fd = s;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            int pr = WSAPoll(&pfd, 1, 2000);
            if (pr <= 0) {
                closesocket(s);
                continue;
            }
            int soerr = 0;
            int optlen = sizeof(soerr);
            if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&soerr, &optlen) != 0 || soerr != 0) {
                closesocket(s);
                continue;
            }
        }
        fd = s;
        break;
    }
    freeaddrinfo(list);
    if (fd == INVALID_SOCKET) return -1;
    return (int64_t)fd;
}

int64_t eiwa_tcp_accept(int64_t fd) {
    struct sockaddr_in addr;
    int addr_len = sizeof(addr);
    SOCKET client_fd = accept((SOCKET)fd, (struct sockaddr*)&addr, &addr_len);
    if (client_fd == INVALID_SOCKET) return -1;
    return (int64_t)client_fd;
}

int64_t eiwa_socket_read(int64_t fd, char* buf, int64_t max_len) {
    int n = recv((SOCKET)fd, buf, (int)max_len, 0);
    return (int64_t)n;
}

int64_t eiwa_socket_write(int64_t fd, const char* data, int64_t len) {
    int64_t total = 0;
    while (total < len) {
        WSAPOLLFD pfd;
        pfd.fd = (SOCKET)fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int pr = WSAPoll(&pfd, 1, -1);
        if (pr == SOCKET_ERROR) return -1;
        int n = send((SOCKET)fd, data + total, (int)(len - total), 0);
        if (n <= 0) return (total > 0) ? total : (int64_t)n;
        total += (int64_t)n;
    }
    return total;
}

int64_t eiwa_tcp_set_nonblocking(int64_t fd) {
    u_long mode = 1;
    int res = ioctlsocket((SOCKET)fd, FIONBIO, &mode);
    return (int64_t)res;
}

void eiwa_socket_close(int64_t fd) {
    closesocket((SOCKET)fd);
}

#else

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

int64_t eiwa_tcp_bind(int64_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, EIWA_LISTEN_BACKLOG) < 0) {
        close(fd);
        return -1;
    }
    return (int64_t)fd;
}

int64_t eiwa_tcp_connect(const char* host, int64_t port) {
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%lld", (long long)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* list = NULL;
    if (getaddrinfo(host, port_str, &hints, &list) != 0 || list == NULL) {
        if (list != NULL) freeaddrinfo(list);
        return -1;
    }
    int fd = -1;
    for (struct addrinfo* ai = list; ai != NULL; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
        // Same bounded-connect rationale as the Windows branch above.
        int flags = fcntl(s, F_GETFL, 0);
        if (flags < 0 || fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(s);
            continue;
        }
        int cr;
        do {
            cr = connect(s, ai->ai_addr, ai->ai_addrlen);
        } while (cr < 0 && errno == EINTR);
        if (cr < 0 && errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = s;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            int pr;
            do {
                pr = poll(&pfd, 1, 2000);
            } while (pr < 0 && errno == EINTR);
            if (pr <= 0) {
                close(s);
                continue;
            }
            int soerr = 0;
            socklen_t optlen = sizeof(soerr);
            if (getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &optlen) != 0 || soerr != 0) {
                close(s);
                continue;
            }
        } else if (cr != 0) {
            close(s);
            continue;
        }
        fd = s;
        break;
    }
    freeaddrinfo(list);
    if (fd < 0) return -1;
    return (int64_t)fd;
}

int64_t eiwa_tcp_accept(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    int client_fd;
    do {
        client_fd = accept((int)fd, (struct sockaddr*)&addr, &addr_len);
    } while (client_fd < 0 && errno == EINTR);
    return (int64_t)client_fd;
}

int64_t eiwa_socket_read(int64_t fd, char* buf, int64_t max_len) {
    ssize_t n;
    do {
        n = read((int)fd, buf, (size_t)max_len);
    } while (n < 0 && errno == EINTR);
    return (int64_t)n;
}

int64_t eiwa_socket_write(int64_t fd, const char* data, int64_t len) {
    int64_t total = 0;
    while (total < len) {
        struct pollfd pfd;
        pfd.fd = (int)fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int pr;
        do {
            pr = poll(&pfd, 1, -1);
        } while (pr < 0 && errno == EINTR);
        if (pr < 0) return -1;
        ssize_t n;
        do {
            n = write((int)fd, data + total, (size_t)(len - total));
        } while (n < 0 && errno == EINTR);
        if (n <= 0) return (total > 0) ? total : (int64_t)n;
        total += (int64_t)n;
    }
    return total;
}

int64_t eiwa_tcp_set_nonblocking(int64_t fd) {
    int flags = fcntl((int)fd, F_GETFL, 0);
    if (flags < 0) return -1;
    int res = fcntl((int)fd, F_SETFL, flags | O_NONBLOCK);
    return (int64_t)res;
}

void eiwa_socket_close(int64_t fd) {
    close((int)fd);
}

#endif
