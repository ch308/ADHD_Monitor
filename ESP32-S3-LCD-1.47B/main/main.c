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

void Driver_Loop(void *parameter)
{
    Wireless_Init();
    while(1)
    {
        QMI8658_Loop();
        BAT_Get_Volts();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    vTaskDelete(NULL);
}

/* LVGL 渲染/触摸循环：单独一个任务，固定到核心 1。
 * 这样核心 0 让给 WiFi/BLE/Driver_Loop，避免 UI 把无线协议栈饿死。
 *  - wait_ms 上限放宽到 100 ms：LVGL 无事可做时 CPU 真正能睡满；
 *    琥珀全屏动画时 lv_timer_handler 会返回小值，loop 自然提高频率。
 *  - wait_ms 下限保持 5 ms，避免极端情况下空跑 0 ms 把核心打满。 */
static void Lvgl_Loop(void *parameter)
{
    const uint32_t WAIT_MAX_MS = 100;
    const uint32_t WAIT_MIN_MS = 5;
    while (1) {
        uint32_t wait_ms = lv_timer_handler();
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
    LVGL_Init();   // returns the screen object

/********************* Demo *********************/
    Lvgl_Example1();
    Backlight_Example();

    // lv_demo_widgets();
    // lv_demo_keypad_encoder();
    // lv_demo_benchmark();
    // lv_demo_stress();
    // lv_demo_music();

    Simulated_Touch_Init();

    /* 板载 GPIO38 RGB：倒计时与宁静蓝呼吸为两个独立任务，便于 BLE 分别启停 */
    RGB_Start_Countdown_Task();
    RGB_Start_Breathing_Task();

    xTaskCreatePinnedToCore(
        Driver_Loop, 
        "Other Driver task",
        4096, 
        NULL, 
        3, 
        NULL, 
        0);

    /* LVGL 渲染挂在核心 1，无线/传感器/电池任务留在核心 0。
     * 栈给到 8 KB，琥珀全屏动画 + 字体渲染下不会爆栈。 */
    xTaskCreatePinnedToCore(
        Lvgl_Loop,
        "LVGL task",
        8192,
        NULL,
        2,
        NULL,
        1);

    /* app_main 结束后 idle task 会回收它，无需再 while(1) 占用核心 0 */
}
