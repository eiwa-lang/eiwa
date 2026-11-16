// Freestanding compat: symbols referenced by emitted-but-sometimes-idle host
// code paths (thread trampolines). The firmware owns fault handling; if one
// of these ever executes on device, spinning is louder than returning.
#include <stdint.h>

void eiwa_install_crash_handler(void) {}

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
