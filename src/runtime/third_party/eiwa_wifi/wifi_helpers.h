#ifndef EIWA_WIFI_HELPERS_H
#define EIWA_WIFI_HELPERS_H

#include <stdint.h>

// Blocking station connect: returns 1 once GOT_IP, 0 on timeout or when
// no credentials are configured (CONFIG_EIWA_WIFI_SSID empty).
int64_t eiwa_wifi_connect(void);

// 1 when associated with an IP, 0 otherwise.
int64_t eiwa_wifi_connected(void);

#endif
