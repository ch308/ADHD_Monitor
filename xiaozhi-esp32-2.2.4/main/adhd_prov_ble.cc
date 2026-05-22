#include "adhd_prov_ble.h"

#include "sdkconfig.h"

#if CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING

#include <cstdio>
#include <cstring>
#include <string>

#include <esp_event.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_system.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <nvs.h>
#include <nvs_flash.h>

#include "network_provisioning/manager.h"
#include "network_provisioning/scheme_ble.h"

#include "esp_timer.h"
#include "ssid_manager.h"
#include "wifi_manager.h"

static const char* TAG = "adhd_prov_ble";

// Project-wide BLE service UUID — must match Flutter EspProvUuids.service.
// Bytes are little-endian as advertised on-air.
static uint8_t s_prov_service_uuid[16] = {
    /* ad480001-7f86-46ad-a02e-3ca5849da5b6 */
    0xb6, 0xa5, 0x9d, 0x84, 0xa5, 0x3c, 0x2e, 0xa0,
    0xad, 0x46, 0x86, 0x7f, 0x01, 0x00, 0x48, 0xad,
};

static char s_prov_name[24] = {0};

static volatile bool  s_prov_done         = false;
// When credentials are received we save them via SsidManager (so the next
// boot's WifiManager picks them up) and arm a delayed reboot.  CONFIG_ESP_WIFI
// _NVS_ENABLED is OFF in this firmware, so network_prov_mgr's own
// esp_wifi_set_config call only lives in RAM — without an SsidManager save,
// every reboot would land us back in BLE config mode.
static volatile int64_t s_reboot_at_ms    = 0;

static void make_prov_name() {
    if (s_prov_name[0] != 0) {
        return;
    }
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    // Same convention as the plush-ball: last 4 bytes of the STA MAC, upper-hex.
    // We use the "XIAOZHI_" prefix so the Flutter app can tell the two
    // device kinds apart in a single BLE scan.
    std::snprintf(s_prov_name, sizeof(s_prov_name), "XIAOZHI_%02X%02X%02X%02X",
                  mac[2], mac[3], mac[4], mac[5]);
}

static void prov_event_handler(void* arg, esp_event_base_t base, int32_t id, void* data) {
    (void)arg;
    if (base != NETWORK_PROV_EVENT) {
        return;
    }
    switch (id) {
        case NETWORK_PROV_START:
            ESP_LOGI(TAG, "BLE provisioning started, name=%s", s_prov_name);
            break;
        case NETWORK_PROV_WIFI_CRED_RECV: {
            wifi_sta_config_t* cfg = (wifi_sta_config_t*)data;
            ESP_LOGI(TAG, "got creds, SSID=%s", (const char*)cfg->ssid);

            // Persist into xiaozhi's WiFi store so the post-reboot WifiManager
            // can find it (CONFIG_ESP_WIFI_NVS_ENABLED is off in this build,
            // so the IDF wifi_provisioning manager does NOT write to NVS).
            std::string ssid(reinterpret_cast<const char*>(cfg->ssid));
            std::string password(reinterpret_cast<const char*>(cfg->password));
            SsidManager::GetInstance().AddSsid(ssid, password);
            ESP_LOGI(TAG, "creds saved to SsidManager, will reboot to join AP");

            // Arm a short delayed reboot.  We don't try to keep BLE alive
            // long enough for network_prov_mgr to finish testing the AP —
            // the BT/Wi-Fi coexistence on ESP32-S3 routinely kills the GATT
            // link with LINK_SUPERVISION_TIMEOUT during STA association
            // anyway.  Letting WifiManager handle the actual STA connect on
            // the next boot is more reliable, and the Flutter app already
            // falls back to "wait for cloud announce" on this disconnect.
            s_reboot_at_ms = esp_timer_get_time() / 1000LL + 3000;
            break;
        }
        case NETWORK_PROV_WIFI_CRED_FAIL: {
            network_prov_wifi_sta_fail_reason_t* reason = (network_prov_wifi_sta_fail_reason_t*)data;
            ESP_LOGE(TAG, "creds failed, reason=%s",
                     (*reason == NETWORK_PROV_WIFI_STA_AUTH_ERROR) ? "AUTH" : "AP_NOT_FOUND");
            // Note: we already armed the reboot in CRED_RECV; this event
            // arrives much later (after IDF's STA retry budget) so just log.
            // On reboot WifiManager will retry the saved creds; if they're
            // still wrong it will time out into BLE config mode again.
            network_prov_mgr_reset_wifi_sm_state_on_failure();
            break;
        }
        case NETWORK_PROV_WIFI_CRED_SUCCESS:
            ESP_LOGI(TAG, "creds accepted by AP");
            break;
        case NETWORK_PROV_END:
            ESP_LOGI(TAG, "provisioning ended, will reboot");
            s_prov_done = true;
            break;
        default:
            break;
    }
}

