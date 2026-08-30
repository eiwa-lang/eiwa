#include "net_helpers.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <string.h>

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
    if (listen(fd, 10) == SOCKET_ERROR) {
        closesocket(fd);
        return -1;
    }
    return (int64_t)fd;
}

int64_t eiwa_tcp_connect(const char* host, int64_t port) {
    ensure_winsock_initialized();
    SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        closesocket(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        closesocket(fd);
        return -1;
    }
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

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>

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
    if (listen(fd, 10) < 0) {
        close(fd);
        return -1;
    }
    return (int64_t)fd;
}

int64_t eiwa_tcp_connect(const char* host, int64_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return (int64_t)fd;
}

int64_t eiwa_tcp_accept(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    int client_fd = accept((int)fd, (struct sockaddr*)&addr, &addr_len);
    return (int64_t)client_fd;
}

int64_t eiwa_socket_read(int64_t fd, char* buf, int64_t max_len) {
    ssize_t n = read((int)fd, buf, (size_t)max_len);
    return (int64_t)n;
}

int64_t eiwa_socket_write(int64_t fd, const char* data, int64_t len) {
    int64_t total = 0;
    while (total < len) {
        struct pollfd pfd;
        pfd.fd = (int)fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, -1);
        if (pr < 0) return -1;
        ssize_t n = write((int)fd, data + total, (size_t)(len - total));
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
