// Minimal station-mode WiFi for Eiwa: init-once, connect, wait for GOT_IP.
// Drops are left to the IDF stack (it auto-reconnects a started station);
// the Eiwa side polls eiwa_wifi_connected() or just reconnects.
#include "wifi_helpers.h"

#include <string.h>

#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

// Standalone reuse without the sample Kconfig.projbuild: empty SSID means
// "unconfigured" and connect() honestly returns 0.
#ifndef CONFIG_EIWA_WIFI_SSID
#define CONFIG_EIWA_WIFI_SSID ""
#endif
#ifndef CONFIG_EIWA_WIFI_PASS
#define CONFIG_EIWA_WIFI_PASS ""
#endif

#define EIWA_WIFI_GOT_IP_BIT BIT0
#define EIWA_WIFI_WAIT_MS 15000

static EventGroupHandle_t eiwa_wifi_bits = NULL;
static int eiwa_wifi_inited = 0;

static void eiwa_wifi_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        // Best-effort rejoin; the blocking wait below only cares about GOT_IP.
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        if (eiwa_wifi_bits != NULL) {
            xEventGroupSetBits(eiwa_wifi_bits, EIWA_WIFI_GOT_IP_BIT);
        }
    }
}

int64_t eiwa_wifi_connect(void) {
    const char *ssid = CONFIG_EIWA_WIFI_SSID;
    const char *pass = CONFIG_EIWA_WIFI_PASS;
    if (ssid == NULL || ssid[0] == '\0') {
        return 0;
    }

    if (!eiwa_wifi_inited) {
        esp_err_t r = nvs_flash_init();
        if (r == ESP_ERR_NVS_NO_FREE_PAGES || r == ESP_ERR_NVS_NEW_VERSION_FOUND) {
            nvs_flash_erase();
            r = nvs_flash_init();
        }
        if (r != ESP_OK) {
            return 0;
        }
        esp_netif_init();
        if (esp_event_loop_create_default() != ESP_OK) {
            return 0;
        }
        esp_netif_create_default_wifi_sta();
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        if (esp_wifi_init(&cfg) != ESP_OK) {
            return 0;
        }
        if (esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, eiwa_wifi_handler, NULL, NULL) != ESP_OK) {
            return 0;
        }
        if (esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, eiwa_wifi_handler, NULL, NULL) != ESP_OK) {
            return 0;
        }
        eiwa_wifi_bits = xEventGroupCreate();
        if (eiwa_wifi_bits == NULL) {
            return 0;
        }
        eiwa_wifi_inited = 1;
    } else {
        xEventGroupClearBits(eiwa_wifi_bits, EIWA_WIFI_GOT_IP_BIT);
    }

    wifi_config_t c;
    memset(&c, 0, sizeof(c));
    size_t slen = strlen(ssid);
    if (slen >= sizeof(c.sta.ssid)) {
        return 0;
    }
    memcpy(c.sta.ssid, ssid, slen);
    if (pass != NULL) {
        size_t plen = strlen(pass);
        if (plen >= sizeof(c.sta.password)) {
            return 0;
        }
        memcpy(c.sta.password, pass, plen);
    }
    // Open networks need an explicit threshold; secured ones keep default.
    if (pass == NULL || pass[0] == '\0') {
        c.sta.threshold.authmode = WIFI_AUTH_OPEN;
    }

    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK) {
        return 0;
    }
    if (esp_wifi_set_config(WIFI_IF_STA, &c) != ESP_OK) {
        return 0;
    }
    if (esp_wifi_start() != ESP_OK) {
        // Already started (retry path): fall through to the wait.
    }

    EventBits_t bits = xEventGroupWaitBits(eiwa_wifi_bits, EIWA_WIFI_GOT_IP_BIT, pdFALSE, pdFALSE,
                                           pdMS_TO_TICKS(EIWA_WIFI_WAIT_MS));
    return (bits & EIWA_WIFI_GOT_IP_BIT) ? 1 : 0;
}

int64_t eiwa_wifi_connected(void) {
    if (!eiwa_wifi_inited || eiwa_wifi_bits == NULL) {
        return 0;
    }
    return (xEventGroupGetBits(eiwa_wifi_bits) & EIWA_WIFI_GOT_IP_BIT) ? 1 : 0;
}
