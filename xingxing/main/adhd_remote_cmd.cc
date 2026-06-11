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
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <esp_mac.h>
#include <algorithm>
#include <ctime>
#include <memory>
#include <vector>

#include "application.h"
#include "board.h"
#include "action_cards.h"
#include "lvgl_display.h"
#include "display/lvgl_display/lvgl_image.h"
#if CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING
#include "adhd_prov_ble.h"
#endif
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
static const char* TAG = "adhd_cmd";

struct AutismDailyPlanSlot {
    int minute_of_day = -1;
    std::string time_text;
    std::string tts;
    std::vector<std::string> option_labels;
    std::vector<std::string> image_urls;
    int last_fired_yday = -1;
};

struct AutismChoiceItem {
    std::string label;
    std::string image_url;
};

struct AutismChoiceContext {
    bool active = false;
    int current_index = -1;
    int generation = 0;
    int session_id = 0;
    std::string scene;
    std::string kind;
    std::string source;
    std::string slot_time;
    std::vector<AutismChoiceItem> items;
};

static SemaphoreHandle_t g_daily_plan_mutex = nullptr;
static TaskHandle_t g_daily_plan_task = nullptr;
static std::vector<AutismDailyPlanSlot> g_daily_plan_slots;
static SemaphoreHandle_t g_choice_mutex = nullptr;
static AutismChoiceContext g_choice_context;
static int g_choice_generation = 0;
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

static void EnsureAutismChoiceMutex() {
    if (g_choice_mutex == nullptr) {
        g_choice_mutex = xSemaphoreCreateMutex();
    }
}

/** 行动卡片全屏层在 preview_image_ 之上，不退出则训练图永远被挡住。 */
static void ExitActionCardsIfCoveringPreview() {
    if (ActionCards::GetInstance().IsActive()) {
        ESP_LOGI(TAG, "leaving action cards (fullscreen was covering preview)");
        ActionCards::GetInstance().Toggle();
    }
}

static bool IsChoiceGenerationActive(int generation) {
    if (generation <= 0) {
        return true;
    }
    bool active = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        active = g_choice_context.active && g_choice_context.generation == generation;
        xSemaphoreGive(g_choice_mutex);
    }
    return active;
}

static void VisualChoiceFallbackRestoreTask(void*) {
    vTaskDelay(pdMS_TO_TICKS(30000));
    bool any_active = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        any_active = g_choice_context.active;
        xSemaphoreGive(g_choice_mutex);
    }
    if (!any_active) {
        ESP_LOGI(TAG, "visual choice fallback restore default listening");
        Application::GetInstance().SetVisualChoiceMode(false);
    }
    vTaskDelete(nullptr);
}

static void ScheduleVisualChoiceFallbackRestore() {
    (void)xTaskCreate(
        VisualChoiceFallbackRestoreTask,
        "choice_restore",
        3072,
        nullptr,
        2,
        nullptr
    );
}

static bool PostAutismTrainingChoiceEvent(const AutismChoiceContext& ctx, int index, const std::string& label) {
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4 || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        return false;
    }
    cJSON* root = cJSON_CreateObject();
    if (!root) {
        return false;
    }
    cJSON_AddStringToObject(root, "scene", ctx.scene.empty() ? "unknown" : ctx.scene.c_str());
    cJSON_AddStringToObject(root, "phase", "image_confirmed");
    if (ctx.session_id > 0) {
        cJSON_AddNumberToObject(root, "session_id", ctx.session_id);
    }
    cJSON* payload = cJSON_CreateObject();
    if (payload != nullptr) {
        cJSON_AddStringToObject(payload, "kind", ctx.kind.c_str());
        cJSON_AddStringToObject(payload, "source", ctx.source.c_str());
        cJSON_AddStringToObject(payload, "slot_time", ctx.slot_time.c_str());
        cJSON_AddStringToObject(payload, "label", label.c_str());
        cJSON_AddNumberToObject(payload, "option_index", index);
        cJSON_AddItemToObject(root, "payload", payload);
    }
    char* out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!out) {
        return false;
    }
    std::string body(out);
    cJSON_free(out);
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/" + id +
                       "/autism/training-event";
    const bool ok = HttpPostJson(url, body);
    if (!ok) {
        ESP_LOGW(TAG, "autism training choice event POST failed");
    }
    return ok;
}

