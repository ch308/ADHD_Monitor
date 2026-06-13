#pragma once

/**
 * Path A integration with ADHD_Monitor Flask backend.
 *
 * - adhd_remote_cmd_seed_settings(): writes websocket.url / websocket.token /
 *   websocket.version into NVS from Kconfig (no OTA needed). Safe to call
 *   multiple times; runs only when CONFIG_ADHD_MONITOR_BYPASS_OTA is set.
 *
 * - adhd_remote_cmd_start(): launches the long-poll task that consumes
 *   /device/<MAC>/cmd queue items (xiaozhi_invoke_chat / xiaozhi_abort).
 *
 * - adhd_remote_cmd_announce_sync_once(): POST /device/esp32/announce on the
 *   caller task (blocking). Run once when activation completes so the Flask DB
 *   always has a row before the phone app polls esp32/list — avoids relying on
 *   a background task that may be delayed or missing in mismatched flashes.
 */
void adhd_remote_cmd_seed_settings(void);
void adhd_remote_cmd_announce_sync_once(void);
void adhd_remote_cmd_start(void);
void adhd_remote_cmd_start_default_proactive(void);

/// POST /device/<id>/autism/need-event（需 CONFIG_ADHD_MONITOR_REMOTE_CMD 或 BYPASS_OTA）。
bool adhd_post_autism_need_event(const char* card_slug, const char* label, const char* voice_text);

/// 确认当前训练/日常计划动态图片选择，并上报 /device/<id>/autism/training-event。
/// 返回 true 表示本次 BOOT/点击已被动态图片选择消费。
bool adhd_confirm_autism_choice(void);

/// 切换到下一张训练/日常计划动态图片；返回 true 表示摇晃事件已被消费。
bool adhd_next_autism_choice(void);

/// 选图界面已进入「省电黑屏」时：摇晃不应唤醒或切图（仅 BOOT 唤醒），供 MPU 任务先判断。
bool adhd_autism_choice_shake_blocked(void);