void adhd_prov_ble_start_blocking(void) {
    make_prov_name();

    // Take xiaozhi's WifiManager out of the way. From this point we won't
    // interact with it again — we'll reboot once the manager finishes so that
    // WifiManager re-reads the freshly stored SSID/password from NVS on next
    // boot. This keeps us off the same WIFI_EVENT race the plush-ball flow
    // already had to fight off.
    WifiManager::GetInstance().StopStation();

    // The default IDF event loop and NVS are already initialised by xiaozhi's
    // boot sequence; network_prov_mgr just plugs into them.
    esp_err_t err = esp_event_handler_register(NETWORK_PROV_EVENT, ESP_EVENT_ANY_ID,
                                               &prov_event_handler, NULL);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "register prov event handler: %s", esp_err_to_name(err));
        return;
    }

    network_prov_mgr_config_t cfg = {};
    cfg.scheme = network_prov_scheme_ble;
    // Keep BTDM up — we'll just esp_restart() when prov is done. Releasing
    // BTDM mid-flight while still inside the manager has been flaky on S3.
    cfg.scheme_event_handler = NETWORK_PROV_EVENT_HANDLER_NONE;

    err = network_prov_mgr_init(cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "network_prov_mgr_init: %s", esp_err_to_name(err));
        return;
    }

    network_prov_scheme_ble_set_service_uuid(s_prov_service_uuid);

    // SECURITY_0 only — Flutter EspProvisionService.dart hand-rolls the
    // sec0 SessionData protobuf (no SRP6a / no PoP).
    err = network_prov_mgr_start_provisioning(NETWORK_PROV_SECURITY_0,
                                              /*pop=*/NULL, s_prov_name,
                                              /*service_key=*/NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "start_provisioning: %s", esp_err_to_name(err));
        network_prov_mgr_deinit();
        return;
    }

    // Block here until either the CRED_RECV handler arms a reboot (success
    // path: creds delivered → SsidManager populated → reboot soon) or the
    // 5-min ceiling expires (no client showed up, no point holding BLE
    // forever).
    const TickType_t poll = pdMS_TO_TICKS(200);
    const int max_iters = (5 * 60 * 1000) / 200;
    for (int i = 0; i < max_iters && !s_prov_done; ++i) {
        vTaskDelay(poll);

        int64_t reboot_at = s_reboot_at_ms;
        if (reboot_at > 0) {
            int64_t now_ms = esp_timer_get_time() / 1000LL;
            if (now_ms >= reboot_at) {
                ESP_LOGW(TAG, "reboot deadline reached, rebooting now");
                break;
            }
        }
    }

    ESP_LOGW(TAG, "rebooting to let WifiManager pick up new credentials");
    vTaskDelay(pdMS_TO_TICKS(300));  // let logs / final BLE responses flush
    esp_restart();
}

void adhd_prov_ble_reset_and_reboot(void) {
    ESP_LOGW(TAG, "reset_provisioning requested → clearing NVS WiFi creds");

    // 1) Try the proper manager API — works even if the manager isn't running
    //    in the current boot (the IDF helper opens NVS by itself).
    esp_err_t err = network_prov_mgr_reset_wifi_provisioning();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "network_prov_mgr_reset_wifi_provisioning: %s, fallback to esp_wifi_restore",
                 esp_err_to_name(err));
        // 2) esp_wifi_restore() wipes the SSID/PASSWORD from the wifi NVS
        //    namespace. Requires esp_wifi_init to have been called, which
        //    xiaozhi's WifiManager does at boot.
        esp_err_t r2 = esp_wifi_restore();
        if (r2 != ESP_OK) {
            ESP_LOGE(TAG, "esp_wifi_restore: %s — manually erasing nvs.net80211",
                     esp_err_to_name(r2));
            // 3) Last-ditch: erase the IDF wifi NVS namespace by hand.
            nvs_handle_t h;
            if (nvs_open("nvs.net80211", NVS_READWRITE, &h) == ESP_OK) {
                nvs_erase_all(h);
                nvs_commit(h);
                nvs_close(h);
            }
        }
    }

    // xiaozhi's own SsidManager (78/esp-wifi-connect) keeps its own list under
    // the "wifi" NVS namespace; clearing that too keeps the two stacks in sync
    // so WifiManager doesn't immediately reconnect to the just-erased AP.
    nvs_handle_t h;
    if (nvs_open("wifi", NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_all(h);
        nvs_commit(h);
        nvs_close(h);
    }

    vTaskDelay(pdMS_TO_TICKS(400));
    esp_restart();
}

#else  // !CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING

void adhd_prov_ble_start_blocking(void) {}
void adhd_prov_ble_reset_and_reboot(void) {}

#endif
