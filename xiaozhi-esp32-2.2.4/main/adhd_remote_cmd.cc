#include "adhd_remote_cmd.h"

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
#include <cstring>
#include <string>
#include <esp_log.h>
#endif

#if CONFIG_ADHD_MONITOR_BYPASS_OTA
#include "settings.h"
#endif

// announce + long-poll both belong to Path A. They were originally only
// compiled when CONFIG_ADHD_MONITOR_REMOTE_CMD was on, but in practice
// CONFIG_ADHD_MONITOR_BYPASS_OTA=y already implies "we're on Path A and
// the Flutter app is waiting for /device/esp32/announce". Latch the two
// together so a stale sdkconfig with REMOTE_CMD=n + BYPASS_OTA=y (which
// happened to one user after defaults were merged into an old sdkconfig
// without fullclean) still emits the announce — otherwise the Flutter
// cloud-wait silently fails 60 s out and the user thinks BLE provisioning
// broke.
#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
#include <cstdio>
#include <cJSON.h>
#include <esp_http_client.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_mac.h>

#include "application.h"
#if CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING
#include "adhd_prov_ble.h"
#endif
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
static const char* TAG = "adhd_cmd";
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
// Must match BLE name `XIAOZHI_<id>` / Flutter `EspProvDevice.deviceId` and the
// plush-ball `ADHD_<id>` convention: last 4 bytes of STA MAC as 8 upper-hex
// chars (see adhd_prov_ble::make_prov_name and ESP32-S3-LCD Wireless.c).
// Do NOT use the full 12-char MAC here — the App binds `E0160560` while we
// used to announce `9888E0160560`, so the DB row never matched and long-poll
// hit the wrong URL.
static std::string PathADeviceIdUpper() {
    uint8_t mac[6] = {0};
    esp_err_t e = esp_read_mac(mac, ESP_MAC_WIFI_STA);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "esp_read_mac(ESP_MAC_WIFI_STA): %s", esp_err_to_name(e));
        return std::string();
    }
    char buf[16];
    snprintf(buf, sizeof(buf), "%02X%02X%02X%02X", mac[2], mac[3], mac[4], mac[5]);
    return std::string(buf);
}
#endif

#if CONFIG_ADHD_MONITOR_BYPASS_OTA
void adhd_remote_cmd_seed_settings(void) {
    Settings settings("websocket", true);

    const char* url = CONFIG_ADHD_MONITOR_WS_URL;
    const char* token = CONFIG_ADHD_MONITOR_WS_TOKEN;
    if (url && url[0] != '\0') {
        if (settings.GetString("url") != std::string(url)) {
            settings.SetString("url", url);
        }
    }
    if (token && token[0] != '\0') {
        if (settings.GetString("token") != std::string(token)) {
            settings.SetString("token", token);
        }
    }
    if (settings.GetInt("version") == 0) {
        settings.SetInt("version", 1);
    }
    ESP_LOGI(TAG, "websocket NVS seeded: url=%s", url);
}
#else
void adhd_remote_cmd_seed_settings(void) {}
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA

static bool HttpPostJson(const std::string& url, const std::string& body) {
    esp_http_client_config_t cfg = {};
    cfg.url = url.c_str();
    cfg.timeout_ms = 12000;
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client) {
        return false;
    }
    esp_http_client_set_method(client, HTTP_METHOD_POST);
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, body.c_str(), static_cast<int>(body.size()));
    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);
    return err == ESP_OK && status >= 200 && status < 300;
}

static void DoAnnounceOnce() {
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4) {
        ESP_LOGW(TAG, "announce skipped: empty device id");
        return;
    }
    std::string body = std::string("{\"device_id\":\"") + id + "\",\"kind\":\"xiaozhi\"}";
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/esp32/announce";
    ESP_LOGI(TAG, "announce POST → %s", url.c_str());
    if (!HttpPostJson(url, body)) {
        ESP_LOGW(TAG, "announce POST failed (device_id=%s)", id.c_str());
    } else {
        ESP_LOGI(TAG, "announce ok device_id=%s", id.c_str());
    }
}

void adhd_remote_cmd_announce_sync_once(void) {
    if (strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        ESP_LOGW(TAG, "announce_sync: ADHD_MONITOR_CMD_HOST empty, skip");
        return;
    }
    DoAnnounceOnce();
}

