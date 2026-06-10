#include "adhd_remote_cmd.h"
// Must appear before any `#if CONFIG_*`: this .cc does not include other IDF
// headers first, so without sdkconfig.h all CONFIG_ADHD_MONITOR_* macros are
// undefined and GCC treats `#if UNDEFINED` as 0 — the entire Path A body is
// stripped and announce/long-poll become empty stubs (no `adhd_cmd` logs).
#include "sdkconfig.h"

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
#include <cstdint>
#include <cJSON.h>
#include <esp_http_client.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_mac.h>
#include <memory>
#include <vector>

#include "application.h"
#include "board.h"
#include "display/lvgl_display/lvgl_image.h"
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

static void LogPathAIdentity() {
    uint8_t mac[6] = {0};
    esp_err_t e = esp_read_mac(mac, ESP_MAC_WIFI_STA);
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "identity: failed to read STA MAC: %s", esp_err_to_name(e));
        return;
    }
    char mac_full[20] = {0};
    snprintf(mac_full, sizeof(mac_full), "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    char device_id[16] = {0};
    snprintf(device_id, sizeof(device_id), "%02X%02X%02X%02X",
             mac[2], mac[3], mac[4], mac[5]);
    ESP_LOGI(TAG, "identity: sta_mac=%s device_id=%s", mac_full, device_id);
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

static bool DownloadAndShowPreviewImage(const std::string& url) {
    if (url.empty()) {
        return false;
    }
    auto http = Board::GetInstance().GetNetwork()->CreateHttp(3);
    ESP_LOGI(TAG, "autism image download: %s", url.c_str());
    if (!http->Open("GET", url)) {
        ESP_LOGW(TAG, "autism image open failed: %s", url.c_str());
        return false;
    }
    int status_code = http->GetStatusCode();
    if (status_code != 200) {
        ESP_LOGW(TAG, "autism image http status=%d url=%s", status_code, url.c_str());
        http->Close();
        return false;
    }
    size_t content_length = http->GetBodyLength();
    if (content_length == 0 || content_length > 256 * 1024) {
        ESP_LOGW(TAG, "autism image invalid length=%u", (unsigned)content_length);
        http->Close();
        return false;
    }
    char* data = static_cast<char*>(heap_caps_malloc(content_length, MALLOC_CAP_8BIT));
    if (data == nullptr) {
        ESP_LOGW(TAG, "autism image malloc failed length=%u", (unsigned)content_length);
        http->Close();
        return false;
    }
    size_t total_read = 0;
    while (total_read < content_length) {
        int ret = http->Read(data + total_read, content_length - total_read);
        if (ret < 0) {
            ESP_LOGW(TAG, "autism image read failed: %s", url.c_str());
            heap_caps_free(data);
            http->Close();
            return false;
        }
        if (ret == 0) {
            break;
        }
        total_read += ret;
    }
    http->Close();
    if (total_read == 0) {
        heap_caps_free(data);
        return false;
    }
    try {
        auto image = std::make_unique<LvglAllocatedImage>(data, total_read);
        Board::GetInstance().GetDisplay()->SetPreviewImage(std::move(image));
        ESP_LOGI(TAG, "autism image shown bytes=%u", (unsigned)total_read);
        return true;
    } catch (...) {
        ESP_LOGW(TAG, "autism image decode/show failed");
        heap_caps_free(data);
        return false;
    }
}

static void AutismImageSequenceTask(void* arg) {
    auto* urls = static_cast<std::vector<std::string>*>(arg);
    if (urls == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    for (const auto& url : *urls) {
        DownloadAndShowPreviewImage(url);
        vTaskDelay(pdMS_TO_TICKS(4500));
    }
    delete urls;
    vTaskDelete(nullptr);
}

static void StartAutismImageSequence(cJSON* images) {
    if (!cJSON_IsObject(images)) {
        return;
    }
    auto* urls = new std::vector<std::string>();
    cJSON* child = nullptr;
    cJSON_ArrayForEach(child, images) {
        if (cJSON_IsString(child) && child->valuestring && strlen(child->valuestring) > 0) {
            urls->push_back(child->valuestring);
        }
    }
    if (urls->empty()) {
        delete urls;
        return;
    }
    ESP_LOGI(TAG, "autism image sequence start count=%u", (unsigned)urls->size());
    BaseType_t tr = xTaskCreate(AutismImageSequenceTask, "autism_img", 8192, urls, 3, nullptr);
    if (tr != pdPASS) {
        ESP_LOGW(TAG, "autism_img task create failed");
        delete urls;
    }
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
    LogPathAIdentity();
    DoAnnounceOnce();
}

bool adhd_post_autism_need_event(const char* card_slug, const char* label, const char* voice_text) {
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4 || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        return false;
    }
    cJSON* root = cJSON_CreateObject();
    if (!root) {
        return false;
    }
    if (card_slug && card_slug[0]) {
        cJSON_AddStringToObject(root, "card_slug", card_slug);
    } else {
        cJSON_AddStringToObject(root, "card_slug", "");
    }
    cJSON_AddStringToObject(root, "label", label ? label : "");
    const char* vt = (voice_text && voice_text[0]) ? voice_text : label;
    cJSON_AddStringToObject(root, "voice_text", vt ? vt : "");
    char* out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!out) {
        return false;
    }
    std::string body(out);
    cJSON_free(out);
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/" + id +
                       "/autism/need-event";
    const bool ok = HttpPostJson(url, body);
    if (!ok) {
        ESP_LOGW(TAG, "autism need-event POST failed");
    }
    return ok;
}

