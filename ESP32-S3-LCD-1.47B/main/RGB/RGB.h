#pragma once

#include <stdint.h>

/** 板载 WS2812 类 RGB，常见接在 GPIO38 */
#define BLINK_GPIO 38

/** 倒计时总时长 10 s（与下述三段边界之和一致） */
#define RGB_COUNTDOWN_TOTAL_MS   10000
#define RGB_COUNTDOWN_STEP_MS    50
/** 一轮结束后的停顿，再开始下一轮（便于 BLE 插入其它指令） */
#define RGB_COUNTDOWN_RESTART_MS 1000

/** 阶段边界：10–7 s → 0–4 s；6–4 s → 4–7 s；3–1 s → 7–10 s */
#define RGB_PHASE_BLUE_END_MS    4000
#define RGB_PHASE_AMBER_END_MS   7000
#define RGB_PHASE_CORAL_END_MS   10000

/** 时间到：薄荷绿单次亮起时长，随后熄灭 */
#define RGB_MINT_FLASH_MS        280

/**
 * 实机常见 WS2812 绿芯偏亮：对写入的 G 做比例衰减，100=不改，越小越不绿。
 * 仍偏绿可再降到 60；偏品红则略调高到 80+。
 */
#define RGB_GREEN_GAIN_PERCENT   70

void RGB_Init(void);
void Set_RGB(uint8_t red_val, uint8_t green_val, uint8_t blue_val);

/** 独立 FreeRTOS 任务：10 s 分段倒计时 + 结束闪一次薄荷绿，循环 */
void RGB_Start_Countdown_Task(void);

/** 独立 FreeRTOS 任务：宁静蓝慢呼吸（倒计时占用灯时自动暂停） */
void RGB_Start_Breathing_Task(void);

/** 兼容旧名：仅启动倒计时任务 */
void RGB_Example(void);
