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
#include <functional>
#include <memory>
#include <vector>
#include <atomic>

#include "application.h"
#include "board.h"
#include "action_cards.h"
#include "action_cards/choice_hint_images_generated.h"
#include "lvgl_display.h"
#include "display/lvgl_display/lvgl_image.h"
#if CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING
#include "adhd_prov_ble.h"
#endif
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
static const char* TAG = "adhd_cmd";

/// Run UI mutation on the Application main thread (LVGL-safe).
static void UiSyncRun(std::function<void()> fn) {
    SemaphoreHandle_t sem = xSemaphoreCreateBinary();
    if (sem == nullptr) {
        fn();
        return;
    }
    auto* heap_fn = new std::function<void()>(std::move(fn));
    Application::GetInstance().Schedule([heap_fn, sem]() {
        (*heap_fn)();
        delete heap_fn;
        xSemaphoreGive(sem);
    });
    (void)xSemaphoreTake(sem, pdMS_TO_TICKS(8000));
    vSemaphoreDelete(sem);
}

struct AutismDailyPlanSlot {
    int minute_of_day = -1;
    std::string time_text;
    std::string tts;
    std::vector<std::string> option_labels;
    std::vector<std::string> image_urls;
    std::vector<std::string> audio_urls;
    std::vector<std::string> praise_audio_urls;
    /// 该时段「长时间未选图」鼓励语 OGG（与日常训练同源话术，服务端预生成）。
    std::string choice_timeout_audio_url;
    /// 该时段开场白 OGG（服务端 edge-tts 预生成）；到点直接外放，不走聊天链路。
    std::string intro_audio_url;
    int last_fired_yday = -1;
    /// 每次服务端下发新计划表递增；用于丢弃旧 intro/选图任务与「表已换」检测。
    int plan_table_revision = 0;
};

struct AutismChoiceItem {
    std::string label;
    std::string image_url;
    std::string audio_url;
    /// 选中后要外放的鼓励语 OGG（服务端 edge-tts 预生成，确定性本地播放）。
    std::string praise_audio_url;
};

struct AutismChoiceContext {
    bool active = false;
    bool display_dimmed = false;
    int current_index = -1;
    int activity_seq = 0;
    int generation = 0;
    int session_id = 0;
    /// 仅 daily_plan：与 StoreAutismDailyPlan 写入的 revision 一致，用于丢弃过期 intro。
    int plan_table_revision = 0;
    /// 仅 child_training：每次新的 training_start 递增，用于丢弃过期 intro。
    int training_cmd_revision = 0;
    std::string scene;
    std::string kind;
    std::string source;
    std::string slot_time;
    std::string focus_label;
    /// 开场白文案（服务端 tts / 计划表 slot.tts），用于上报 intro_played 与家长端 digest。
    std::string intro_tts_text;
    /// 选图长时间无操作后的鼓励 OGG（服务端预生成）。
    std::string choice_timeout_audio_url;
    std::vector<AutismChoiceItem> items;
};

static SemaphoreHandle_t g_daily_plan_mutex = nullptr;
static TaskHandle_t g_daily_plan_task = nullptr;
static std::vector<AutismDailyPlanSlot> g_daily_plan_slots;
static int g_daily_plan_store_revision = 0;
static SemaphoreHandle_t g_choice_mutex = nullptr;
static AutismChoiceContext g_choice_context;
static int g_choice_generation = 0;
static int g_autism_training_cmd_revision = 0;
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
struct ChoicePreviewRequest;
static bool DownloadAndShowPreviewImage(const std::string& url, int choice_generation,
                                        const ChoicePreviewRequest* binding = nullptr);

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

#if HAVE_LVGL
static std::atomic<bool> g_path_a_intro_suppresses_kids{false};
struct PathAIntroKidsGuard {
    PathAIntroKidsGuard() { g_path_a_intro_suppresses_kids.store(true); }
    ~PathAIntroKidsGuard() { g_path_a_intro_suppresses_kids.store(false); }
};
#endif

bool adhd_path_a_intro_suppresses_kids(void) {
#if HAVE_LVGL
    return g_path_a_intro_suppresses_kids.load();
#else
    return false;
#endif
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
        return false;
    }
    bool active = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        active = g_choice_context.active && g_choice_context.generation == generation;
        xSemaphoreGive(g_choice_mutex);
    }
    return active;
}

static void RestoreAutismChoiceBacklight() {
    Backlight* bl = Board::GetInstance().GetBacklight();
    if (bl != nullptr) {
        bl->RestoreBrightness();
    }
}

/// 结束选图省电态：恢复背光并点亮面板（部分板子在省电时会 disp_off）。
static void RestoreAutismChoiceDisplayFully() {
    RestoreAutismChoiceBacklight();
    Application::GetInstance().Schedule([]() {
        Board::GetInstance().SetApplicationSleepDisplayDimmed(false);
    });
}

static void DimAutismChoiceBacklight() {
    Backlight* bl = Board::GetInstance().GetBacklight();
    if (bl != nullptr) {
        bl->SetBrightness(0);
    }
}

/// 选图空闲 60s：仅关背光 + 面板显示（SetApplicationSleepDisplayDimmed）。
/// 不调用 EnterSleepPowerSaveMode：不关音频会话、不降 WiFi、不深睡；长轮询与计划表到点仍依赖 STA 在线。
static void DimAutismChoiceIdleSleepDisplay() {
    DimAutismChoiceBacklight();
    Application::GetInstance().Schedule([]() {
        Board::GetInstance().SetApplicationSleepDisplayDimmed(true);
    });
}

static void ShowAutismChoiceWaitingPrompt() {
    auto* display = Board::GetInstance().GetDisplay();
    if (display == nullptr) {
        return;
    }
    auto* lvgl = dynamic_cast<LvglDisplay*>(display);
    if (lvgl != nullptr) {
        lvgl->SetPreviewImage(nullptr);
    }
    display->HideFullscreenImage();
    display->SetCenterStatus("");
    // 与行动卡片待机一致：选图会话初始全屏也用「欢迎你」，避免上电欢迎后再切一张「请选择」。
    display->ShowFullscreenImage(&welcome_ni);
}

static void ScheduleChoiceLabelAudio(const ChoicePreviewRequest& preview);

struct ChoicePreviewRequest {
    std::string url;
    std::string audio_url;
    int generation = 0;
    int index = -1;
    std::string scene;
    std::string source;
    int training_cmd_revision = 0;
    int plan_table_revision = 0;
};

