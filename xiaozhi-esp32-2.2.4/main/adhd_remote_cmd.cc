#include "adhd_remote_cmd.h"

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
#include <cstring>
#include <string>
#include <esp_log.h>
#endif

#if CONFIG_ADHD_MONITOR_BYPASS_OTA
#include "settings.h"
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD
#include <cctype>
#include <cJSON.h>
#include <esp_http_client.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include "application.h"
#include "system_info.h"
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
static const char* TAG = "adhd_cmd";
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD
static std::string MacNoColonUpper() {
    std::string mac = SystemInfo::GetMacAddress();
    std::string out;
    out.reserve(12);
    for (char c : mac) {
        if (c == ':' || c == '-') {
            continue;
        }
        out.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
    }
    return out;
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

#if CONFIG_ADHD_MONITOR_REMOTE_CMD

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

static void AnnounceOnce() {
    const std::string id = MacNoColonUpper();
    if (id.size() < 4) {
        return;
    }
    std::string body = std::string("{\"device_id\":\"") + id + "\",\"kind\":\"xiaozhi\"}";
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/esp32/announce";
    if (!HttpPostJson(url, body)) {
        ESP_LOGW(TAG, "announce POST failed");
    } else {
        ESP_LOGI(TAG, "announce ok device_id=%s", id.c_str());
    }
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
    vTaskDelay(pdMS_TO_TICKS(5000));
    AnnounceOnce();
    const std::string id = MacNoColonUpper();
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
        return;
    }
    if (strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        ESP_LOGW(TAG, "ADHD_MONITOR_CMD_HOST empty, skip remote cmd");
        return;
    }
    started = true;
    xTaskCreate(RemoteCmdTask, "adhd_remote_cmd", 8192, nullptr, 3, nullptr);
}

#else

void adhd_remote_cmd_start(void) {}

#endif
