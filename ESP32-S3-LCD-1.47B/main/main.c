/*
 * SPDX-FileCopyrightText: 2021-2022 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: CC0-1.0
 */

#include "ST7789.h"
#include "SD_MMC.h"
#include "Wireless.h"
#include "LVGL_Example.h"
#include "QMI8658.h"
#include "BAT_Driver.h"
#include "RGB.h"
#include "Cloud.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

void Driver_Loop(void *parameter)
{
    Wireless_Init();
    while (1) {
        QMI8658_Loop();
        BAT_Get_Volts();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    vTaskDelete(NULL);
}

/* LVGL 渲染/触摸循环：单独一个任务，固定到核心 1。
 * 这样核心 0 让给 WiFi/BLE/Driver_Loop，避免 UI 把无线协议栈饿死。 */
static void Lvgl_Loop(void *parameter)
{
    const uint32_t WAIT_MAX_MS = 100;
    const uint32_t WAIT_MIN_MS = 5;
    while (1) {
        uint32_t wait_ms = WAIT_MAX_MS;
        if (lvgl_port_lock(WAIT_MAX_MS)) {
            wait_ms = lv_timer_handler();
            lvgl_port_unlock();
        }
        if (wait_ms > WAIT_MAX_MS) {
            wait_ms = WAIT_MAX_MS;
        }
        if (wait_ms < WAIT_MIN_MS) {
            wait_ms = WAIT_MIN_MS;
        }
        vTaskDelay(pdMS_TO_TICKS(wait_ms));
    }
}

void app_main(void)
{
    Flash_Searching();
    button_Init();
    BAT_Init();
    I2C_Init();
    QMI8658_Init();
    SD_Init();
    LCD_Init();
    LVGL_Init();

    /* 初始进入"黑屏待命"：背光 0，等收到云端 breathing_start 时由 Cloud.c 拉亮。
     * 触摸/UI 框架仍然跑着，便于后续在 LVGL 上画"已联网"等状态。 */
    Backlight_Init();
    Set_Backlight(0);

    /* 创建呼吸 / 倒计时 RGB 任务（默认 idle，不点灯）；
     * 真正点亮的时机由 Cloud.c 收到云端命令后 RGB_Start_* 控制。 */
    RGB_Start_Countdown_Task();
    RGB_Start_Breathing_Task();
    RGB_All_Off();

    Simulated_Touch_Init();

    xTaskCreatePinnedToCore(
        Driver_Loop,
        "Driver task",
        4096,
        NULL,
        3,
        NULL,
        0);

    xTaskCreatePinnedToCore(
        Lvgl_Loop,
        "LVGL task",
        8192,
        NULL,
        2,
        NULL,
        1);

    /* 云端长轮询：会等 Wireless_State 到 CONNECTED 才开始 announce + poll */
    Cloud_Start();
}