static bool IsChoicePreviewBindingStillValid(const ChoicePreviewRequest& b) {
    if (g_choice_mutex == nullptr) {
        return false;
    }
    if (xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return false;
    }
    bool ok = g_choice_context.active && g_choice_context.generation == b.generation &&
              g_choice_context.current_index == b.index &&
              b.index >= 0 && b.index < static_cast<int>(g_choice_context.items.size()) &&
              g_choice_context.items[b.index].image_url == b.url &&
              g_choice_context.items[b.index].audio_url == b.audio_url &&
              g_choice_context.scene == b.scene && g_choice_context.source == b.source;
    if (ok && b.source == "child_training") {
        ok = g_choice_context.training_cmd_revision == b.training_cmd_revision;
    }
    if (ok && g_choice_context.scene == "daily_plan") {
        ok = g_choice_context.plan_table_revision == b.plan_table_revision;
    }
    xSemaphoreGive(g_choice_mutex);
    return ok;
}

static void ChoicePreviewTask(void* arg) {
    auto* req = static_cast<ChoicePreviewRequest*>(arg);
    if (req != nullptr) {
        if (DownloadAndShowPreviewImage(req->url, req->generation, req)) {
            ScheduleChoiceLabelAudio(*req);
        }
        delete req;
    }
    vTaskDelete(nullptr);
}

