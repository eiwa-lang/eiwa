#ifndef EIWA_NET_HELPERS_H
#define EIWA_NET_HELPERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int64_t eiwa_tcp_bind(int64_t port);
int64_t eiwa_tcp_accept(int64_t fd);
int64_t eiwa_socket_read(int64_t fd, char* buf, int64_t max_len);
int64_t eiwa_socket_write(int64_t fd, const char* data, int64_t len);
int64_t eiwa_tcp_set_nonblocking(int64_t fd);
void eiwa_socket_close(int64_t fd);

#ifdef __cplusplus
}
#endif

#endif // EIWA_NET_HELPERS_H
