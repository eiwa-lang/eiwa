// https://github.com/tidwall/neco
//
// Copyright 2024 Joshua J Baker. All rights reserved.
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.
//
// Neco -- Coroutine library for C

#ifndef NECO_H
#define NECO_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <netdb.h>
#include <sys/socket.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

int neco_start(void(*coroutine)(int argc, void *argv[]), int argc, ...);
int neco_startv(void(*coroutine)(int argc, void *argv[]), int argc, void *argv[]);
int neco_yield(void);
int neco_sleep(int64_t nanosecs);
int neco_sleep_dl(int64_t deadline);
int neco_join(int64_t id);
int neco_join_dl(int64_t id, int64_t deadline);
int neco_suspend(void);
int neco_suspend_dl(int64_t deadline);
int neco_resume(int64_t id);
void neco_exit(void);
int64_t neco_getid(void);
int64_t neco_lastid(void);
int64_t neco_starterid(void);

typedef struct neco_chan neco_chan;

int neco_chan_make(neco_chan **chan, size_t data_size, size_t capacity);
int neco_chan_retain(neco_chan *chan);
int neco_chan_release(neco_chan *chan);
int neco_chan_send(neco_chan *chan, void *data);
int neco_chan_send_dl(neco_chan *chan, void *data, int64_t deadline);
int neco_chan_broadcast(neco_chan *chan, void *data);
int neco_chan_recv(neco_chan *chan, void *data);
int neco_chan_recv_dl(neco_chan *chan, void *data, int64_t deadline);
int neco_chan_tryrecv(neco_chan *chan, void *data);
int neco_chan_close(neco_chan *chan);
int neco_chan_select(int nchans, ...);
int neco_chan_select_dl(int64_t deadline, int nchans, ...);
int neco_chan_selectv(int nchans, neco_chan *chans[]);
int neco_chan_selectv_dl(int nchans, neco_chan *chans[], int64_t deadline);
int neco_chan_tryselect(int nchans, ...);
int neco_chan_tryselectv(int nchans, neco_chan *chans[]);
int neco_chan_case(neco_chan *chan, void *data);

typedef struct neco_gen neco_gen;

int neco_gen_start(neco_gen **gen, size_t data_size, void(*coroutine)(int argc, void *argv[]), int argc, ...);
int neco_gen_startv(neco_gen **gen, size_t data_size, void(*coroutine)(int argc, void *argv[]), int argc, void *argv[]);
int neco_gen_retain(neco_gen *gen);
int neco_gen_release(neco_gen *gen);
int neco_gen_yield(void *data);
int neco_gen_yield_dl(void *data, int64_t deadline);
int neco_gen_next(neco_gen *gen, void *data);
int neco_gen_next_dl(neco_gen *gen, void *data, int64_t deadline);
int neco_gen_close(neco_gen *gen);

typedef struct { int64_t _0; intptr_t _1[5]; } neco_mutex;
#define NECO_MUTEX_INITIALIZER { 0 }

int neco_mutex_init(neco_mutex *mutex);
int neco_mutex_lock(neco_mutex *mutex);
int neco_mutex_lock_dl(neco_mutex *mutex, int64_t deadline);
int neco_mutex_trylock(neco_mutex *mutex);
int neco_mutex_unlock(neco_mutex *mutex);
int neco_mutex_rdlock(neco_mutex *mutex);
int neco_mutex_rdlock_dl(neco_mutex *mutex, int64_t deadline);
int neco_mutex_tryrdlock(neco_mutex *mutex);

typedef struct { int64_t _0; intptr_t _1[5]; } neco_waitgroup;
#define NECO_WAITGROUP_INITIALIZER { 0 }

int neco_waitgroup_init(neco_waitgroup *waitgroup);
int neco_waitgroup_add(neco_waitgroup *waitgroup, int delta);
int neco_waitgroup_done(neco_waitgroup *waitgroup);
int neco_waitgroup_wait(neco_waitgroup *waitgroup);
int neco_waitgroup_wait_dl(neco_waitgroup *waitgroup, int64_t deadline);

typedef struct { int64_t _0; intptr_t _1[5]; } neco_cond;
#define NECO_COND_INITIALIZER { 0 }

int neco_cond_init(neco_cond *cond);
int neco_cond_signal(neco_cond *cond);
int neco_cond_broadcast(neco_cond *cond);
int neco_cond_wait(neco_cond *cond, neco_mutex *mutex);
int neco_cond_wait_dl(neco_cond *cond, neco_mutex *mutex, int64_t deadline);

ssize_t neco_read(int fd, void *data, size_t nbytes);
ssize_t neco_read_dl(int fd, void *data, size_t nbytes, int64_t deadline);
ssize_t neco_write(int fd, const void *data, size_t nbytes);
ssize_t neco_write_dl(int fd, const void *data, size_t nbytes, int64_t deadline);
int neco_accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
int neco_accept_dl(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int64_t deadline);
int neco_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
int neco_connect_dl(int sockfd, const struct sockaddr *addr, socklen_t addrlen, int64_t deadline);
int neco_getaddrinfo(const char *node, const char *service,
    const struct addrinfo *hints, struct addrinfo **res);
int neco_getaddrinfo_dl(const char *node, const char *service,
    const struct addrinfo *hints, struct addrinfo **res, int64_t deadline);

int neco_setnonblock(int fd, bool nonblock, bool *oldnonblock);

#define NECO_WAIT_READ  1
#define NECO_WAIT_WRITE 2

int neco_wait(int fd, int mode);
int neco_wait_dl(int fd, int mode, int64_t deadline);

int neco_serve(const char *network, const char *address);
int neco_serve_dl(const char *network, const char *address, int64_t deadline);
int neco_dial(const char *network, const char *address);
int neco_dial_dl(const char *network, const char *address, int64_t deadline);

