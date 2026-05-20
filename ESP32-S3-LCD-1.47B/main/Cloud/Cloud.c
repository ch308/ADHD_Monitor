#include "Cloud.h"
#include "Wireless.h"
#include "RGB.h"
#include "ST7789.h"

#include "esp_log.h"
#include "esp_http_client.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "cJSON.h"
#include "sdkconfig.h"

#include <string.h>
#include <stdio.h>

#ifndef CONFIG_ADHD_CLOUD_HOST
#define CONFIG_ADHD_CLOUD_HOST "124.223.53.33"
#endif
#ifndef CONFIG_ADHD_CLOUD_PORT
#define CONFIG_ADHD_CLOUD_PORT 11760
#endif
#ifndef CONFIG_ADHD_CLOUD_POLL_WAIT_S
#define CONFIG_ADHD_CLOUD_POLL_WAIT_S 25
#endif

static const char *TAG = "Cloud";

static unsigned long s_last_success_ms = 0;

/* 单次响应缓冲：上限 2 KB；命令体本来就小 */
#define CLOUD_RESP_MAX  2048
static char s_resp_buf[CLOUD_RESP_MAX + 1];
static size_t s_resp_len = 0;

/** 呼吸 watchdog：如果手机端因为掉线 / 进程被杀，stop 命令丢了，
 *  灯环不应该一直亮着。breathing_start 启动这个一次性定时器，
 *  到期自动 RGB_All_Off + 灭屏；breathing_stop / all_off / reset_provisioning
 *  会取消它。 */
#define BREATHING_WATCHDOG_DEFAULT_MS  (10 * 60 * 1000)  /* 10 分钟 */
static esp_timer_handle_t s_breathing_watchdog = NULL;

static void breathing_watchdog_cb(void *arg)
{
    (void)arg;
    ESP_LOGW(TAG, "breathing watchdog fired (stop cmd never arrived) → all_off");
    RGB_All_Off();
    Set_Backlight(0);
}

static void breathing_watchdog_arm(uint32_t timeout_ms)
{
    if (s_breathing_watchdog == NULL) {
        const esp_timer_create_args_t targs = {
            .callback = breathing_watchdog_cb,
            .name = "breath_wdt",
            .arg = NULL,
        };
        if (esp_timer_create(&targs, &s_breathing_watchdog) != ESP_OK) {
            ESP_LOGE(TAG, "breathing watchdog create failed");
            return;
        }
    }
    /* 重置：先停再启，避免旧定时器和新的叠加 */
    esp_timer_stop(s_breathing_watchdog);
    if (timeout_ms == 0) {
        timeout_ms = BREATHING_WATCHDOG_DEFAULT_MS;
    }
    esp_timer_start_once(s_breathing_watchdog, (uint64_t)timeout_ms * 1000ULL);
    ESP_LOGI(TAG, "breathing watchdog armed: %u ms", (unsigned)timeout_ms);
}

static void breathing_watchdog_cancel(void)
{
    if (s_breathing_watchdog != NULL) {
        esp_timer_stop(s_breathing_watchdog);
    }
}

static unsigned long now_ms(void)
{
    return (unsigned long)(esp_timer_get_time() / 1000ULL);
}

unsigned long Cloud_LastSuccessMs(void)
{
    return s_last_success_ms;
}

static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    switch (evt->event_id) {
        case HTTP_EVENT_ON_DATA:
            if (!esp_http_client_is_chunked_response(evt->client)) {
                size_t copy = evt->data_len;
                if (s_resp_len + copy > CLOUD_RESP_MAX) {
                    copy = CLOUD_RESP_MAX - s_resp_len;
                }
                if (copy > 0) {
                    memcpy(s_resp_buf + s_resp_len, evt->data, copy);
                    s_resp_len += copy;
                }
            }
            break;
        case HTTP_EVENT_ON_FINISH:
            s_resp_buf[s_resp_len] = '\0';
            break;
        case HTTP_EVENT_DISCONNECTED:
            s_resp_buf[s_resp_len] = '\0';
            break;
        default:
            break;
    }
    return ESP_OK;
}

static void dispatch_cmd(const char *action, const cJSON *params)
{
    if (action == NULL) {
        return;
    }

    if (strcmp(action, "breathing_start") == 0) {
        int cycle_ms = 0;
        const cJSON *c = cJSON_GetObjectItemCaseSensitive(params, "cycle_ms");
        if (cJSON_IsNumber(c)) {
            cycle_ms = c->valueint;
        }
        /* 服务器可选下发 ttl_ms 覆盖默认 watchdog 时长（防丢 stop 命令） */
        uint32_t ttl_ms = 0;
        const cJSON *ttl = cJSON_GetObjectItemCaseSensitive(params, "ttl_ms");
        if (cJSON_IsNumber(ttl) && ttl->valueint > 0) {
            ttl_ms = (uint32_t)ttl->valueint;
        }
        Set_Backlight(60);  /* 命令到了，把屏轻轻点亮一些 */
        RGB_Start_Breathing((uint32_t)cycle_ms);
        breathing_watchdog_arm(ttl_ms);
        ESP_LOGI(TAG, "→ breathing_start cycle_ms=%d", cycle_ms);
        return;
    }
    if (strcmp(action, "breathing_stop") == 0) {
        RGB_Stop_Breathing();
        RGB_Stop_Countdown();
        Set_Backlight(0);
        breathing_watchdog_cancel();
        ESP_LOGI(TAG, "→ breathing_stop");
        return;
    }
    if (strcmp(action, "countdown_start") == 0) {
        int total_ms = 0;
        const cJSON *t = cJSON_GetObjectItemCaseSensitive(params, "total_ms");
        if (cJSON_IsNumber(t)) {
            total_ms = t->valueint;
        }
        Set_Backlight(60);
        RGB_Start_Countdown((uint32_t)total_ms);
        ESP_LOGI(TAG, "→ countdown_start total_ms=%d", total_ms);
        return;
    }
    if (strcmp(action, "countdown_stop") == 0) {
        RGB_Stop_Countdown();
        ESP_LOGI(TAG, "→ countdown_stop");
        return;
    }
    if (strcmp(action, "all_off") == 0) {
        RGB_All_Off();
        Set_Backlight(0);
        breathing_watchdog_cancel();
        ESP_LOGI(TAG, "→ all_off");
        return;
    }
    if (strcmp(action, "reset_provisioning") == 0) {
        /* 关掉所有灯/屏，给一点时间把日志冲出 UART，再走 NVS 清空 + 重启路径。
         * Wireless_ResetProvisioning() 内部 esp_restart()，不会返回。 */
        RGB_All_Off();
        Set_Backlight(0);
        breathing_watchdog_cancel();
        ESP_LOGW(TAG, "→ reset_provisioning (clear creds & reboot to BLE prov)");
        vTaskDelay(pdMS_TO_TICKS(300));
        Wireless_ResetProvisioning();
        return;
    }
    ESP_LOGW(TAG, "unknown action: %s", action);
}

