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
 */
void adhd_remote_cmd_seed_settings(void);
void adhd_remote_cmd_start(void);
