#include "Wireless.h"

#include "esp_mac.h"
#include "esp_http_client.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"

#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"

#include <stdio.h>
#include <string.h>

uint16_t BLE_NUM = 0;
uint16_t WIFI_NUM = 0;
bool Scan_finish = 0;

volatile bool WIFI_Sta_GotIp = false;
volatile bool WIFI_Sta_CaptivePortal = false;
volatile wireless_state_t Wireless_State = WIRELESS_STATE_BOOT;

static const char *WIFI_TAG = "wifi_sta";
static const char *PROV_TAG = "wifi_prov";

#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1
#define WIFI_MAX_RETRY     8

static EventGroupHandle_t s_wifi_event_group;
static int s_wifi_retry_num = 0;

static char s_device_id[9] = {0};       /* 8 hex chars + NUL */
static char s_prov_name[24] = {0};      /* "ADHD_XXXXXXXX" */

/* Provision scheme BLE 用的服务 UUID（128-bit）。Flutter 端扫到这个就连。
 * 这是一个固定 ADHD 项目自己的 UUID，便于 Flutter 端硬编码识别。
 * 字节顺序按 esp_ble_gap_set_raw_adv_data() 内部小端解释，最低字节先发。 */
static uint8_t s_prov_service_uuid[16] = {
    /* 项目自定义 UUID: ADHD0001-7F86-46AD-A02E-3CA5849DA5B6 */
    0xb6, 0xa5, 0x9d, 0x84, 0xa5, 0x3c, 0x2e, 0xa0,
    0xad, 0x46, 0x86, 0x7f, 0x01, 0x00, 0x48, 0xad,
};

static void wireless_make_ids(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id), "%02X%02X%02X%02X",
             mac[2], mac[3], mac[4], mac[5]);
    snprintf(s_prov_name, sizeof(s_prov_name), "ADHD_%s", s_device_id);
}

const char *Wireless_GetDeviceId(void)
{
    if (s_device_id[0] == 0) {
        wireless_make_ids();
    }
    return s_device_id;
}

const char *Wireless_GetProvServiceName(void)
{
    if (s_prov_name[0] == 0) {
        wireless_make_ids();
    }
    return s_prov_name;
}

/** 正常公网应返回 HTTP 204 且无正文；开放热点强制门户常返回 200/302 等 */
static bool wifi_probe_generate_204(void)
{
    esp_http_client_config_t cfg = {
        .url = "http://connectivitycheck.gstatic.com/generate_204",
        .timeout_ms = 8000,
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        return false;
    }

    esp_err_t err = esp_http_client_perform(client);
    int status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        ESP_LOGW(WIFI_TAG, "captive probe HTTP err: %s", esp_err_to_name(err));
        return false;
    }
    if (status != 204) {
        ESP_LOGW(WIFI_TAG, "captive probe: status=%d (expect 204)", status);
        return false;
    }
    return true;
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    (void)arg;

    if (event_base == WIFI_PROV_EVENT) {
        switch (event_id) {
            case WIFI_PROV_START:
                ESP_LOGI(PROV_TAG, "BLE provisioning started, name=%s", s_prov_name);
                Wireless_State = WIRELESS_STATE_PROVISIONING;
                break;
            case WIFI_PROV_CRED_RECV: {
                wifi_sta_config_t *cfg = (wifi_sta_config_t *)event_data;
                ESP_LOGI(PROV_TAG, "got creds, SSID=%s", (const char *)cfg->ssid);
                Wireless_State = WIRELESS_STATE_CONNECTING;
                break;
            }
            case WIFI_PROV_CRED_FAIL: {
                wifi_prov_sta_fail_reason_t *reason = (wifi_prov_sta_fail_reason_t *)event_data;
                ESP_LOGE(PROV_TAG, "creds failed, reason=%s",
                         (*reason == WIFI_PROV_STA_AUTH_ERROR) ? "AUTH" : "AP_NOT_FOUND");
                Wireless_State = WIRELESS_STATE_FAILED;
                /* 抛出 reset 让 manager 重新接受新的凭据 */
                wifi_prov_mgr_reset_sm_state_on_failure();
                break;
            }
            case WIFI_PROV_CRED_SUCCESS:
                ESP_LOGI(PROV_TAG, "creds accepted, applying");
                break;
            case WIFI_PROV_END:
                ESP_LOGI(PROV_TAG, "provisioning ended, releasing manager");
                wifi_prov_mgr_deinit();
                break;
            default:
                break;
        }
        return;
    }

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        Wireless_State = WIRELESS_STATE_CONNECTING;
        esp_wifi_connect();
        return;
    }

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        WIFI_Sta_GotIp = false;
        Wireless_State = WIRELESS_STATE_CONNECTING;
        if (s_wifi_retry_num < WIFI_MAX_RETRY) {
            esp_wifi_connect();
            s_wifi_retry_num++;
            ESP_LOGW(WIFI_TAG, "STA disconnected, retry %d/%d", s_wifi_retry_num, WIFI_MAX_RETRY);
        } else {
            if (s_wifi_event_group != NULL) {
                xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
            }
            Wireless_State = WIRELESS_STATE_FAILED;
        }
        return;
    }

    if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(WIFI_TAG, "got ip: " IPSTR, IP2STR(&event->ip_info.ip));
        s_wifi_retry_num = 0;
        WIFI_Sta_GotIp = true;
        if (wifi_probe_generate_204()) {
            WIFI_Sta_CaptivePortal = false;
            ESP_LOGI(WIFI_TAG, "internet probe OK");
        } else {
            WIFI_Sta_CaptivePortal = true;
            ESP_LOGW(WIFI_TAG, "captive portal suspected");
        }
        Wireless_State = WIRELESS_STATE_CONNECTED;
        if (s_wifi_event_group != NULL) {
            xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        }
        return;
    }
}