static void parse_and_dispatch(const char *body, size_t len)
{
    if (body == NULL || len < 2) {
        return;
    }
    cJSON *root = cJSON_ParseWithLength(body, len);
    if (root == NULL) {
        ESP_LOGW(TAG, "json parse failed: %.*s", (int)len, body);
        return;
    }

    /* 支持两种格式：
     *  - {"action":"breathing_start", "cycle_ms": 8000}
     *  - {"cmds":[{...},{...}]}            // 批量
     */
    cJSON *cmds = cJSON_GetObjectItemCaseSensitive(root, "cmds");
    if (cJSON_IsArray(cmds)) {
        cJSON *it = NULL;
        cJSON_ArrayForEach(it, cmds) {
            cJSON *a = cJSON_GetObjectItemCaseSensitive(it, "action");
            if (cJSON_IsString(a)) {
                dispatch_cmd(a->valuestring, it);
            }
        }
    } else {
        cJSON *a = cJSON_GetObjectItemCaseSensitive(root, "action");
        if (cJSON_IsString(a)) {
            dispatch_cmd(a->valuestring, root);
        }
    }

    cJSON_Delete(root);
}

static void poll_once(void)
{
    char url[160];
    snprintf(url, sizeof(url),
             "http://%s:%d/device/%s/cmd?wait=%d",
             CONFIG_ADHD_CLOUD_HOST,
             CONFIG_ADHD_CLOUD_PORT,
             Wireless_GetDeviceId(),
             CONFIG_ADHD_CLOUD_POLL_WAIT_S);

    s_resp_len = 0;
    s_resp_buf[0] = '\0';

    esp_http_client_config_t cfg = {
        .url = url,
        .method = HTTP_METHOD_GET,
        .event_handler = http_event_handler,
        /* 给服务器最多 hold N 秒；这里再加 5 秒余量等响应 */
        .timeout_ms = (CONFIG_ADHD_CLOUD_POLL_WAIT_S + 5) * 1000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        ESP_LOGE(TAG, "http_client init failed");
        vTaskDelay(pdMS_TO_TICKS(3000));
        return;
    }

    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        ESP_LOGW(TAG, "poll err: %s (status=%d)", esp_err_to_name(err), status);
        vTaskDelay(pdMS_TO_TICKS(2000));
        return;
    }

    s_last_success_ms = now_ms();

    if (status == 200) {
        ESP_LOGI(TAG, "cmd %u bytes", (unsigned)s_resp_len);
        parse_and_dispatch(s_resp_buf, s_resp_len);
    } else if (status == 204) {
        /* 服务器 hold 超时无命令，立即下一轮 */
    } else {
        ESP_LOGW(TAG, "unexpected status=%d body=%.*s",
                 status, (int)s_resp_len, s_resp_buf);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

static void announce_once(void)
{
    char url[160];
    snprintf(url, sizeof(url),
             "http://%s:%d/device/esp32/announce",
             CONFIG_ADHD_CLOUD_HOST,
             CONFIG_ADHD_CLOUD_PORT);

    char body[160];
    snprintf(body, sizeof(body),
             "{\"device_id\":\"%s\",\"kind\":\"esp32-s3-lcd-1.47B\"}",
             Wireless_GetDeviceId());

    esp_http_client_config_t cfg = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 5000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        return;
    }
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, body, (int)strlen(body));
    (void)esp_http_client_perform(client);
    esp_http_client_cleanup(client);
}

static void cloud_task(void *arg)
{
    (void)arg;

    /* 等 WiFi 上线 */
    while (Wireless_State != WIRELESS_STATE_CONNECTED) {
        vTaskDelay(pdMS_TO_TICKS(500));
    }

    ESP_LOGI(TAG, "STA up, announce + poll (%s:%d, device=%s)",
             CONFIG_ADHD_CLOUD_HOST, CONFIG_ADHD_CLOUD_PORT,
             Wireless_GetDeviceId());

    announce_once();

    while (1) {
        if (Wireless_State != WIRELESS_STATE_CONNECTED) {
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        poll_once();
        /* 紧跟下一轮，但留点窗口防 100% CPU */
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void Cloud_Start(void)
{
    xTaskCreatePinnedToCore(cloud_task, "cloud_poll", 6144, NULL, 4, NULL, 0);
}