static bool PostAutismChoiceEvent(const AutismChoiceContext& ctx, const char* phase, int index,
                                  const std::string& label, bool timed_out) {
    const std::string id = PathADeviceIdUpper();
    if (id.size() < 4 || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        return false;
    }
    cJSON* root = cJSON_CreateObject();
    if (!root) {
        return false;
    }
    cJSON_AddStringToObject(root, "scene", ctx.scene.empty() ? "unknown" : ctx.scene.c_str());
    cJSON_AddStringToObject(root, "phase", phase ? phase : "unknown");
    if (ctx.session_id > 0) {
        cJSON_AddNumberToObject(root, "session_id", ctx.session_id);
    }
    cJSON* payload = cJSON_CreateObject();
    if (payload != nullptr) {
        cJSON_AddStringToObject(payload, "kind", ctx.kind.c_str());
        cJSON_AddStringToObject(payload, "source", ctx.source.c_str());
        cJSON_AddStringToObject(payload, "slot_time", ctx.slot_time.c_str());
        cJSON_AddStringToObject(payload, "focus_label", ctx.focus_label.c_str());
        if (!ctx.intro_tts_text.empty()) {
            cJSON_AddStringToObject(payload, "intro_tts", ctx.intro_tts_text.c_str());
        }
        if (timed_out) {
            cJSON_AddBoolToObject(payload, "timed_out", 1);
        }
        if (index >= 0) {
            cJSON_AddStringToObject(payload, "label", label.c_str());
            cJSON_AddNumberToObject(payload, "option_index", index);
            cJSON* opts = cJSON_CreateArray();
            if (opts != nullptr) {
                for (const auto& item : ctx.items) {
                    cJSON_AddItemToArray(opts, cJSON_CreateString(item.label.c_str()));
                }
                cJSON_AddItemToObject(payload, "options", opts);
            }
        }
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
        ESP_LOGW(TAG, "autism choice event POST failed phase=%s", phase ? phase : "");
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

static void SubmitRobotOpeningLine(const std::string& line, const std::string& context) {
    if (line.empty()) {
        return;
    }
    if (!PostXiaozhiOpeningHint(line, context)) {
        return;
    }
    Application::GetInstance().Schedule([line]() {
        Application::GetInstance().SubmitChildTextInput(line);
    });
}

static std::string RewriteLoopbackAssetUrlForDevice(const std::string& url) {
    if (url.empty() || strlen(CONFIG_ADHD_MONITOR_CMD_HOST) == 0) {
        return url;
    }
    const bool is_loopback =
        url.rfind("http://127.0.0.1", 0) == 0 ||
        url.rfind("http://localhost", 0) == 0;
    if (!is_loopback) {
        return url;
    }
    const size_t scheme_end = url.find("://");
    const size_t path_start = scheme_end == std::string::npos
        ? std::string::npos
        : url.find('/', scheme_end + 3);
    if (path_start == std::string::npos) {
        return url;
    }
    std::string rewritten = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                            std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + url.substr(path_start);
    ESP_LOGW(TAG, "rewrite loopback asset url for device: %s -> %s", url.c_str(), rewritten.c_str());
    return rewritten;
}

void adhd_remote_cmd_start_default_proactive(void) {
    const std::string opening(reinterpret_cast<const char*>(
        u8"\u4f60\u597d\u5440\uff0c\u6211\u662f\u661f\u661f\u3002"
        u8"\u6211\u5728\u8fd9\u91cc\u966a\u4f60\uff0c\u4f60\u73b0\u5728\u60f3\u544a\u8bc9\u6211\uff0c"
        u8"\u4f60\u7684\u5fc3\u60c5\u662f\u4ec0\u4e48\u6837\u7684\u5417\uff1f"
    ));
    const std::string context(reinterpret_cast<const char*>(
        u8"\u8fd9\u662fWiFi\u8fde\u63a5\u540e\u7684\u9ed8\u8ba4\u5b69\u5b50\u4e3b\u52a8\u4e8b\u4ef6\u3002"
        u8"\u8bf7\u53ea\u64ad\u653e\u8fd9\u53e5\u5f00\u573a\u767d\uff0c\u7136\u540e\u7b49\u5f85\u5b69\u5b50\u56de\u7b54\u3002"
    ));
    ESP_LOGI(TAG, "default proactive opening start");
    SubmitRobotOpeningLine(opening, context);
}

static bool DownloadAndShowPreviewImage(const std::string& url, int choice_generation,
                                        const ChoicePreviewRequest* binding) {
    if (url.empty()) {
        return false;
    }
    const std::string asset_url = RewriteLoopbackAssetUrlForDevice(url);
    auto http = Board::GetInstance().GetNetwork()->CreateHttp(3);
    ESP_LOGI(TAG, "autism image download: %s", asset_url.c_str());
    if (!http->Open("GET", asset_url)) {
        ESP_LOGW(TAG, "autism image open failed: %s", asset_url.c_str());
        return false;
    }
    int status_code = http->GetStatusCode();
    if (status_code != 200) {
        ESP_LOGW(TAG, "autism image http status=%d url=%s", status_code, asset_url.c_str());
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
            ESP_LOGW(TAG, "autism image read failed: %s", asset_url.c_str());
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
    if (binding != nullptr) {
        if (!IsChoicePreviewBindingStillValid(*binding)) {
            ESP_LOGI(TAG, "autism image skip stale binding gen=%d idx=%d scene=%s",
                     binding->generation, binding->index, binding->scene.c_str());
            heap_caps_free(data);
            return false;
        }
    } else if (choice_generation >= 0) {
        if (!IsChoiceGenerationActive(choice_generation)) {
            ESP_LOGI(TAG, "autism image skip stale generation=%d", choice_generation);
            heap_caps_free(data);
            return false;
        }
    }
    ExitActionCardsIfCoveringPreview();
    auto* any_disp = Board::GetInstance().GetDisplay();
    if (any_disp != nullptr) {
        any_disp->HideFullscreenImage();
    }
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

static bool DownloadAndPlayOggLabel(const std::string& url) {
    if (url.empty()) {
        return false;
    }
    const std::string asset_url = RewriteLoopbackAssetUrlForDevice(url);
    auto http = Board::GetInstance().GetNetwork()->CreateHttp(3);
    ESP_LOGI(TAG, "autism label audio download: %s", asset_url.c_str());
    if (!http->Open("GET", asset_url)) {
        ESP_LOGW(TAG, "autism label audio open failed: %s", asset_url.c_str());
        return false;
    }
    const int status_code = http->GetStatusCode();
    if (status_code != 200) {
        ESP_LOGW(TAG, "autism label audio http status=%d url=%s", status_code, asset_url.c_str());
        http->Close();
        return false;
    }
    const size_t content_length = http->GetBodyLength();
    const size_t max_audio_bytes = 256 * 1024;
    if (content_length > max_audio_bytes) {
        ESP_LOGW(TAG, "autism label audio too large length=%u", (unsigned)content_length);
        http->Close();
        return false;
    }
    ESP_LOGI(TAG, "autism label audio http ok body_len=%u", (unsigned)content_length);

    std::string body;
    body.reserve(content_length > 0 ? content_length : 8192);
    size_t total_read = 0;
    const int64_t read_deadline_us = esp_timer_get_time() + 8000LL * 1000LL;
    while (content_length == 0 || total_read < content_length) {
        if (esp_timer_get_time() > read_deadline_us) {
            ESP_LOGW(TAG, "autism label audio read timeout bytes=%u url=%s",
                     (unsigned)total_read, asset_url.c_str());
            http->Close();
            return false;
        }
        char chunk[2048];
        const size_t want = content_length > 0
            ? std::min(sizeof(chunk), content_length - total_read)
            : sizeof(chunk);
        int ret = http->Read(chunk, want);
        if (ret < 0) {
            ESP_LOGW(TAG, "autism label audio read failed: %s", asset_url.c_str());
            http->Close();
            return false;
        }
        if (ret == 0) {
            break;
        }
        if (total_read + static_cast<size_t>(ret) > max_audio_bytes) {
            ESP_LOGW(TAG, "autism label audio chunked too large >%u", (unsigned)max_audio_bytes);
            http->Close();
            return false;
        }
        body.append(chunk, ret);
        total_read += static_cast<size_t>(ret);
    }
    http->Close();
    if (content_length > 0 && total_read != content_length) {
        ESP_LOGW(TAG, "autism label audio incomplete read %u/%u",
                 (unsigned)total_read, (unsigned)content_length);
        return false;
    }
    if (body.empty() || body.size() > 256 * 1024) {
        ESP_LOGW(TAG, "autism label audio invalid size=%u", (unsigned)body.size());
        return false;
    }
    Application::GetInstance().PlaySound(std::string_view(body.data(), body.size()));
    ESP_LOGI(TAG, "autism label audio played bytes=%u", (unsigned)body.size());
    return true;
}

static void WaitForRobotAudioQuietBounded(int timeout_ms) {
    const int64_t deadline_us = esp_timer_get_time() + static_cast<int64_t>(timeout_ms) * 1000LL;
    auto& audio_service = Application::GetInstance().GetAudioService();
    while (!audio_service.IsIdle() && esp_timer_get_time() < deadline_us) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (!audio_service.IsIdle()) {
        ESP_LOGW(TAG, "robot audio wait timeout after %d ms", timeout_ms);
    }
}

struct RobotOggRequest {
    std::string url;
};

static void RobotOggPlayTask(void* arg) {
    auto* req = static_cast<RobotOggRequest*>(arg);
    if (req != nullptr) {
        (void)DownloadAndPlayOggLabel(req->url);
        delete req;
    }
    vTaskDelete(nullptr);
}

/// 外放服务端预生成的脚本语音（开场白 / 鼓励语）。确定性本地播放，不经 LLM、
/// 不开麦克风、不依赖主动开场匹配——孩子必定听到这句固定内容。
static void PlayRobotOggAsync(const std::string& url) {
    if (url.empty()) {
        return;
    }
    auto* req = new RobotOggRequest();
    req->url = url;
    if (xTaskCreate(RobotOggPlayTask, "robot_ogg", 8192, req, 3, nullptr) != pdPASS) {
        ESP_LOGW(TAG, "robot_ogg task create failed");
        delete req;
    }
}

/// 日常训练 / 计划表确认后：全屏选图 UI 保持到鼓励 OGG 播完，再关 visual choice，并按上电逻辑回到全屏「欢迎你」。
/// `training_cmd_revision` / `plan_table_revision` 为确认时的快照；若期间下发新的
/// training_start 或新计划表会递增 revision，此时不再关 UI（新会话已接管）。
struct PraiseThenCloseVisualArg {
    std::string praise_url;
    int training_cmd_revision = 0;
    int plan_table_revision = 0;
    bool is_daily_plan = false;
    AutismChoiceContext snapshot;
    int idx = -1;
    std::string label;
};

struct CelebrationOverlayArg {
    bool is_daily_plan = false;  // true=计划表→你真棒；false=日常训练→击掌庆祝
};

static void CelebrationOverlayTask(void* arg) {
    bool is_daily_plan = false;
    if (arg != nullptr) {
        auto* p = static_cast<CelebrationOverlayArg*>(arg);
        is_daily_plan = p->is_daily_plan;
        delete p;
    }
    const lv_image_dsc_t* img = is_daily_plan ? &you_great : &celebrate_highfive;
    UiSyncRun([img]() {
        auto* d = Board::GetInstance().GetDisplay();
        if (d != nullptr) {
            d->ShowFullscreenImage(img);
        }
    });
    vTaskDelay(pdMS_TO_TICKS(1500));
    UiSyncRun([]() {
        auto* d = Board::GetInstance().GetDisplay();
        if (d != nullptr) {
            d->HideFullscreenImage();
        }
    });
    vTaskDelete(nullptr);
}

static void PraiseThenCloseVisualChoiceTask(void* arg) {
    auto* a = static_cast<PraiseThenCloseVisualArg*>(arg);
    if (a == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    // 从本任务发 POST，避免在 BOOT/LVGL 线程里同步 HttpPostJson 与鼓励下载并发卡死 lwIP。
    (void)PostAutismChoiceEvent(a->snapshot, "image_confirmed", a->idx, a->label, false);

    // BOOT 确认瞬间：「你想做什么」0.5s，再播选项标签音（如「面条」）。
    UiSyncRun([]() {
        auto* d = Board::GetInstance().GetDisplay();
        if (d != nullptr) {
            d->ShowFullscreenImage(&what_you_want);
        }
    });
    vTaskDelay(pdMS_TO_TICKS(500));
    UiSyncRun([]() {
        auto* d = Board::GetInstance().GetDisplay();
        if (d != nullptr) {
            d->HideFullscreenImage();
        }
    });

    std::string label_audio;
    if (a->idx >= 0 && a->idx < static_cast<int>(a->snapshot.items.size())) {
        label_audio = a->snapshot.items[a->idx].audio_url;
    }
    if (!label_audio.empty()) {
        const bool label_ok = DownloadAndPlayOggLabel(label_audio);
        if (!label_ok) {
            ESP_LOGW(TAG, "praise_close: option label ogg missing or download failed");
        }
        WaitForRobotAudioQuietBounded(15000);
        vTaskDelay(pdMS_TO_TICKS(200));
    }

    if (!a->praise_url.empty()) {
        auto* cele = new CelebrationOverlayArg();
        cele->is_daily_plan = a->is_daily_plan;
        if (xTaskCreate(CelebrationOverlayTask, "cele_overlay", 4096, cele, 3, nullptr) != pdPASS) {
            ESP_LOGW(TAG, "praise_close: cele_overlay task create failed");
            delete cele;
        }
        const bool played = DownloadAndPlayOggLabel(a->praise_url);
        if (!played) {
            ESP_LOGW(TAG, "praise_close: encourage ogg missing or download failed");
        }
        WaitForRobotAudioQuietBounded(15000);
        vTaskDelay(pdMS_TO_TICKS(400));
    } else {
        ESP_LOGW(TAG, "praise_close: no praise_url (skip encourage overlay)");
    }
    bool skip_close = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(200)) == pdTRUE) {
        if (a->is_daily_plan) {
            if (g_daily_plan_store_revision != a->plan_table_revision) {
                skip_close = true;
            }
        } else if (g_autism_training_cmd_revision != a->training_cmd_revision) {
            skip_close = true;
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (!skip_close) {
        Application::GetInstance().SetVisualChoiceMode(false);
        RestoreAutismChoiceDisplayFully();
        Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
    } else {
        ESP_LOGI(TAG, "praise_close: skip UI close (superseded by newer session/plan)");
    }
    delete a;
    vTaskDelete(nullptr);
}

static void ChoiceTimeoutCloseTask(void* arg) {
    auto* snap = static_cast<AutismChoiceContext*>(arg);
    if (snap == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    bool should_run = false;
    EnsureAutismChoiceMutex();
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(300)) == pdTRUE) {
        if (g_choice_context.active && g_choice_context.generation == snap->generation &&
            g_choice_context.display_dimmed) {
            g_choice_context.active = false;
            ++g_choice_generation;
            should_run = true;
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (!should_run) {
        delete snap;
        vTaskDelete(nullptr);
        return;
    }
    (void)PostAutismChoiceEvent(*snap, "choice_timeout", -1, "", true);
    if (!snap->choice_timeout_audio_url.empty()) {
        const bool played = DownloadAndPlayOggLabel(snap->choice_timeout_audio_url);
        if (!played) {
            ESP_LOGW(TAG, "choice_timeout: encourage ogg missing or download failed");
        }
        WaitForRobotAudioQuietBounded(15000);
        vTaskDelay(pdMS_TO_TICKS(400));
    } else {
        ESP_LOGW(TAG, "choice_timeout: no choice_timeout_audio_url from server");
    }
    Application::GetInstance().SetVisualChoiceMode(false);
    RestoreAutismChoiceDisplayFully();
    Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
    delete snap;
    vTaskDelete(nullptr);
}

struct ChoiceLabelAudioRequest {
    int generation = 0;
    int index = -1;
    std::string audio_url;
    std::string image_url;
    std::string scene;
    std::string source;
    int training_cmd_revision = 0;
    int plan_table_revision = 0;
};

static void ChoiceLabelAudioHoldTask(void* arg) {
    auto* req = static_cast<ChoiceLabelAudioRequest*>(arg);
    if (req == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    // 图片已显示后再播标签 OGG（与服务端预生成 o 对应）
    vTaskDelay(pdMS_TO_TICKS(2000));
    ChoicePreviewRequest chk;
    chk.url = req->image_url;
    chk.audio_url = req->audio_url;
    chk.generation = req->generation;
    chk.index = req->index;
    chk.scene = req->scene;
    chk.source = req->source;
    chk.training_cmd_revision = req->training_cmd_revision;
    chk.plan_table_revision = req->plan_table_revision;
    if (IsChoicePreviewBindingStillValid(chk)) {
        (void)DownloadAndPlayOggLabel(req->audio_url);
    } else {
        ESP_LOGI(TAG, "autism label audio skip stale gen=%d idx=%d", req->generation, req->index);
    }
    delete req;
    vTaskDelete(nullptr);
}

static void ScheduleChoiceLabelAudio(const ChoicePreviewRequest& preview) {
    if (preview.audio_url.empty()) {
        return;
    }
    auto* req = new ChoiceLabelAudioRequest();
    req->generation = preview.generation;
    req->index = preview.index;
    req->audio_url = preview.audio_url;
    req->image_url = preview.url;
    req->scene = preview.scene;
    req->source = preview.source;
    req->training_cmd_revision = preview.training_cmd_revision;
    req->plan_table_revision = preview.plan_table_revision;
    BaseType_t tr = xTaskCreate(ChoiceLabelAudioHoldTask, "choice_audio", 8192, req, 3, nullptr);
    if (tr != pdPASS) {
        delete req;
        ESP_LOGW(TAG, "choice_audio task create failed");
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
        g_choice_context.display_dimmed = false;
        g_choice_context.current_index = -1;
        g_choice_context.activity_seq = 0;
        xSemaphoreGive(g_choice_mutex);
    }
    RestoreAutismChoiceDisplayFully();
    ShowAutismChoiceWaitingPrompt();
    int last_index = -1;
    int last_activity_seq = 0;
    int64_t last_activity_us = esp_timer_get_time();
    int64_t dim_entered_at_us = 0;
    bool idle_timeout_task_launched = false;
    while (true) {
        bool still_active = true;
        bool display_dimmed = false;
        int current_index = -1;
        int activity_seq = 0;
        if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
            still_active = g_choice_context.active && g_choice_context.generation == ctx->generation;
            current_index = g_choice_context.current_index;
            activity_seq = g_choice_context.activity_seq;
            display_dimmed = g_choice_context.display_dimmed;
            xSemaphoreGive(g_choice_mutex);
        }
        if (!still_active) {
            break;
        }
        const int64_t now_us = esp_timer_get_time();
        if (current_index != last_index) {
            last_index = current_index;
            last_activity_seq = activity_seq;
            last_activity_us = now_us;
            if (display_dimmed) {
                RestoreAutismChoiceDisplayFully();
                if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                    if (g_choice_context.active && g_choice_context.generation == ctx->generation) {
                        g_choice_context.display_dimmed = false;
                    }
                    xSemaphoreGive(g_choice_mutex);
                }
            }
        } else if (activity_seq != last_activity_seq) {
            last_activity_seq = activity_seq;
            last_activity_us = now_us;
        }
        if (!display_dimmed) {
            dim_entered_at_us = 0;
            idle_timeout_task_launched = false;
        } else if (dim_entered_at_us == 0) {
            dim_entered_at_us = now_us;
            idle_timeout_task_launched = false;
        }
        if (!display_dimmed && now_us - last_activity_us >= 60LL * 1000LL * 1000LL) {
            DimAutismChoiceIdleSleepDisplay();
            if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                if (g_choice_context.active && g_choice_context.generation == ctx->generation) {
                    g_choice_context.display_dimmed = true;
                }
                xSemaphoreGive(g_choice_mutex);
            }
            ESP_LOGI(TAG, "autism choice idle dimmed scene=%s index=%d",
                     ctx->scene.c_str(), current_index);
        }
        // 全黑后再等待 60s 仍无 BOOT 确认：上报超时并播放鼓励语，关闭选图 UI。
        if (display_dimmed && dim_entered_at_us > 0 && !idle_timeout_task_launched &&
            now_us - dim_entered_at_us >= 60LL * 1000LL * 1000LL) {
            AutismChoiceContext* snap = nullptr;
            if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(200)) == pdTRUE) {
                if (g_choice_context.active && g_choice_context.generation == ctx->generation &&
                    g_choice_context.display_dimmed) {
                    snap = new AutismChoiceContext();
                    *snap = g_choice_context;
                    idle_timeout_task_launched = true;
                }
                xSemaphoreGive(g_choice_mutex);
            }
            if (snap != nullptr) {
                BaseType_t tr = xTaskCreate(ChoiceTimeoutCloseTask, "choice_timeout", 12288, snap, 3, nullptr);
                if (tr != pdPASS) {
                    ESP_LOGW(TAG, "choice_timeout task create failed");
                    delete snap;
                    idle_timeout_task_launched = false;
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
    // 选图会话结束：仅释放 ctx。日常训练确认后的关 UI 在鼓励播完后由 PraiseThenCloseVisualChoiceTask
    // 执行；Invalidate 路径会自行 SetVisualChoiceMode(false)。
    delete ctx;
    vTaskDelete(nullptr);
}

static void StartAutismChoiceSequence(AutismChoiceContext* ctx) {
    if (ctx == nullptr || ctx->items.empty()) {
        delete ctx;
        return;
    }
#if HAVE_LVGL
    g_path_a_intro_suppresses_kids.store(false);
#endif
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

struct IntroThenChoiceArg {
    AutismChoiceContext* ctx = nullptr;
    /// 开场白 OGG（计划表为各时段 `tts` 预合成的固定话术，非闲聊链路）。
    std::string intro_audio_url;
    /// 没有开场白音频时的兜底等待（让等待界面不至于瞬间弹出）。
    int fallback_delay_ms = 500;
    /// 仅 daily_plan：到点时计划表 revision，无选图 ctx 时仍用于丢弃已被替换的旧开场。
    int daily_plan_revision_snapshot = -1;
    /// 仅计划表「仅开场、无选图」槽位：用于上报 intro_played。
    bool intro_log_daily_plan_only = false;
    std::string intro_log_slot_time;
    std::string intro_log_tts;
};

static void IntroThenChoiceTask(void* arg) {
    auto* a = static_cast<IntroThenChoiceArg*>(arg);
    if (a == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    ESP_LOGI(TAG, "autism_intro_wait: start (intro_url_len=%u rev=%d)",
             (unsigned)a->intro_audio_url.size(),
             a->ctx != nullptr ? a->ctx->training_cmd_revision : -1);
    if (a->daily_plan_revision_snapshot >= 0 &&
        a->daily_plan_revision_snapshot != g_daily_plan_store_revision) {
        ESP_LOGI(TAG, "daily_plan superseded before intro (rev=%d current=%d); skip",
                 a->daily_plan_revision_snapshot, g_daily_plan_store_revision);
        delete a->ctx;
        a->ctx = nullptr;
        delete a;
        vTaskDelete(nullptr);
        return;
    }
#if HAVE_LVGL
    PathAIntroKidsGuard intro_kids_guard;
#endif
    if (!a->intro_audio_url.empty()) {
        // 固定话术 OGG（服务端按时段 tts 预生成），整段播完再出选图。
        (void)DownloadAndPlayOggLabel(a->intro_audio_url);
        WaitForRobotAudioQuietBounded(15000);
        vTaskDelay(pdMS_TO_TICKS(400));  // 一点自然停顿，避免说完立刻跳图
    } else if (a->fallback_delay_ms > 0) {
        vTaskDelay(pdMS_TO_TICKS(a->fallback_delay_ms));
    }
    // 开场白已完整播放（或走兜底等待）：上报 intro_played，供家长端 digest / 周报中文记录。
    if (a->ctx != nullptr) {
        (void)PostAutismChoiceEvent(*a->ctx, "intro_played", -1, "", false);
    } else if (a->intro_log_daily_plan_only && a->daily_plan_revision_snapshot >= 0) {
        AutismChoiceContext tmp;
        tmp.scene = "daily_plan";
        tmp.kind = "daily_plan";
        tmp.source = "daily_plan";
        tmp.slot_time = a->intro_log_slot_time;
        tmp.focus_label = a->intro_log_tts;
        tmp.intro_tts_text = a->intro_log_tts;
        tmp.plan_table_revision = a->daily_plan_revision_snapshot;
        (void)PostAutismChoiceEvent(tmp, "intro_played", -1, "", false);
    }
    if (a->daily_plan_revision_snapshot >= 0 &&
        a->daily_plan_revision_snapshot != g_daily_plan_store_revision) {
        ESP_LOGI(TAG, "daily_plan superseded after intro (rev=%d current=%d); skip choice UI",
                 a->daily_plan_revision_snapshot, g_daily_plan_store_revision);
        delete a->ctx;
        a->ctx = nullptr;
        delete a;
        vTaskDelete(nullptr);
        return;
    }
    if (a->ctx != nullptr && a->ctx->scene == "daily_plan" &&
        a->ctx->plan_table_revision != g_daily_plan_store_revision) {
        ESP_LOGI(TAG, "daily_plan intro stale (rev=%d current=%d); skip choice UI",
                 a->ctx->plan_table_revision, g_daily_plan_store_revision);
        delete a->ctx;
        delete a;
        vTaskDelete(nullptr);
        return;
    }
    if (a->ctx != nullptr && a->ctx->source == "child_training" &&
        a->ctx->training_cmd_revision != g_autism_training_cmd_revision) {
        ESP_LOGI(TAG, "training_start intro stale (rev=%d current=%d); skip choice UI",
                 a->ctx->training_cmd_revision, g_autism_training_cmd_revision);
        delete a->ctx;
        delete a;
        vTaskDelete(nullptr);
        return;
    }
    if (a->ctx != nullptr) {
        StartAutismChoiceSequence(a->ctx);
    }
    delete a;
    vTaskDelete(nullptr);
}

/// 新的一次日常训练覆盖尚未结束的上一轮：清选图 UI，避免多路 intro/选图任务叠内存。
static void InvalidateAutismTrainingChoiceUi() {
    EnsureAutismChoiceMutex();
    bool cleared = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        if (g_choice_context.active && g_choice_context.source == "child_training") {
            g_choice_context.active = false;
            ++g_choice_generation;
            cleared = true;
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (cleared) {
        Application::GetInstance().SetVisualChoiceMode(false);
        RestoreAutismChoiceDisplayFully();
        Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
        ESP_LOGI(TAG, "autism training superseded: cleared in-progress training choice UI");
    }
}

static void FireAutismDailyPlanSlot(const AutismDailyPlanSlot& slot) {
    Application::GetInstance().ExitSleepPowerSaveForAlarm("daily_plan");
    Application::GetInstance().CancelPowerWelcomeFlowForPathA();
    ExitActionCardsIfCoveringPreview();
    AutismChoiceContext* plan_ctx = nullptr;
    if (!slot.image_urls.empty()) {
        plan_ctx = new AutismChoiceContext();
        plan_ctx->scene = "daily_plan";
        plan_ctx->kind = "daily_plan";
        plan_ctx->source = "daily_plan";
        plan_ctx->slot_time = slot.time_text;
        plan_ctx->focus_label = slot.tts;
        plan_ctx->intro_tts_text = slot.tts;
        plan_ctx->choice_timeout_audio_url = slot.choice_timeout_audio_url;
        plan_ctx->plan_table_revision = slot.plan_table_revision;
        for (size_t i = 0; i < slot.image_urls.size(); ++i) {
            AutismChoiceItem item;
            item.image_url = slot.image_urls[i];
            item.label = i < slot.option_labels.size() ? slot.option_labels[i] : "";
            item.audio_url = i < slot.audio_urls.size() ? slot.audio_urls[i] : "";
            item.praise_audio_url =
                i < slot.praise_audio_urls.size() ? slot.praise_audio_urls[i] : "";
            plan_ctx->items.push_back(std::move(item));
        }
    }
    ESP_LOGI(TAG, "daily_plan fire %s images=%u intro_url=%s", slot.time_text.c_str(),
             (unsigned)slot.image_urls.size(), slot.intro_audio_url.empty() ? "empty" : "ok");
    const bool have_intro = !slot.intro_audio_url.empty();
    if (!have_intro && plan_ctx == nullptr) {
        ESP_LOGW(TAG, "daily_plan fire %s: no intro_audio and no images (tts needs server OGG inject)",
                 slot.time_text.c_str());
        return;
    }
    if (have_intro && plan_ctx == nullptr && !slot.tts.empty()) {
        ESP_LOGI(TAG, "daily_plan intro-only (fixed tts playback, no choice UI this slot)");
    }
    if (have_intro || plan_ctx != nullptr) {
        auto* delay_arg = new IntroThenChoiceArg();
        delay_arg->ctx = plan_ctx;
        delay_arg->intro_audio_url = slot.intro_audio_url;
        delay_arg->daily_plan_revision_snapshot = slot.plan_table_revision;
        delay_arg->intro_log_daily_plan_only = (plan_ctx == nullptr);
        delay_arg->intro_log_slot_time = slot.time_text;
        delay_arg->intro_log_tts = slot.tts;
        BaseType_t tr = xTaskCreate(IntroThenChoiceTask, "autism_intro_wait", 8192, delay_arg, 3, nullptr);
        if (tr != pdPASS) {
            ESP_LOGW(TAG, "autism_intro_wait task create failed");
            delete plan_ctx;
            delete delay_arg;
        }
    }
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

/// 新计划表覆盖旧表：结束进行中的计划表选图，避免旧图/旧 TTS 与新表混用。
static void InvalidateAutismDailyPlanChoiceUi() {
    EnsureAutismChoiceMutex();
    bool cleared = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        if (g_choice_context.active && g_choice_context.scene == "daily_plan") {
            g_choice_context.active = false;
            ++g_choice_generation;
            cleared = true;
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (cleared) {
        Application::GetInstance().SetVisualChoiceMode(false);
        RestoreAutismChoiceDisplayFully();
        Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
        ESP_LOGI(TAG, "daily_plan superseded: cleared in-progress plan choice UI");
    }
}

static void StoreAutismDailyPlan(cJSON* session) {
    cJSON* slots = cJSON_GetObjectItem(session, "slots");
    cJSON* images = cJSON_GetObjectItem(session, "images");
    cJSON* audio = cJSON_GetObjectItem(session, "audio");
    cJSON* intro_audio = cJSON_GetObjectItem(session, "intro_audio");
    cJSON* praise_audio = cJSON_GetObjectItem(session, "praise_audio");
    cJSON* choice_timeout_audio = cJSON_GetObjectItem(session, "choice_timeout_audio");
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
        if (cJSON_IsObject(intro_audio)) {
            char intro_key[16];
            snprintf(intro_key, sizeof(intro_key), "s%d", i);
            cJSON* intro_url = cJSON_GetObjectItem(intro_audio, intro_key);
            if (cJSON_IsString(intro_url) && intro_url->valuestring) {
                slot.intro_audio_url = intro_url->valuestring;
            }
        }
        cJSON* options = cJSON_GetObjectItem(item, "options");
        const int opt_count = cJSON_IsArray(options) ? cJSON_GetArraySize(options) : 4;
        for (int j = 0; j < opt_count; ++j) {
            char key[24];
            snprintf(key, sizeof(key), "s%d_o%d", i, j);
            cJSON* url = cJSON_IsObject(images) ? cJSON_GetObjectItem(images, key) : nullptr;
            if (cJSON_IsString(url) && url->valuestring && strlen(url->valuestring) > 0) {
                cJSON* opt = cJSON_IsArray(options) ? cJSON_GetArrayItem(options, j) : nullptr;
                cJSON* audio_url = cJSON_IsObject(audio) ? cJSON_GetObjectItem(audio, key) : nullptr;
                cJSON* pr_url = cJSON_IsObject(praise_audio) ? cJSON_GetObjectItem(praise_audio, key) : nullptr;
                slot.option_labels.push_back(cJSON_IsString(opt) && opt->valuestring ? opt->valuestring : "");
                slot.image_urls.push_back(url->valuestring);
                slot.audio_urls.push_back(cJSON_IsString(audio_url) && audio_url->valuestring ? audio_url->valuestring : "");
                slot.praise_audio_urls.push_back(
                    cJSON_IsString(pr_url) && pr_url->valuestring ? pr_url->valuestring : "");
            }
        }
        if (cJSON_IsObject(choice_timeout_audio)) {
            char ctk[16];
            snprintf(ctk, sizeof(ctk), "s%d", i);
            cJSON* ctu = cJSON_GetObjectItem(choice_timeout_audio, ctk);
            if (cJSON_IsString(ctu) && ctu->valuestring) {
                slot.choice_timeout_audio_url = ctu->valuestring;
            }
        }
        parsed.push_back(std::move(slot));
    }
    if (parsed.empty()) {
        ESP_LOGW(TAG, "daily_plan parsed no valid slots");
        return;
    }

    InvalidateAutismDailyPlanChoiceUi();

    EnsureDailyPlanSchedulerStarted();
    if (g_daily_plan_mutex != nullptr && xSemaphoreTake(g_daily_plan_mutex, pdMS_TO_TICKS(1000)) == pdTRUE) {
        const int next_rev = g_daily_plan_store_revision + 1;
        for (auto& slot : parsed) {
            slot.plan_table_revision = next_rev;
        }
        g_daily_plan_slots = std::move(parsed);
        g_daily_plan_store_revision = next_rev;
        xSemaphoreGive(g_daily_plan_mutex);
        ESP_LOGI(TAG, "daily_plan stored slots=%u rev=%d; waiting for scheduled time",
                 (unsigned)g_daily_plan_slots.size(), g_daily_plan_store_revision);
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
    std::string body = std::string("{\"device_id\":\"") + id + "\",\"kind\":\"xingxing\"}";
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
    bool consumed_wake = false;
    int idx = -1;
    std::string label;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(200)) == pdTRUE) {
        if (g_choice_context.active) {
            if (g_choice_context.display_dimmed) {
                g_choice_context.display_dimmed = false;
                ++g_choice_context.activity_seq;
                consumed_wake = true;
            } else if (g_choice_context.current_index < 0) {
                ++g_choice_context.activity_seq;
                consumed_wake = true;
            } else if (g_choice_context.current_index < static_cast<int>(g_choice_context.items.size())) {
                snapshot = g_choice_context;
                idx = g_choice_context.current_index;
                label = g_choice_context.items[idx].label;
                g_choice_context.active = false;
                // 不在此处递增 g_choice_generation：下一轮 StartAutismChoiceSequence 会再 ++，
                // 若此处也 ++，鼓励收尾任务会误判 supersede 而永远不 SetVisualChoiceMode(false)。
            }
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (consumed_wake) {
        RestoreAutismChoiceDisplayFully();
        return true;
    }
    if (idx < 0) {
        return false;
    }
    ESP_LOGI(TAG, "autism choice confirmed scene=%s idx=%d label=%s",
             snapshot.scene.c_str(), idx, label.c_str());
    if (snapshot.source == "child_training" || snapshot.source == "daily_plan") {
        const std::string praise_url =
            (idx >= 0 && idx < static_cast<int>(snapshot.items.size()))
                ? snapshot.items[idx].praise_audio_url
                : std::string();
        auto* pa = new PraiseThenCloseVisualArg();
        pa->praise_url = praise_url;
        pa->training_cmd_revision = snapshot.training_cmd_revision;
        pa->plan_table_revision = snapshot.plan_table_revision;
        pa->is_daily_plan = (snapshot.source == "daily_plan");
        pa->snapshot = std::move(snapshot);
        pa->idx = idx;
        pa->label = std::move(label);
        if (xTaskCreate(PraiseThenCloseVisualChoiceTask, "praise_close", 12288, pa, 3, nullptr) != pdPASS) {
            ESP_LOGW(TAG, "praise_close task create failed");
            (void)PostAutismChoiceEvent(pa->snapshot, "image_confirmed", pa->idx, pa->label, false);
            delete pa;
            Application::GetInstance().SetVisualChoiceMode(false);
            RestoreAutismChoiceDisplayFully();
            Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
        }
    } else {
        (void)PostAutismChoiceEvent(snapshot, "image_confirmed", idx, label, false);
        Application::GetInstance().SetVisualChoiceMode(false);
        RestoreAutismChoiceDisplayFully();
        Application::GetInstance().EnterChildVoluntaryWelcomeFromPathA();
    }
    return true;
}

bool adhd_next_autism_choice(void) {
    EnsureAutismChoiceMutex();
    std::string url;
    std::string audio_url;
    int next_idx = -1;
    int generation = 0;
    std::string scene;
    std::string source;
    int training_cmd_revision = 0;
    int plan_table_revision = 0;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(200)) == pdTRUE) {
        if (g_choice_context.active && !g_choice_context.items.empty()) {
            if (g_choice_context.display_dimmed) {
                next_idx = -2;
            } else {
                ++g_choice_context.activity_seq;
                next_idx = (g_choice_context.current_index + 1) %
                           static_cast<int>(g_choice_context.items.size());
                g_choice_context.current_index = next_idx;
                url = g_choice_context.items[next_idx].image_url;
                audio_url = g_choice_context.items[next_idx].audio_url;
                generation = g_choice_context.generation;
                scene = g_choice_context.scene;
                source = g_choice_context.source;
                training_cmd_revision = g_choice_context.training_cmd_revision;
                plan_table_revision = g_choice_context.plan_table_revision;
            }
        }
        xSemaphoreGive(g_choice_mutex);
    }
    if (next_idx == -2) {
        ESP_LOGI(TAG, "autism choice shake ignored while dimmed");
        return false;
    }
    if (next_idx < 0 || url.empty()) {
        return false;
    }
    RestoreAutismChoiceBacklight();
    auto* req = new ChoicePreviewRequest();
    req->url = url;
    req->audio_url = audio_url;
    req->generation = generation;
    req->index = next_idx;
    req->scene = std::move(scene);
    req->source = std::move(source);
    req->training_cmd_revision = training_cmd_revision;
    req->plan_table_revision = plan_table_revision;
    BaseType_t tr = xTaskCreate(ChoicePreviewTask, "choice_next", 8192, req, 3, nullptr);
    if (tr != pdPASS) {
        ESP_LOGW(TAG, "choice_next task create failed");
        delete req;
        return false;
    }
    ESP_LOGI(TAG, "autism choice next idx=%d generation=%d", next_idx, generation);
    return true;
}

bool adhd_autism_choice_shake_blocked(void) {
    EnsureAutismChoiceMutex();
    bool blocked = false;
    if (g_choice_mutex != nullptr && xSemaphoreTake(g_choice_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
        blocked = g_choice_context.active && g_choice_context.display_dimmed;
        xSemaphoreGive(g_choice_mutex);
    }
    return blocked;
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
            Application::GetInstance().CancelPowerWelcomeFlowForPathA();
            ExitActionCardsIfCoveringPreview();
            cJSON* sidn = cJSON_GetObjectItem(session, "session_id");
            const int sid = cJSON_IsNumber(sidn) ? sidn->valueint : 0;
            cJSON* scene = cJSON_GetObjectItem(session, "scene_id");
            cJSON* focus = cJSON_GetObjectItem(session, "focus_label");
            cJSON* options = cJSON_GetObjectItem(session, "options");
            cJSON* images = cJSON_GetObjectItem(session, "images");
            cJSON* audio = cJSON_GetObjectItem(session, "audio");
            cJSON* praise_audio = cJSON_GetObjectItem(session, "praise_audio");
            auto* ctx = new AutismChoiceContext();
            ctx->scene = cJSON_IsString(scene) && scene->valuestring ? scene->valuestring : "training";
            ctx->kind = "training_start";
            ctx->source = "child_training";
            ctx->session_id = sid;
            ctx->focus_label = cJSON_IsString(focus) && focus->valuestring ? focus->valuestring : "";
            cJSON* tts_intro = cJSON_GetObjectItem(session, "tts_intro");
            ctx->intro_tts_text =
                cJSON_IsString(tts_intro) && tts_intro->valuestring ? tts_intro->valuestring : "";
            cJSON* cto = cJSON_GetObjectItem(session, "choice_timeout_audio");
            if (cJSON_IsString(cto) && cto->valuestring) {
                ctx->choice_timeout_audio_url = cto->valuestring;
            }
            const int opt_count = cJSON_IsArray(options) ? cJSON_GetArraySize(options) : 0;
            for (int i = 0; i < opt_count; ++i) {
                char key[16];
                snprintf(key, sizeof(key), "o%d", i);
                cJSON* url = cJSON_IsObject(images) ? cJSON_GetObjectItem(images, key) : nullptr;
                if (!cJSON_IsString(url) || !url->valuestring || strlen(url->valuestring) == 0) {
                    continue;
                }
                cJSON* opt = cJSON_GetArrayItem(options, i);
                cJSON* audio_url = cJSON_IsObject(audio) ? cJSON_GetObjectItem(audio, key) : nullptr;
                cJSON* praise_url = cJSON_IsObject(praise_audio) ? cJSON_GetObjectItem(praise_audio, key) : nullptr;
                AutismChoiceItem item;
                item.label = cJSON_IsString(opt) && opt->valuestring ? opt->valuestring : "";
                item.image_url = url->valuestring;
                item.audio_url = cJSON_IsString(audio_url) && audio_url->valuestring ? audio_url->valuestring : "";
                item.praise_audio_url = cJSON_IsString(praise_url) && praise_url->valuestring ? praise_url->valuestring : "";
                ctx->items.push_back(std::move(item));
            }
            ESP_LOGI(TAG, "autism_session training_start scene=%s image_urls=%u session_id=%d",
                     ctx->scene.c_str(), (unsigned)ctx->items.size(), sid);
            if (ctx->items.empty()) {
                ESP_LOGW(TAG, "autism_session training_start: no image URLs in payload (check server images + public URL)");
                delete ctx;
            } else {
                InvalidateAutismTrainingChoiceUi();
                ++g_autism_training_cmd_revision;
                ctx->training_cmd_revision = g_autism_training_cmd_revision;
                cJSON* intro_audio = cJSON_GetObjectItem(session, "intro_audio");
                const std::string intro_url =
                    cJSON_IsString(intro_audio) && intro_audio->valuestring ? intro_audio->valuestring : "";
                // 确定性本地外放开场白；开场白播完后再出选图界面，避免突兀。
                auto* delay_arg = new IntroThenChoiceArg();
                delay_arg->ctx = ctx;
                delay_arg->intro_audio_url = intro_url;
                BaseType_t tr_intro = xTaskCreate(IntroThenChoiceTask, "autism_intro_wait", 8192, delay_arg, 3, nullptr);
                if (tr_intro != pdPASS) {
                    ESP_LOGW(TAG, "autism_intro_wait task create failed");
                    delete ctx;
                    delete delay_arg;
                }
            }
            if (sid > 0) {
                BaseType_t tr = xTaskCreate(AutismTrainingAckTask, "autism_ack", 8192,
                                            reinterpret_cast<void*>(static_cast<intptr_t>(sid)), 3, nullptr);
                if (tr != pdPASS) {
                    ESP_LOGW(TAG, "autism_ack task create failed");
                }
            }
        } else if (strcmp(k, "training_score") == 0) {
            cJSON* intro_audio = cJSON_GetObjectItem(session, "intro_audio");
            if (cJSON_IsString(intro_audio) && intro_audio->valuestring &&
                strlen(intro_audio->valuestring) > 0) {
                PlayRobotOggAsync(intro_audio->valuestring);
            } else {
                ESP_LOGW(TAG, "training_score: no intro_audio (server edge-tts/ffmpeg?)");
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

        // 长轮询期间会阻塞数十秒；默认无日志易被误认为死机，故每次发起前打一行。
        ESP_LOGI(TAG, "cmd long-poll: blocking GET (server may hold up to ~55s)…");

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
            ESP_LOGI(TAG, "cmd long-poll: empty queue (204), alive — next round");
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
void adhd_remote_cmd_start_default_proactive(void) {}
bool adhd_post_autism_need_event(const char*, const char*, const char*) {
    return false;
}
bool adhd_confirm_autism_choice(void) {
    return false;
}
bool adhd_next_autism_choice(void) {
    return false;
}
bool adhd_autism_choice_shake_blocked(void) {
    return false;
}

bool adhd_path_a_intro_suppresses_kids(void) {
    return false;
}

#endif