static void HandleOneCommand(cJSON* root) {
    cJSON* action = cJSON_GetObjectItem(root, "action");
    if (!cJSON_IsString(action)) {
        return;
    }
    const char* act = action->valuestring;
    if (strcmp(act, "xiaozhi_invoke_chat") == 0) {
        cJSON* ol = cJSON_GetObjectItem(root, "opening_line");
        std::string ww = " ";
        if (cJSON_IsString(ol) && ol->valuestring && strlen(ol->valuestring) > 0) {
            ww = ol->valuestring;
        }
        Application::GetInstance().Schedule([ww]() {
            Application::GetInstance().WakeWordInvoke(ww);
        });
    } else if (strcmp(act, "xiaozhi_abort") == 0) {
        Application::GetInstance().Schedule([]() {
            Application::GetInstance().ResetProtocol();
        });
    } else if (strcmp(act, "reset_provisioning") == 0) {
        // Same wire format as the plush-ball flow: clear the WiFi NVS and
        // reboot so the device re-enters BLE provisioning advertising.
        // Only effective when CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING is on;
        // otherwise xiaozhi will fall back to whatever wifi-config method
        // is enabled (hotspot/blufi/acoustic) on next boot.
#if CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING
        ESP_LOGW(TAG, "→ reset_provisioning (BLE prov enabled)");
        adhd_prov_ble_reset_and_reboot();
#else
        ESP_LOGW(TAG, "reset_provisioning received but BLE provisioning disabled — ignoring");
#endif
    }
}

static void ProcessCmdPayload(const char* json) {
    cJSON* root = cJSON_Parse(json);
    if (!root) {
        return;
    }
    cJSON* cmds = cJSON_GetObjectItem(root, "cmds");
    if (cJSON_IsArray(cmds)) {
        const int n = cJSON_GetArraySize(cmds);
        for (int i = 0; i < n; ++i) {
            cJSON* item = cJSON_GetArrayItem(cmds, i);
            if (cJSON_IsObject(item)) {
                HandleOneCommand(item);
            }
        }
    } else if (cJSON_GetObjectItem(root, "action")) {
        HandleOneCommand(root);
    }
    cJSON_Delete(root);
}

static void RemoteCmdTask(void* /*arg*/) {
    // announce 已在 Application::HandleActivationDoneEvent 里同步执行过，
    // 这里只做长轮询，避免重复 POST 与「后台任务晚于 App 轮询」的竞态。
    vTaskDelay(pdMS_TO_TICKS(500));
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4) {
        ESP_LOGE(TAG, "invalid mac id");
        vTaskDelete(nullptr);
        return;
    }
    while (true) {
        std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                          std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/" + id +
                          "/cmd?wait=55";

        esp_http_client_config_t cfg = {};
        cfg.url = url.c_str();
        cfg.timeout_ms = 70000;
        esp_http_client_handle_t client = esp_http_client_init(&cfg);
        if (!client) {
            vTaskDelay(pdMS_TO_TICKS(3000));
            continue;
        }
        esp_http_client_set_method(client, HTTP_METHOD_GET);
        esp_err_t err = esp_http_client_open(client, 0);
        int status = 0;
        std::string body;
        if (err == ESP_OK) {
            int cl = esp_http_client_fetch_headers(client);
            status = esp_http_client_get_status_code(client);
            if (cl > 0 && cl < 65536) {
                body.resize(static_cast<size_t>(cl));
                int total = 0;
                while (total < cl) {
                    int r = esp_http_client_read(client, body.data() + total, cl - total);
                    if (r <= 0) {
                        break;
                    }
                    total += r;
                }
                body.resize(static_cast<size_t>(total));
            } else if (status == 200) {
                char tmp[4096];
                int r = esp_http_client_read(client, tmp, sizeof(tmp) - 1);
                if (r > 0) {
                    tmp[r] = '\0';
                    body.assign(tmp);
                }
            }
        }
        esp_http_client_close(client);
        esp_http_client_cleanup(client);

        if (err == ESP_OK && status == 200 && !body.empty()) {
            ESP_LOGI(TAG, "cmd payload: %s", body.c_str());
            ProcessCmdPayload(body.c_str());
        } else if (err == ESP_OK && status == 204) {
            // no command
        } else {
            ESP_LOGD(TAG, "cmd poll err=%s status=%d", esp_err_to_name(err), status);
            vTaskDelay(pdMS_TO_TICKS(1500));
        }
    }
}

void adhd_remote_cmd_start(void) {
    static bool started = false;
    if (started) {
        ESP_LOGI(TAG, "remote cmd task already running, skip");
        return;
    }
    if (strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        ESP_LOGW(TAG, "ADHD_MONITOR_CMD_HOST empty, skip remote cmd");
        return;
    }
    // Echo where we'll announce so the next ESP32.txt makes it obvious
    // the build actually compiled the announce path. The previous build
    // silently no-op'd because CONFIG_ADHD_MONITOR_REMOTE_CMD was n in a
    // stale sdkconfig — that case now logs "(via BYPASS_OTA fallback)".
    ESP_LOGI(TAG, "remote cmd long-poll task → http://%s:%d/device/<id>/cmd",
             CONFIG_ADHD_MONITOR_CMD_HOST, CONFIG_ADHD_MONITOR_CMD_PORT);
    started = true;
    BaseType_t r = xTaskCreate(RemoteCmdTask, "adhd_remote_cmd", 8192, nullptr, 3, nullptr);
    if (r != pdPASS) {
        ESP_LOGE(TAG, "xTaskCreate failed (%d), announce path is dead", (int)r);
        started = false;
    }
}

#else

void adhd_remote_cmd_announce_sync_once(void) {}
void adhd_remote_cmd_start(void) {}

#endif
