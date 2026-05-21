#pragma once

/**
 * ADHD Monitor BLE WiFi provisioning (xiaozhi 星星机器人).
 *
 * Mirrors the plush-ball ESP32-S3-LCD-1.47B flow exactly so the same Flutter
 * client (lib/services/esp_provision_service.dart) can drive both:
 *   - Service UUID : ad480001-7f86-46ad-a02e-3ca5849da5b6
 *   - Security     : 0 (no PoP, no DH); requires CONFIG_ESP_PROTOCOMM_SUPPORT_SECURITY_VERSION_0
 *   - Adv name     : "XIAOZHI_<8 hex MAC suffix>"
 *
 * adhd_prov_ble_start_blocking()
 *   Stops xiaozhi's WifiManager, initialises network_prov_mgr with scheme_ble,
 *   advertises, and blocks until NETWORK_PROV_END. On success it reboots the
 *   device so that WifiManager picks up the new credentials from NVS on next
 *   boot — keeping us out of the path xiaozhi's own state machine owns.
 *
 * adhd_prov_ble_reset_and_reboot()
 *   Cloud-side trigger (action=reset_provisioning): clear NVS WiFi credentials
 *   and reboot so the device re-enters provisioning advertising mode.
 *
 * Both functions are no-ops unless CONFIG_USE_ADHD_BLE_WIFI_PROVISIONING is set.
 */

#ifdef __cplusplus
extern "C" {
#endif

void adhd_prov_ble_start_blocking(void);
void adhd_prov_ble_reset_and_reboot(void);

#ifdef __cplusplus
}
#endif