static void AutismTrainingAckTask(void* arg) {
    const int sid = static_cast<int>(reinterpret_cast<intptr_t>(arg));
    if (sid <= 0) {
        vTaskDelete(nullptr);
        return;
    }
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4 || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        vTaskDelete(nullptr);
        return;
    }
    cJSON* root = cJSON_CreateObject();
    if (!root) {
        vTaskDelete(nullptr);
        return;
    }
    cJSON_AddNumberToObject(root, "session_id", sid);
    cJSON_AddStringToObject(root, "phase", "robot_received");
    cJSON_AddStringToObject(root, "scene", "training");
    cJSON_AddStringToObject(root, "ts", "");
    char* out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!out) {
        vTaskDelete(nullptr);
        return;
    }
    std::string body(out);
    cJSON_free(out);
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/" + id +
                       "/autism/training-event";
    (void)HttpPostJson(url, body);
    vTaskDelete(nullptr);
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
    } else if (strcmp(act, "autism_session") == 0) {
        cJSON* sj = cJSON_GetObjectItem(root, "session_json");
        if (!cJSON_IsString(sj) || !sj->valuestring) {
            ESP_LOGW(TAG, "autism_session: missing session_json");
            return;
        }
        cJSON* session = cJSON_Parse(sj->valuestring);
        if (!session) {
            ESP_LOGW(TAG, "autism_session: invalid JSON");
            return;
        }
        cJSON* kind = cJSON_GetObjectItem(session, "kind");
        const char* k = cJSON_IsString(kind) ? kind->valuestring : "";
        if (strcmp(k, "training_start") == 0) {
            StartAutismImageSequence(cJSON_GetObjectItem(session, "images"));
            cJSON* tts = cJSON_GetObjectItem(session, "tts_intro");
            std::string line(reinterpret_cast<const char*>(u8"\u6211\u4eec\u4e00\u8d77\u6765\u505a\u4e00\u4e2a\u7ec3\u4e60\u5427"));
            if (cJSON_IsString(tts) && tts->valuestring && strlen(tts->valuestring) > 0) {
                line = tts->valuestring;
            }
            cJSON* sidn = cJSON_GetObjectItem(session, "session_id");
            const int sid = cJSON_IsNumber(sidn) ? sidn->valueint : 0;
            Application::GetInstance().Schedule([line]() {
                Application::GetInstance().WakeWordInvoke(line);
            });
            if (sid > 0) {
                BaseType_t tr = xTaskCreate(AutismTrainingAckTask, "autism_ack", 8192,
                                            reinterpret_cast<void*>(static_cast<intptr_t>(sid)), 3, nullptr);
                if (tr != pdPASS) {
                    ESP_LOGW(TAG, "autism_ack task create failed");
                }
            }
        } else if (strcmp(k, "daily_plan") == 0) {
            StartAutismImageSequence(cJSON_GetObjectItem(session, "images"));
            cJSON* slots = cJSON_GetObjectItem(session, "slots");
            std::string line(reinterpret_cast<const char*>(
                u8"\u4eca\u5929\u7684\u5b89\u6392\u5df2\u540c\u6b65\uff0c\u6211\u4eec\u4e00\u8d77\u770b\u770b\u5427"));
            if (cJSON_IsArray(slots) && cJSON_GetArraySize(slots) > 0) {
                cJSON* first = cJSON_GetArrayItem(slots, 0);
                cJSON* tt = cJSON_GetObjectItem(first, "tts");
                if (cJSON_IsString(tt) && tt->valuestring && strlen(tt->valuestring) > 0) {
                    line = tt->valuestring;
                }
            }
            ESP_LOGI(TAG, "autism_session daily_plan → WakeWordInvoke len=%u", (unsigned)line.size());
            Application::GetInstance().Schedule([line]() {
                Application::GetInstance().WakeWordInvoke(line);
            });
        } else {
            ESP_LOGW(TAG, "autism_session: unknown kind %s", k);
        }
        cJSON_Delete(session);
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
bool adhd_post_autism_need_event(const char*, const char*, const char*) {
    return false;
}

#endif