static bool PostXiaozhiOpeningHint(const std::string& opening, const std::string& context) {
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4 || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0 || opening.empty()) {
        return false;
    }
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "opening_line", opening.c_str());
    cJSON_AddStringToObject(root, "context", context.c_str());
    char* out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (out == nullptr) {
        return false;
    }
    std::string body(out);
    cJSON_free(out);
    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                       std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/device/" + id +
                       "/xiaozhi/opening-hint";
    const bool ok = HttpPostJson(url, body);
    if (!ok) {
        ESP_LOGW(TAG, "xiaozhi opening hint POST failed");
    }
    return ok;
}

static bool DownloadAndShowPreviewImage(const std::string& url, int choice_generation = 0) {
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
    const size_t content_length = http->GetBodyLength();
    const size_t max_image_bytes = 512 * 1024;
    if (content_length > max_image_bytes) {
        ESP_LOGW(TAG, "autism image too large length=%u", (unsigned)content_length);
        http->Close();
        return false;
    }
    ESP_LOGI(TAG, "autism image http ok body_len=%u", (unsigned)content_length);

    std::vector<uint8_t> dynamic_data;
    char* data = nullptr;
    size_t capacity = content_length;
    if (capacity > 0) {
        data = static_cast<char*>(heap_caps_malloc(capacity, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (data == nullptr) {
            data = static_cast<char*>(heap_caps_malloc(capacity, MALLOC_CAP_8BIT));
        }
        if (data == nullptr) {
            ESP_LOGW(TAG, "autism image malloc failed length=%u", (unsigned)capacity);
            http->Close();
            return false;
        }
    } else {
        dynamic_data.reserve(64 * 1024);
    }
    size_t total_read = 0;
    while (content_length == 0 || total_read < content_length) {
        char chunk[4096];
        char* dst = data != nullptr ? data + total_read : chunk;
        const size_t want = data != nullptr
            ? std::min(sizeof(chunk), content_length - total_read)
            : sizeof(chunk);
        int ret = http->Read(dst, want);
        if (ret < 0) {
            ESP_LOGW(TAG, "autism image read failed: %s", url.c_str());
            if (data != nullptr) {
                heap_caps_free(data);
            }
            http->Close();
            return false;
        }
        if (ret == 0) {
            break;
        }
        if (data == nullptr) {
            if (total_read + static_cast<size_t>(ret) > max_image_bytes) {
                ESP_LOGW(TAG, "autism image chunked too large >%u", (unsigned)max_image_bytes);
                http->Close();
                return false;
            }
            dynamic_data.insert(dynamic_data.end(), chunk, chunk + ret);
        }
        total_read += ret;
    }
    http->Close();
    if (total_read == 0) {
        if (data != nullptr) {
            heap_caps_free(data);
        }
        return false;
    }
    if (content_length > 0 && total_read != content_length) {
        ESP_LOGW(TAG, "autism image incomplete read %u/%u", (unsigned)total_read, (unsigned)content_length);
        heap_caps_free(data);
        return false;
    }
    if (data == nullptr) {
        data = static_cast<char*>(heap_caps_malloc(total_read, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (data == nullptr) {
            data = static_cast<char*>(heap_caps_malloc(total_read, MALLOC_CAP_8BIT));
        }
        if (data == nullptr) {
            ESP_LOGW(TAG, "autism image malloc failed after chunked read length=%u", (unsigned)total_read);
            return false;
        }
        memcpy(data, dynamic_data.data(), total_read);
    }
    ESP_LOGI(TAG, "autism image downloaded bytes=%u", (unsigned)total_read);
    if (total_read >= 8) {
        const auto* u = reinterpret_cast<const uint8_t*>(data);
        ESP_LOGI(TAG, "autism image head %02x%02x%02x%02x (expect 89504e47 for PNG)",
                 u[0], u[1], u[2], u[3]);
    }
    if (!IsChoiceGenerationActive(choice_generation)) {
        ESP_LOGI(TAG, "autism image skip stale generation=%d", choice_generation);
        heap_caps_free(data);
        return false;
    }
    ExitActionCardsIfCoveringPreview();
    auto* lvgl = dynamic_cast<LvglDisplay*>(Board::GetInstance().GetDisplay());
    if (lvgl == nullptr) {
        ESP_LOGW(TAG, "autism image: display is not LvglDisplay, skip preview");
        heap_caps_free(data);
        return false;
    }
    try {
        auto image = std::make_unique<LvglAllocatedImage>(data, total_read);
        lvgl->SetPreviewImage(std::move(image));
        ESP_LOGI(TAG, "autism image SetPreviewImage ok bytes=%u", (unsigned)total_read);
        return true;
    } catch (...) {
        ESP_LOGW(TAG, "autism image decode/show failed");
        heap_caps_free(data);
        return false;
    }
}

static int ParseHourMinuteToMinuteOfDay(const char* text) {
    if (text == nullptr) {
        return -1;
    }
    int hh = -1;
    int mm = -1;
    if (sscanf(text, "%d:%d", &hh, &mm) != 2) {
        return -1;
    }
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) {
        return -1;
    }
    return hh * 60 + mm;
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

static void AutismChoiceSequenceTask(void* arg) {
    auto* ctx = static_cast<AutismChoiceContext*>(arg);
    if (ctx == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    EnsureAutismChoiceMutex();
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        g_choice_context = *ctx;
        g_choice_context.active = true;
        g_choice_context.current_index = 0;
        xSemaphoreGive(g_choice_mutex);
    }
    const int64_t deadline_us = esp_timer_get_time() + 60LL * 1000LL * 1000LL;
    size_t i = 0;
    while (esp_timer_get_time() < deadline_us) {
        bool still_active = true;
        if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
            still_active = g_choice_context.active && g_choice_context.generation == ctx->generation;
            if (still_active) {
                g_choice_context.current_index = static_cast<int>(i);
            }
            xSemaphoreGive(g_choice_mutex);
        }
        if (!still_active) {
            break;
        }
        DownloadAndShowPreviewImage(ctx->items[i].image_url, ctx->generation);
        vTaskDelay(pdMS_TO_TICKS(4500));
        i = (i + 1) % ctx->items.size();
    }
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        if (g_choice_context.active && g_choice_context.generation == ctx->generation) {
            ESP_LOGI(TAG, "autism choice sequence timeout scene=%s", ctx->scene.c_str());
            g_choice_context.active = false;
            Application::GetInstance().SetVisualChoiceMode(false);
        }
        xSemaphoreGive(g_choice_mutex);
    }
    delete ctx;
    vTaskDelete(nullptr);
}

static void StartAutismImageSequenceUrls(std::vector<std::string>* urls) {
    if (urls == nullptr || urls->empty()) {
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

static void StartAutismChoiceSequence(AutismChoiceContext* ctx) {
    if (ctx == nullptr || ctx->items.empty()) {
        delete ctx;
        return;
    }
    Application::GetInstance().SetVisualChoiceMode(true);
    EnsureAutismChoiceMutex();
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        g_choice_generation++;
        ctx->generation = g_choice_generation;
        g_choice_context.active = false;
        xSemaphoreGive(g_choice_mutex);
    }
    ESP_LOGI(TAG, "autism choice sequence start scene=%s count=%u",
             ctx->scene.c_str(), (unsigned)ctx->items.size());
    BaseType_t tr = xTaskCreate(AutismChoiceSequenceTask, "autism_choice", 8192, ctx, 3, nullptr);
    if (tr != pdPASS) {
        ESP_LOGW(TAG, "autism_choice task create failed");
        delete ctx;
    }
}


static void FireAutismDailyPlanSlot(const AutismDailyPlanSlot& slot) {
    ExitActionCardsIfCoveringPreview();
    if (!slot.image_urls.empty()) {
        auto* ctx = new AutismChoiceContext();
        ctx->scene = "daily_plan";
        ctx->kind = "daily_plan";
        ctx->source = "daily_plan";
        ctx->slot_time = slot.time_text;
        for (size_t i = 0; i < slot.image_urls.size(); ++i) {
            AutismChoiceItem item;
            item.image_url = slot.image_urls[i];
            item.label = i < slot.option_labels.size() ? slot.option_labels[i] : "";
            ctx->items.push_back(std::move(item));
        }
        StartAutismChoiceSequence(ctx);
    }
    const std::string line = slot.tts.empty()
        ? std::string(reinterpret_cast<const char*>(u8"\u65f6\u95f4\u5230\u5566\uff0c\u6211\u4eec\u6765\u9009\u4e00\u9009\u5427"))
        : slot.tts;
    ESP_LOGI(TAG, "daily_plan fire %s images=%u", slot.time_text.c_str(), (unsigned)slot.image_urls.size());
    (void)PostXiaozhiOpeningHint(
        line,
        std::string(reinterpret_cast<const char*>(u8"\u8fd9\u662f\u8ba1\u5212\u8868\u5230\u70b9\u89e6\u53d1\u7684\u4e3b\u52a8\u63d0\u95ee\u3002\u8bf7\u53ea\u64ad\u653e\u8fd9\u53e5\u8bdd\uff0c\u7136\u540e\u7b49\u5f85\u5b69\u5b50\u9009\u62e9\u56fe\u7247\u6216\u8bed\u97f3\u56de\u7b54\u3002"))
    );
    Application::GetInstance().Schedule([line]() {
        Application::GetInstance().SubmitChildTextInput(line);
    });
}

static void DailyPlanSchedulerTask(void*) {
    while (true) {
        time_t now = time(nullptr);
        struct tm* tm_now = localtime(&now);
        if (tm_now != nullptr && tm_now->tm_year >= 120) {
            const int minute_now = tm_now->tm_hour * 60 + tm_now->tm_min;
            std::vector<AutismDailyPlanSlot> to_fire;
            if (g_daily_plan_mutex != nullptr && xSemaphoreTake(g_daily_plan_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
                for (auto& slot : g_daily_plan_slots) {
                    if (slot.minute_of_day == minute_now && slot.last_fired_yday != tm_now->tm_yday) {
                        slot.last_fired_yday = tm_now->tm_yday;
                        to_fire.push_back(slot);
                    }
                }
                xSemaphoreGive(g_daily_plan_mutex);
            }
            for (const auto& slot : to_fire) {
                FireAutismDailyPlanSlot(slot);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(15000));
    }
}

static void EnsureDailyPlanSchedulerStarted() {
    if (g_daily_plan_mutex == nullptr) {
        g_daily_plan_mutex = xSemaphoreCreateMutex();
    }
    if (g_daily_plan_task == nullptr) {
        BaseType_t tr = xTaskCreate(DailyPlanSchedulerTask, "daily_plan", 8192, nullptr, 3, &g_daily_plan_task);
        if (tr != pdPASS) {
            ESP_LOGW(TAG, "daily_plan scheduler task create failed");
            g_daily_plan_task = nullptr;
        }
    }
}

static void StoreAutismDailyPlan(cJSON* session) {
    cJSON* slots = cJSON_GetObjectItem(session, "slots");
    cJSON* images = cJSON_GetObjectItem(session, "images");
    if (!cJSON_IsArray(slots)) {
        ESP_LOGW(TAG, "daily_plan missing slots");
        return;
    }
    std::vector<AutismDailyPlanSlot> parsed;
    const int count = cJSON_GetArraySize(slots);
    for (int i = 0; i < count; ++i) {
        cJSON* item = cJSON_GetArrayItem(slots, i);
        if (!cJSON_IsObject(item)) {
            continue;
        }
        cJSON* time = cJSON_GetObjectItem(item, "time");
        cJSON* tts = cJSON_GetObjectItem(item, "tts");
        const char* time_text = cJSON_IsString(time) ? time->valuestring : "";
        const int minute = ParseHourMinuteToMinuteOfDay(time_text);
        if (minute < 0) {
            ESP_LOGW(TAG, "daily_plan skip invalid time: %s", time_text ? time_text : "(null)");
            continue;
        }
        AutismDailyPlanSlot slot;
        slot.minute_of_day = minute;
        slot.time_text = time_text ? time_text : "";
        if (cJSON_IsString(tts) && tts->valuestring) {
            slot.tts = tts->valuestring;
        }
        cJSON* options = cJSON_GetObjectItem(item, "options");
        const int opt_count = cJSON_IsArray(options) ? cJSON_GetArraySize(options) : 4;
        for (int j = 0; j < opt_count; ++j) {
            char key[24];
            snprintf(key, sizeof(key), "s%d_o%d", i, j);
            cJSON* url = cJSON_IsObject(images) ? cJSON_GetObjectItem(images, key) : nullptr;
            if (cJSON_IsString(url) && url->valuestring && strlen(url->valuestring) > 0) {
                cJSON* opt = cJSON_IsArray(options) ? cJSON_GetArrayItem(options, j) : nullptr;
                slot.option_labels.push_back(cJSON_IsString(opt) && opt->valuestring ? opt->valuestring : "");
                slot.image_urls.push_back(url->valuestring);
            }
        }
        parsed.push_back(std::move(slot));
    }
    if (parsed.empty()) {
        ESP_LOGW(TAG, "daily_plan parsed no valid slots");
        return;
    }

    EnsureDailyPlanSchedulerStarted();
    if (g_daily_plan_mutex != nullptr && xSemaphoreTake(g_daily_plan_mutex, pdMS_TO_TICKS(1000)) == pdTRUE) {
        g_daily_plan_slots = std::move(parsed);
        xSemaphoreGive(g_daily_plan_mutex);
        ESP_LOGI(TAG, "daily_plan stored slots=%u; waiting for scheduled time", (unsigned)g_daily_plan_slots.size());
    } else {
        ESP_LOGW(TAG, "daily_plan store failed: mutex unavailable");
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

bool adhd_confirm_autism_choice(void) {
    EnsureAutismChoiceMutex();
    AutismChoiceContext snapshot;
    int idx = -1;
    std::string label;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(200)) == pdTRUE) {
        if (g_choice_context.active &&
            g_choice_context.current_index >= 0 &&
            g_choice_context.current_index < static_cast<int>(g_choice_context.items.size())) {
            snapshot = g_choice_context;
            idx = g_choice_context.current_index;
            label = g_choice_context.items[idx].label;
            g_choice_context.active = false;
            g_choice_generation++;
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (idx < 0) {
        return false;
    }
    ESP_LOGI(TAG, "autism choice confirmed scene=%s idx=%d label=%s",
             snapshot.scene.c_str(), idx, label.c_str());
    (void)PostAutismTrainingChoiceEvent(snapshot, idx, label);
    ScheduleVisualChoiceFallbackRestore();
    const std::string line = label.empty()
        ? std::string(reinterpret_cast<const char*>(u8"\u6211\u5df2\u7ecf\u505a\u51fa\u4e86\u9009\u62e9"))
        : std::string(reinterpret_cast<const char*>(u8"\u6211\u9009\u62e9\u4e86")) + label;
    Application::GetInstance().Schedule([line]() {
        Application::GetInstance().SubmitChildTextInput(line);
    });
    return true;
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
            ExitActionCardsIfCoveringPreview();
            cJSON* sidn = cJSON_GetObjectItem(session, "session_id");
            const int sid = cJSON_IsNumber(sidn) ? sidn->valueint : 0;
            cJSON* scene = cJSON_GetObjectItem(session, "scene_id");
            cJSON* options = cJSON_GetObjectItem(session, "options");
            cJSON* images = cJSON_GetObjectItem(session, "images");
            auto* ctx = new AutismChoiceContext();
            ctx->scene = cJSON_IsString(scene) && scene->valuestring ? scene->valuestring : "training";
            ctx->kind = "training_start";
            ctx->source = "child_training";
            ctx->session_id = sid;
            const int opt_count = cJSON_IsArray(options) ? cJSON_GetArraySize(options) : 0;
            for (int i = 0; i < opt_count; ++i) {
                char key[16];
                snprintf(key, sizeof(key), "o%d", i);
                cJSON* url = cJSON_IsObject(images) ? cJSON_GetObjectItem(images, key) : nullptr;
                if (!cJSON_IsString(url) || !url->valuestring || strlen(url->valuestring) == 0) {
                    continue;
                }
                cJSON* opt = cJSON_GetArrayItem(options, i);
                AutismChoiceItem item;
                item.label = cJSON_IsString(opt) && opt->valuestring ? opt->valuestring : "";
                item.image_url = url->valuestring;
                ctx->items.push_back(std::move(item));
            }
            ESP_LOGI(TAG, "autism_session training_start scene=%s image_urls=%u session_id=%d",
                     ctx->scene.c_str(), (unsigned)ctx->items.size(), sid);
            if (ctx->items.empty()) {
                ESP_LOGW(TAG, "autism_session training_start: no image URLs in payload (check server images + public URL)");
                delete ctx;
            } else {
                StartAutismChoiceSequence(ctx);
            }
            cJSON* tts = cJSON_GetObjectItem(session, "tts_intro");
            std::string line(reinterpret_cast<const char*>(u8"\u6211\u4eec\u4e00\u8d77\u6765\u505a\u4e00\u4e2a\u7ec3\u4e60\u5427"));
            if (cJSON_IsString(tts) && tts->valuestring && strlen(tts->valuestring) > 0) {
                line = tts->valuestring;
            }
            Application::GetInstance().Schedule([line]() {
                Application::GetInstance().SubmitChildTextInput(line);
            });
            if (sid > 0) {
                BaseType_t tr = xTaskCreate(AutismTrainingAckTask, "autism_ack", 8192,
                                            reinterpret_cast<void*>(static_cast<intptr_t>(sid)), 3, nullptr);
                if (tr != pdPASS) {
                    ESP_LOGW(TAG, "autism_ack task create failed");
                }
            }
        } else if (strcmp(k, "daily_plan") == 0) {
            StoreAutismDailyPlan(session);
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
bool adhd_confirm_autism_choice(void) {
    return false;
}

#endif
