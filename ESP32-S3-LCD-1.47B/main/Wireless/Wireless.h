#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_netif.h"

#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 显示用的"WiFi 扫到 N 个 / BLE 扫到 N 个"，保留兼容 LVGL_Example */
extern uint16_t BLE_NUM;
extern uint16_t WIFI_NUM;
extern bool Scan_finish;

/** STA 已拿到 IPv4（可能仍被强制门户拦截，需看 WIFI_Sta_CaptivePortal） */
extern volatile bool WIFI_Sta_GotIp;
/** 已联网但 generate_204 探测未通过：多为需浏览器二次认证的开放热点 */
extern volatile bool WIFI_Sta_CaptivePortal;

/** Provision 子系统状态，用于 UI 显示 */
typedef enum {
    WIRELESS_STATE_BOOT = 0,
    WIRELESS_STATE_PROVISIONING,
    WIRELESS_STATE_CONNECTING,
    WIRELESS_STATE_CONNECTED,
    WIRELESS_STATE_FAILED,
} wireless_state_t;

extern volatile wireless_state_t Wireless_State;

/** 8 字符设备 ID（efuse MAC 低 4 字节 hex），开机生成；
 *  BLE 广播名 / 云端 device_id 都用它。 */
const char *Wireless_GetDeviceId(void);

/** Provision 期间广播的 BLE 服务名（"ADHD_<DEVID>"），便于 Flutter 扫描 */
const char *Wireless_GetProvServiceName(void);

void Wireless_Init(void);
void WIFI_Init(void *arg);
uint16_t WIFI_Scan(void);
void BLE_Init(void *arg);
uint16_t BLE_Scan(void);

/** 由 Flutter 端"重新配网"按钮触发：清掉 NVS 凭据并重启进入 provisioning */
void Wireless_ResetProvisioning(void);

#ifdef __cplusplus
}
#endif