int neco_cancel(int64_t id);
int neco_cancel_dl(int64_t id, int64_t deadline);

#define NECO_CANCEL_ASYNC      1
#define NECO_CANCEL_INLINE     2
#define NECO_CANCEL_ENABLE     3
#define NECO_CANCEL_DISABLE    4

int neco_setcanceltype(int type, int *oldtype);
int neco_setcancelstate(int state, int *oldstate);

#define neco_cleanup_push(routine, arg) {char __neco_handler[32]={0};\
    __neco_c0(__neco_handler,routine,arg);
#define neco_cleanup_pop(execute) __neco_c1(execute);}

#define NECO_CSPRNG 0
#define NECO_PRNG   1

int neco_rand_setseed(int64_t seed, int64_t *oldseed);
int neco_rand(void *data, size_t nbytes, int attr);
int neco_rand_dl(void *data, size_t nbytes, int attr, int64_t deadline);

int neco_signal_watch(int signo);
int neco_signal_wait(void);
int neco_signal_wait_dl(int64_t deadline);
int neco_signal_unwatch(int signo);

int neco_work(int64_t pin, void(*work)(void *udata), void *udata);

typedef struct neco_stats {
    size_t coroutines;
    size_t sleepers;
    size_t evwaiters;
    size_t sigwaiters;
    size_t senders;
    size_t receivers;
    size_t locked;
    size_t waitgroupers;
    size_t condwaiters;
    size_t suspended;
    size_t workers;
} neco_stats;

int neco_getstats(neco_stats *stats);
int neco_is_main_thread(void);
const char *neco_switch_method(void);

void neco_env_setallocator(void *(*malloc)(size_t), void *(*realloc)(void*, size_t), void (*free)(void*));
void neco_env_setpaniconerror(bool paniconerror);
void neco_env_setcanceltype(int type);
void neco_env_setcancelstate(int state);

#define NECO_NANOSECOND  INT64_C(1)
#define NECO_MICROSECOND INT64_C(1000)
#define NECO_MILLISECOND INT64_C(1000000)
#define NECO_SECOND      INT64_C(1000000000)
#define NECO_MINUTE      INT64_C(60000000000)
#define NECO_HOUR        INT64_C(3600000000000)

int64_t neco_now(void);

#define NECO_OK              0
#define NECO_ERROR          -1
#define NECO_INVAL          -2
#define NECO_PERM           -3
#define NECO_NOMEM          -4
#define NECO_EOF            -5
#define NECO_NOTFOUND       -6
#define NECO_NOSIGWATCH     -7
#define NECO_CLOSED         -8
#define NECO_EMPTY          -9
#define NECO_TIMEDOUT      -10
#define NECO_CANCELED      -11
#define NECO_BUSY          -12
#define NECO_NEGWAITGRP    -13
#define NECO_GAIERROR      -14
#define NECO_UNREADFAIL    -15
#define NECO_PARTIALWRITE  -16
#define NECO_NOTGENERATOR  -17
#define NECO_NOTSUSPENDED  -18

const char *neco_strerror(ssize_t errcode);
int neco_lasterr(void);
int neco_gai_lasterr(void);
int neco_panic(const char *fmt, ...);

typedef struct neco_stream neco_stream;

int neco_stream_make(neco_stream **stream, int fd);
int neco_stream_make_buffered(neco_stream **stream, int fd);
int neco_stream_close(neco_stream *stream);
int neco_stream_close_dl(neco_stream *stream, int64_t deadline);
ssize_t neco_stream_read(neco_stream *stream, void *data, size_t nbytes);
ssize_t neco_stream_read_dl(neco_stream *stream, void *data, size_t nbytes, int64_t deadline);
ssize_t neco_stream_write(neco_stream *stream, const void *data, size_t nbytes);
ssize_t neco_stream_write_dl(neco_stream *stream, const void *data, size_t nbytes, int64_t deadline);
ssize_t neco_stream_readfull(neco_stream *stream, void *data, size_t nbytes);
ssize_t neco_stream_readfull_dl(neco_stream *stream, void *data, size_t nbytes, int64_t deadline);
int neco_stream_read_byte(neco_stream *stream);
int neco_stream_read_byte_dl(neco_stream *stream, int64_t deadline);
int neco_stream_unread_byte(neco_stream *stream);
int neco_stream_flush(neco_stream *stream);
int neco_stream_flush_dl(neco_stream *stream, int64_t deadline);
ssize_t neco_stream_buffered_read_size(neco_stream *stream);
ssize_t neco_stream_buffered_write_size(neco_stream *stream);

#include <stdio.h>
#include <stdlib.h>

// neco_main macro: replaces int main() with int neco_main()
// The macro converts int neco_main(...) into a wrapper that initializes
// the neco runtime and starts the program as a coroutine.
#define neco_main \
__neco_main(int argc, char *argv[]); \
static void _neco_main(int argc, void *argv[]) { \
    (void)argc; \
    __neco_exit_prog(__neco_main(*(int*)argv[0], *(char***)argv[1])); \
} \
int main(int argc, char *argv[]) { \
    neco_env_setpaniconerror(true); \
    neco_env_setcanceltype(NECO_CANCEL_ASYNC); \
    int ret = neco_start(_neco_main, 2, &argc, &argv); \
    fprintf(stderr, "neco_start: %s (code %d)\n", neco_strerror(ret), ret); \
    return -1; \
}; \
int __neco_main

void __neco_c0(void*,void(*)(void*),void*); 
void __neco_c1(int);
void __neco_exit_prog(int);

#ifndef EAI_SYSTEM
#define EAI_SYSTEM 11
#endif

#ifdef __cplusplus
}
#endif

#endif // NECO_H
