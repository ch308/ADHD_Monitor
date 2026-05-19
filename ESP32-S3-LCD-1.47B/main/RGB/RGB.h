#pragma once

#include <stdint.h>
#include <stdbool.h>

/** 板载 WS2812 类 RGB，常见接在 GPIO38 */
#define BLINK_GPIO 38

/** 倒计时默认总时长 10 s（与下述三段边界之和一致） */
#define RGB_COUNTDOWN_TOTAL_MS   10000
#define RGB_COUNTDOWN_STEP_MS    50
/** 一轮结束后的停顿，再开始下一轮（便于云端插入其它指令） */
#define RGB_COUNTDOWN_RESTART_MS 1000

/** 阶段边界：10–7 s → 0–4 s；6–4 s → 4–7 s；3–1 s → 7–10 s */
#define RGB_PHASE_BLUE_END_MS    4000
#define RGB_PHASE_AMBER_END_MS   7000
#define RGB_PHASE_CORAL_END_MS   10000

/** 时间到：薄荷绿单次亮起时长，随后熄灭 */
#define RGB_MINT_FLASH_MS        280

/** 呼吸默认参数（可在运行时改） */
#define RGB_BREATH_DEFAULT_CYCLE_MS  8000

/**
 * 实机常见 WS2812 绿芯偏亮：对写入的 G 做比例衰减，100=不改，越小越不绿。
 * 仍偏绿可再降到 60；偏品红则略调高到 80+。
 */
#define RGB_GREEN_GAIN_PERCENT   70

void RGB_Init(void);
void Set_RGB(uint8_t red_val, uint8_t green_val, uint8_t blue_val);

/** 创建呼吸 / 倒计时 FreeRTOS 任务（幂等）。任务**创建后默认处于暂停**，
 *  必须显式调用 RGB_Start_Breathing / RGB_Start_Countdown 才会亮。 */
void RGB_Start_Breathing_Task(void);
void RGB_Start_Countdown_Task(void);

/** 启停 + 单次配置：可被云端命令调用。线程安全（内部用原子标志位）。 */
void RGB_Start_Breathing(uint32_t cycle_ms);   /* cycle_ms==0 时沿用上次/默认值 */
void RGB_Stop_Breathing(void);
void RGB_Start_Countdown(uint32_t total_ms);   /* total_ms==0 时沿用宏 RGB_COUNTDOWN_TOTAL_MS */
void RGB_Stop_Countdown(void);

/** 全部熄灭并暂停（开机/掉线/取消正念呼吸时调用） */
void RGB_All_Off(void);

/** 查询：是否有任一灯效正在跑（呼吸或倒计时） */
bool RGB_Is_Active(void);

/** 兼容旧名：仅启动倒计时任务（不再自动 enable） */
void RGB_Example(void);
