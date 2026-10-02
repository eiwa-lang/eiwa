#ifndef EIWA_POLL_HELPERS_H
#define EIWA_POLL_HELPERS_H

// EINTR-resilient poll(): retries when a signal interrupts the wait and
// returns every other outcome (ready/timeout/error) untouched. Lets
// runtimes that suspend threads with signals (e.g. Boehm GC stop-the-world
// on Linux) coexist with blocking readiness waits.
int eiwa_poll_retry(void* fds, int nfds, int timeout);

#endif // EIWA_POLL_HELPERS_H
