#ifndef EIWA_NET_HELPERS_H
#define EIWA_NET_HELPERS_H

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

// POSIX Net Helpers
static inline int eiwa_tcp_bind(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 10) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static inline int eiwa_tcp_accept(int fd) {
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    return accept(fd, (struct sockaddr*)&addr, &addr_len);
}

static inline int eiwa_socket_read(int fd, char* buf, int max_len) {
    return read(fd, buf, max_len);
}

static inline int eiwa_socket_write(int fd, const char* data, int len) {
    return write(fd, data, len);
}

static inline int eiwa_tcp_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static inline void eiwa_socket_close(int fd) {
    close(fd);
}

#endif // EIWA_NET_HELPERS_H
