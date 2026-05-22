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