static void wireless_connect_with_nvs(void)
{
    s_wifi_retry_num = 0;
    Wireless_State = WIRELESS_STATE_CONNECTING;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    /* WIFI_EVENT_STA_START 回调会触发 esp_wifi_connect() */
}

void Wireless_Init(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    wireless_make_ids();

    xTaskCreatePinnedToCore(
        WIFI_Init,
        "WIFI task",
        8192,
        NULL,
        1,
        NULL,
        0);
}

void WIFI_Init(void *arg)
{
    (void)arg;

    s_wifi_event_group = xEventGroupCreate();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_PROV_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));

    /* 让 wifi_provisioning manager 帮我们看 NVS 里是否已经配过网。
     * 第一次刷机会一定是 false。 */
    wifi_prov_mgr_config_t pmgr_cfg = {
        .scheme = wifi_prov_scheme_ble,
        .scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM,
    };
    ESP_ERROR_CHECK(wifi_prov_mgr_init(pmgr_cfg));

    bool provisioned = false;
    ESP_ERROR_CHECK(wifi_prov_mgr_is_provisioned(&provisioned));

    if (!provisioned) {
        ESP_LOGI(PROV_TAG, "device not provisioned, start BLE provisioning");
        wifi_prov_scheme_ble_set_service_uuid(s_prov_service_uuid);
        ESP_ERROR_CHECK(wifi_prov_mgr_start_provisioning(
            WIFI_PROV_SECURITY_0, NULL, s_prov_name, NULL));
        /* 等 provision 完成、manager 自动 deinit 并触发 STA 连接 */
        wifi_prov_mgr_wait();
    } else {
        ESP_LOGI(PROV_TAG, "device already provisioned, releasing manager");
        wifi_prov_mgr_deinit();
        wireless_connect_with_nvs();
    }

    /* 阻塞直到连上或彻底失败，主要是为了同步 Wireless_State，
     * 但不让 BLE/Cloud 等其它任务也卡在这里。 */
    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_event_group,
        WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
        pdFALSE,
        pdFALSE,
        portMAX_DELAY);

    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(WIFI_TAG, "STA up, device_id=%s", s_device_id);
    } else {
        ESP_LOGE(WIFI_TAG, "STA failed, awaiting reset_provisioning");
    }

    WIFI_NUM = WIFI_Scan();
    BLE_NUM = 0;

    vTaskDelete(NULL);
}

uint16_t WIFI_Scan(void)
{
    /* 已经在 STA 模式，直接扫一次便于 UI 显示 AP 数量。
     * provisioning 期间 BLE 占用射频，扫描会失败，这里容错。 */
    uint16_t ap_count = 0;
    if (esp_wifi_scan_start(NULL, true) == ESP_OK) {
        esp_wifi_scan_get_ap_num(&ap_count);
        esp_wifi_scan_stop();
    }
    Scan_finish = 1;
    return ap_count;
}

/* BLE_Init / BLE_Scan：现在 BLE 由 wifi_provisioning + scheme_ble 接管，
 * 这里保留空壳，让 LVGL_Example 老逻辑能编。配网完成后 BTDM 控制器
 * 会被 WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM 释放掉。 */
void BLE_Init(void *arg) { (void)arg; vTaskDelete(NULL); }
uint16_t BLE_Scan(void) { return BLE_NUM; }

void Wireless_ResetProvisioning(void)
{
    ESP_LOGW(PROV_TAG, "resetting provisioning, will reboot");
    wifi_prov_mgr_reset_provisioning();
    /* 触发重启，下次开机直接进入 provisioning 状态 */
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
}
