#pragma once

#include <stdbool.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "esp_wifi.h"
#include "nvs_flash.h" 
#include "esp_log.h"

#include <stdio.h>
#include <string.h>  // For memcpy
#include "esp_system.h"
#include "esp_bt.h"
#include "esp_gap_ble_api.h"
#include "esp_bt_main.h"



extern uint16_t BLE_NUM;
extern uint16_t WIFI_NUM;
extern bool Scan_finish;

/** STA 已拿到 IPv4（可能仍被强制门户拦截，需看 WIFI_Sta_CaptivePortal） */
extern volatile bool WIFI_Sta_GotIp;
/** 已联网但探测未通过：多为需浏览器二次认证的开放热点（强制门户） */
extern volatile bool WIFI_Sta_CaptivePortal;

void Wireless_Init(void);
void WIFI_Init(void *arg);
uint16_t WIFI_Scan(void);
void BLE_Init(void *arg);
uint16_t BLE_Scan(void);