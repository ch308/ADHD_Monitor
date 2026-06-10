#include "wifi_board.h"
#include "codecs/no_audio_codec.h"
#include "display/lcd_display.h"
#include "system_reset.h"
#include "application.h"
#include "button.h"
#include "config.h"
#include "power_save_timer.h"
#include "led/single_led.h"
#include "assets/lang_config.h"
#include "power_manager.h"
#include "action_cards.h"

#include <esp_log.h>
#include <esp_err.h>
#include <esp_heap_caps.h>
#include <esp_lcd_panel_vendor.h>
#include <esp_lcd_panel_ops.h>
#include <wifi_manager.h>

#include <driver/i2c_master.h>
#include <driver/rtc_io.h>
#include <esp_timer.h>
#include <esp_sleep.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TAG "XINGZHI_CUBE_1_54TFT_WIFI"

#define MPU6050_ADDR 0x68
#define MPU6050_REG_ACCEL_XOUT_H 0x3B
#define MPU6050_REG_PWR_MGMT_1 0x6B
#define MPU6050_REG_WHO_AM_I 0x75
// One motion burst must exceed this (sum of |dax|+|day|+|daz| per 50 ms sample).
// Raised so small bumps do not count; still need two bursts (see shake_pair_* below).
#define MPU6050_SHAKE_DELTA_THRESHOLD 24000
// After a successful switch, ignore starting a new two-shake sequence for this long.
#define MPU6050_SHAKE_COOLDOWN_US 600000
// Two-shake: first burst, then a quiet sample, then second burst within this window.
#define MPU6050_SHAKE_QUIET_THRESHOLD 10000
#define MPU6050_SHAKE_PAIR_MAX_US 1500000
// Second burst must be at least this long after we see "quiet" following the first burst.
#define MPU6050_SHAKE_PAIR_SECOND_MIN_US 120000
// Double knock: stronger impulse than shake, then quiet, then second impulse (no touch panel).
#define MPU6050_KNOCK_DELTA_THRESHOLD 28000
#define MPU6050_KNOCK_QUIET_THRESHOLD 12000
#define MPU6050_DOUBLE_KNOCK_MIN_US 100000
#define MPU6050_DOUBLE_KNOCK_MAX_US 550000

class XINGZHI_CUBE_1_54TFT_WIFI : public WifiBoard {
private:
    Button boot_button_;
    Button volume_up_button_;
    Button volume_down_button_;
    SpiLcdDisplay* display_;
    PowerSaveTimer* power_save_timer_;
    PowerManager* power_manager_;
    esp_lcd_panel_io_handle_t panel_io_ = nullptr;
    esp_lcd_panel_handle_t panel_ = nullptr;
    i2c_master_bus_handle_t mpu_i2c_bus_ = nullptr;
    i2c_master_dev_handle_t mpu6050_ = nullptr;
    bool app_sleep_lcd_off_ = false;
    bool mpu6050_ready_ = false;
    uint8_t mpu6050_who_am_i_ = 0;
    uint8_t mpu6050_addr_ = MPU6050_ADDR;
    esp_err_t mpu6050_init_err_ = ESP_FAIL;
    int16_t mpu6050_initial_ax_ = 0;
    int16_t mpu6050_initial_ay_ = 0;
    int16_t mpu6050_initial_az_ = 0;
    bool mpu6050_initial_accel_valid_ = false;
    TaskHandle_t mpu6050_task_ = nullptr;
    int mpu_dk_state_ = 0;
    int64_t mpu_dk_t0_us_ = 0;

    void InitializePowerManager() {
        power_manager_ = new PowerManager(GPIO_NUM_38);
        power_manager_->OnChargingStatusChanged([this](bool is_charging) {
            if (is_charging) {
                power_save_timer_->SetEnabled(false);
            } else {
                power_save_timer_->SetEnabled(true);
            }
        });
    }

    void InitializePowerSaveTimer() {
        rtc_gpio_init(GPIO_NUM_21);
        rtc_gpio_set_direction(GPIO_NUM_21, RTC_GPIO_MODE_OUTPUT_ONLY);
        rtc_gpio_set_level(GPIO_NUM_21, 1);

        power_save_timer_ = new PowerSaveTimer(-1, 60, 300);
        power_save_timer_->OnEnterSleepMode([this]() {
            GetDisplay()->SetPowerSaveMode(true);
            GetBacklight()->SetBrightness(1);
        });
        power_save_timer_->OnExitSleepMode([this]() {
            GetDisplay()->SetPowerSaveMode(false);
            GetBacklight()->RestoreBrightness();
        });
        power_save_timer_->OnShutdownRequest([this]() {
            ESP_LOGI(TAG, "Shutting down");
            rtc_gpio_set_level(GPIO_NUM_21, 0);
            // 启用保持功能，确保睡眠期间电平不变
            rtc_gpio_hold_en(GPIO_NUM_21);
            esp_lcd_panel_disp_on_off(panel_, false); //关闭显示
            esp_deep_sleep_start();
        });
        power_save_timer_->SetEnabled(true);
    }

    void InitializeSpi() {
        spi_bus_config_t buscfg = {};
        buscfg.mosi_io_num = DISPLAY_SDA;
        buscfg.miso_io_num = GPIO_NUM_NC;
        buscfg.sclk_io_num = DISPLAY_SCL;
        buscfg.quadwp_io_num = GPIO_NUM_NC;
        buscfg.quadhd_io_num = GPIO_NUM_NC;
        buscfg.max_transfer_sz = DISPLAY_WIDTH * DISPLAY_HEIGHT * sizeof(uint16_t);
        ESP_ERROR_CHECK(spi_bus_initialize(SPI3_HOST, &buscfg, SPI_DMA_CH_AUTO));
    }

    void InitializeButtons() {
        boot_button_.OnClick([this]() {
            power_save_timer_->WakeUp();
            // While the action-cards slideshow is running, a click steps to the
            // next picture instead of toggling the chat.
            if (ActionCards::GetInstance().IsActive()) {
                ActionCards::GetInstance().Next();
                return;
            }
            auto& app = Application::GetInstance();
            if (app.GetDeviceState() == kDeviceStateStarting) {
                EnterWifiConfigMode();
                return;
            }
            app.ToggleChatState();
        });

        boot_button_.OnLongPress([this]() {
            power_save_timer_->WakeUp();
            // Long-press enters/leaves the action-cards slideshow.
            ActionCards::GetInstance().Toggle();
        });

        volume_up_button_.OnClick([this]() {
            power_save_timer_->WakeUp();
            auto codec = GetAudioCodec();
            auto volume = codec->output_volume() + 10;
            if (volume > 100) {
                volume = 100;
            }
            codec->SetOutputVolume(volume);
            GetDisplay()->ShowNotification(Lang::Strings::VOLUME + std::to_string(volume));
        });

        volume_up_button_.OnLongPress([this]() {
            power_save_timer_->WakeUp();
            GetAudioCodec()->SetOutputVolume(100);
            GetDisplay()->ShowNotification(Lang::Strings::MAX_VOLUME);
        });

        volume_down_button_.OnClick([this]() {
            power_save_timer_->WakeUp();
            auto codec = GetAudioCodec();
            auto volume = codec->output_volume() - 10;
            if (volume < 0) {
                volume = 0;
            }
            codec->SetOutputVolume(volume);
            GetDisplay()->ShowNotification(Lang::Strings::VOLUME + std::to_string(volume));
        });

        volume_down_button_.OnLongPress([this]() {
            power_save_timer_->WakeUp();
            GetAudioCodec()->SetOutputVolume(0);
            GetDisplay()->ShowNotification(Lang::Strings::MUTED);
        });
    }

    void InitializeSt7789Display() {
        ESP_LOGD(TAG, "Install panel IO");
        esp_lcd_panel_io_spi_config_t io_config = {};
        io_config.cs_gpio_num = DISPLAY_CS;
        io_config.dc_gpio_num = DISPLAY_DC;
        io_config.spi_mode = 3;
        io_config.pclk_hz = 80 * 1000 * 1000;
        io_config.trans_queue_depth = 10;
        io_config.lcd_cmd_bits = 8;
        io_config.lcd_param_bits = 8;
        ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(SPI3_HOST, &io_config, &panel_io_));

        ESP_LOGD(TAG, "Install LCD driver");
        esp_lcd_panel_dev_config_t panel_config = {};
        panel_config.reset_gpio_num = DISPLAY_RES;
        panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
        panel_config.bits_per_pixel = 16;
        ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(panel_io_, &panel_config, &panel_));
        ESP_ERROR_CHECK(esp_lcd_panel_reset(panel_));
        ESP_ERROR_CHECK(esp_lcd_panel_init(panel_));
        ESP_ERROR_CHECK(esp_lcd_panel_swap_xy(panel_, DISPLAY_SWAP_XY));
        ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel_, DISPLAY_MIRROR_X, DISPLAY_MIRROR_Y));
        ESP_ERROR_CHECK(esp_lcd_panel_invert_color(panel_, true));
        ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel_, true));

        display_ = new SpiLcdDisplay(panel_io_, panel_, DISPLAY_WIDTH, DISPLAY_HEIGHT, DISPLAY_OFFSET_X, DISPLAY_OFFSET_Y, 
            DISPLAY_MIRROR_X, DISPLAY_MIRROR_Y, DISPLAY_SWAP_XY);
    }

    void RunDisplaySelfTest() {
        ESP_LOGI(TAG, "LCD self-test: backlight=100%%, panel on, RGBW color fill");
        ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel_, true));
        GetBacklight()->SetBrightness(100);
        vTaskDelay(pdMS_TO_TICKS(150));

        const int stripe_height = 40;
        uint16_t* stripe = static_cast<uint16_t*>(heap_caps_malloc(
            DISPLAY_WIDTH * stripe_height * sizeof(uint16_t), MALLOC_CAP_DMA | MALLOC_CAP_8BIT));
        if (stripe == nullptr) {
            ESP_LOGE(TAG, "LCD self-test: failed to allocate DMA stripe buffer");
            return;
        }

        // RGB565 test colors: red, green, blue, white. If only the backlight turns on,
        // the SPI path or LCD controller init is still suspect.
        const uint16_t colors[] = {0xF800, 0x07E0, 0x001F, 0xFFFF};
        for (uint16_t color : colors) {
            for (int i = 0; i < DISPLAY_WIDTH * stripe_height; ++i) {
                stripe[i] = color;
            }
            for (int y = 0; y < DISPLAY_HEIGHT; y += stripe_height) {
                const int y_end = (y + stripe_height > DISPLAY_HEIGHT) ? DISPLAY_HEIGHT : (y + stripe_height);
                esp_err_t err = esp_lcd_panel_draw_bitmap(panel_, 0, y, DISPLAY_WIDTH, y_end, stripe);
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "LCD self-test: draw failed at y=%d err=%s", y, esp_err_to_name(err));
                    heap_caps_free(stripe);
                    return;
                }
            }
            vTaskDelay(pdMS_TO_TICKS(250));
        }

        heap_caps_free(stripe);
        GetBacklight()->RestoreBrightness();
        ESP_LOGI(TAG, "LCD self-test finished");
    }

    esp_err_t Mpu6050WriteReg(uint8_t reg, uint8_t value) {
        uint8_t buffer[2] = {reg, value};
        return i2c_master_transmit(mpu6050_, buffer, sizeof(buffer), 100);
    }

    esp_err_t Mpu6050ReadRegs(uint8_t reg, uint8_t* buffer, size_t len) {
        return i2c_master_transmit_receive(mpu6050_, &reg, 1, buffer, len, 100);
    }

    bool Mpu6050ReadAccel(int16_t& ax, int16_t& ay, int16_t& az) {
        uint8_t buffer[6] = {};
        esp_err_t err = Mpu6050ReadRegs(MPU6050_REG_ACCEL_XOUT_H, buffer, sizeof(buffer));
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "MPU6050 accel read failed: %s", esp_err_to_name(err));
            return false;
        }

        ax = static_cast<int16_t>((buffer[0] << 8) | buffer[1]);
        ay = static_cast<int16_t>((buffer[2] << 8) | buffer[3]);
        az = static_cast<int16_t>((buffer[4] << 8) | buffer[5]);
        return true;
    }

    void Mpu6050ScanBus() {
        // Probe the whole 7-bit address range so we can tell whether ANY device
        // is electrically present on the bus (helps distinguish wiring problems
        // from a wrong/clone address).
        int found = 0;
        for (uint8_t addr = 0x08; addr <= 0x77; addr++) {
            if (i2c_master_probe(mpu_i2c_bus_, addr, 50) == ESP_OK) {
                found++;
                ESP_LOGI(TAG, "I2C scan: device responded at 0x%02x", addr);
            }
        }
        if (found == 0) {
            ESP_LOGW(TAG, "I2C scan: no devices found on SDA=%d SCL=%d "
                          "(check wiring/power/pull-ups)", MPU6050_I2C_SDA, MPU6050_I2C_SCL);
        }
    }

    void InitializeMpu6050() {
        mpu6050_init_err_ = ESP_FAIL;
        i2c_master_bus_config_t bus_config = {};
        bus_config.i2c_port = I2C_NUM_0;
        bus_config.sda_io_num = MPU6050_I2C_SDA;
        bus_config.scl_io_num = MPU6050_I2C_SCL;
        bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
        bus_config.glitch_ignore_cnt = 7;
        bus_config.flags.enable_internal_pullup = true;

        esp_err_t err = i2c_new_master_bus(&bus_config, &mpu_i2c_bus_);
        if (err != ESP_OK) {
            mpu6050_init_err_ = err;
            ESP_LOGW(TAG, "MPU6050 I2C bus init failed: %s", esp_err_to_name(err));
            return;
        }

        // List everything that ACKs first; this output is the key diagnostic.
        Mpu6050ScanBus();

        // The MPU6050 lives at 0x68 (AD0 low) or 0x69 (AD0 high). Pick whichever
        // actually acknowledges on the bus.
        uint8_t candidates[] = {0x68, 0x69};
        uint8_t addr = 0;
        for (uint8_t c : candidates) {
            if (i2c_master_probe(mpu_i2c_bus_, c, 50) == ESP_OK) {
                addr = c;
                break;
            }
        }
        if (addr == 0) {
            mpu6050_init_err_ = ESP_ERR_NOT_FOUND;
            ESP_LOGW(TAG, "MPU6050 did not ACK at 0x68/0x69 on SDA=%d SCL=%d "
                          "(no response - check VCC/GND/SDA/SCL wiring)",
                     MPU6050_I2C_SDA, MPU6050_I2C_SCL);
            return;
        }
        mpu6050_addr_ = addr;

        i2c_device_config_t dev_config = {};
        dev_config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
        dev_config.device_address = addr;
        // Use 100 kHz: the ESP32 internal pull-ups are weak (~45 kOhm), so a slower
        // bus is far more tolerant when there are no dedicated external pull-ups.
        dev_config.scl_speed_hz = 100 * 1000;

        err = i2c_master_bus_add_device(mpu_i2c_bus_, &dev_config, &mpu6050_);
        if (err != ESP_OK) {
            mpu6050_init_err_ = err;
            ESP_LOGW(TAG, "MPU6050 add device failed: %s", esp_err_to_name(err));
            return;
        }

        // The bus can be noisy on the first transaction; retry the WHO_AM_I read.
        uint8_t who_am_i = 0;
        for (int attempt = 0; attempt < 5; attempt++) {
            err = Mpu6050ReadRegs(MPU6050_REG_WHO_AM_I, &who_am_i, 1);
            if (err == ESP_OK && (who_am_i == 0x68 || who_am_i == 0x69)) {
                break;
            }
            ESP_LOGW(TAG, "MPU6050 WHO_AM_I attempt %d: who=0x%02x err=%s",
                     attempt, who_am_i, esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        mpu6050_who_am_i_ = who_am_i;
        if (err != ESP_OK || (who_am_i != 0x68 && who_am_i != 0x69)) {
            mpu6050_init_err_ = err != ESP_OK ? err : ESP_ERR_INVALID_RESPONSE;
            ESP_LOGW(TAG, "MPU6050 found at 0x%02x but WHO_AM_I invalid: who=0x%02x err=%s",
                     addr, who_am_i, esp_err_to_name(mpu6050_init_err_));
            return;
        }

        ESP_ERROR_CHECK(Mpu6050WriteReg(MPU6050_REG_PWR_MGMT_1, 0x00));
        vTaskDelay(pdMS_TO_TICKS(100));
        mpu6050_initial_accel_valid_ = Mpu6050ReadAccel(mpu6050_initial_ax_, mpu6050_initial_ay_, mpu6050_initial_az_);
        mpu6050_ready_ = true;
        mpu6050_init_err_ = ESP_OK;
        ESP_LOGI(TAG, "MPU6050 SELFTEST OK: SDA=%d SCL=%d addr=0x%02x who=0x%02x accel=(%d,%d,%d)",
                 MPU6050_I2C_SDA, MPU6050_I2C_SCL, addr, mpu6050_who_am_i_,
                 mpu6050_initial_ax_, mpu6050_initial_ay_, mpu6050_initial_az_);
    }

    void ShowMpu6050ValidationResult() {
        char message[96];
        if (mpu6050_ready_) {
            snprintf(message, sizeof(message), "MPU6050 OK\naddr=0x%02X WHO=0x%02X\n摇两下换图 敲两下确认",
                     mpu6050_addr_, mpu6050_who_am_i_);
        } else {
            snprintf(message, sizeof(message), "MPU6050 FAIL\nSDA=12 SCL=11\ncheck wiring: %s",
                     esp_err_to_name(mpu6050_init_err_));
        }
        GetDisplay()->ShowNotification(message, 5000);
    }

    void StartMpu6050Task() {
        if (!mpu6050_ready_ || mpu6050_task_ != nullptr) {
            return;
        }

        xTaskCreate([](void* arg) {
            auto* board = static_cast<XINGZHI_CUBE_1_54TFT_WIFI*>(arg);
            int16_t last_ax = 0;
            int16_t last_ay = 0;
            int16_t last_az = 0;
            int64_t last_switch_us = 0;
            int shake_pair_state = 0;
            int64_t shake_pair_t0_us = 0;
            int64_t shake_pair_arm_us = 0;

            if (!board->Mpu6050ReadAccel(last_ax, last_ay, last_az)) {
                board->mpu6050_task_ = nullptr;
                vTaskDelete(nullptr);
                return;
            }

            while (true) {
                vTaskDelay(pdMS_TO_TICKS(50));

                int16_t ax = 0;
                int16_t ay = 0;
                int16_t az = 0;
                if (!board->Mpu6050ReadAccel(ax, ay, az)) {
                    continue;
                }

                int delta = abs(static_cast<int>(ax) - static_cast<int>(last_ax)) +
                            abs(static_cast<int>(ay) - static_cast<int>(last_ay)) +
                            abs(static_cast<int>(az) - static_cast<int>(last_az));
                last_ax = ax;
                last_ay = ay;
                last_az = az;

                int64_t now_us = esp_timer_get_time();

                auto& cards = ActionCards::GetInstance();

                // Double knock on the case (MPU6050) to confirm the current card when
                // action cards are active — works without a touch panel.
                if (board->mpu6050_ready_ && cards.IsActive()) {
                    if (board->mpu_dk_state_ == 0) {
                        if (delta >= MPU6050_KNOCK_DELTA_THRESHOLD) {
                            board->mpu_dk_state_ = 1;
                            board->mpu_dk_t0_us_ = now_us;
                        }
                    } else if (board->mpu_dk_state_ == 1) {
                        if (now_us - board->mpu_dk_t0_us_ > MPU6050_DOUBLE_KNOCK_MAX_US) {
                            board->mpu_dk_state_ = 0;
                        } else if (delta < MPU6050_KNOCK_QUIET_THRESHOLD) {
                            board->mpu_dk_state_ = 2;
                        }
                    } else {
                        if (now_us - board->mpu_dk_t0_us_ > MPU6050_DOUBLE_KNOCK_MAX_US) {
                            board->mpu_dk_state_ = 0;
                        } else if (delta >= MPU6050_KNOCK_DELTA_THRESHOLD &&
                                   (now_us - board->mpu_dk_t0_us_) >= MPU6050_DOUBLE_KNOCK_MIN_US) {
                            board->power_save_timer_->WakeUp();
                            cards.ConfirmSelection();
                            board->GetDisplay()->ShowNotification("敲两下 已确认", 900);
                            ESP_LOGI(TAG, "MPU6050 double knock confirm, delta=%d", delta);
                            last_switch_us = now_us;
                            board->mpu_dk_state_ = 0;
                            continue;
                        }
                    }
                } else {
                    board->mpu_dk_state_ = 0;
                }

                if (board->mpu_dk_state_ != 0) {
                    shake_pair_state = 0;
                    continue;
                }

                if (now_us - last_switch_us < MPU6050_SHAKE_COOLDOWN_US) {
                    continue;
                }

                // Two distinct shake motions (burst -> quiet -> burst) before switching.
                if (shake_pair_state == 0) {
                    if (delta >= MPU6050_SHAKE_DELTA_THRESHOLD) {
                        shake_pair_state = 1;
                        shake_pair_t0_us = now_us;
                    }
                } else if (shake_pair_state == 1) {
                    if (now_us - shake_pair_t0_us > MPU6050_SHAKE_PAIR_MAX_US) {
                        shake_pair_state = 0;
                    } else if (delta < MPU6050_SHAKE_QUIET_THRESHOLD) {
                        shake_pair_state = 2;
                        shake_pair_arm_us = now_us;
                    }
                } else {
                    if (now_us - shake_pair_t0_us > MPU6050_SHAKE_PAIR_MAX_US) {
                        shake_pair_state = 0;
                    } else if (delta >= MPU6050_SHAKE_DELTA_THRESHOLD &&
                               (now_us - shake_pair_arm_us) >= MPU6050_SHAKE_PAIR_SECOND_MIN_US) {
                        last_switch_us = now_us;
                        shake_pair_state = 0;
                        board->power_save_timer_->WakeUp();
                        if (cards.IsActive()) {
                            cards.Next();
                        } else {
                            cards.Toggle();
                        }
                        board->GetDisplay()->ShowNotification("MPU6050 摇两下", 1000);
                        ESP_LOGI(TAG, "MPU6050 double-shake switch, delta=%d accel=(%d,%d,%d)",
                                 delta, ax, ay, az);
                    }
                }
            }
        }, "mpu6050", 4096, this, 4, &mpu6050_task_);
    }

public:
    XINGZHI_CUBE_1_54TFT_WIFI() :
        boot_button_(BOOT_BUTTON_GPIO),
        volume_up_button_(VOLUME_UP_BUTTON_GPIO),
        volume_down_button_(VOLUME_DOWN_BUTTON_GPIO) {
        InitializePowerManager();
        InitializePowerSaveTimer();
        InitializeSpi();
        InitializeButtons();
        InitializeSt7789Display();
        InitializeMpu6050();
        RunDisplaySelfTest();
    }

    virtual void StartNetwork() override {
        auto& wifi_manager = WifiManager::GetInstance();

        WifiManagerConfig config;
        config.ssid_prefix = "Xiaozhi";
        config.language = Lang::CODE;
        wifi_manager.Initialize(config);
        wifi_manager.SetEventCallback([this](WifiEvent event, const std::string& data) {
            switch (event) {
                case WifiEvent::Scanning:
                    OnNetworkEvent(NetworkEvent::Scanning);
                    break;
                case WifiEvent::Connecting:
                    OnNetworkEvent(NetworkEvent::Connecting, data);
                    break;
                case WifiEvent::Connected:
                    OnNetworkEvent(NetworkEvent::Connected, data);
                    break;
                case WifiEvent::Disconnected:
                    OnNetworkEvent(NetworkEvent::Disconnected);
                    break;
                case WifiEvent::ConfigModeEnter:
                    OnNetworkEvent(NetworkEvent::WifiConfigModeEnter);
                    break;
                case WifiEvent::ConfigModeExit:
                    OnNetworkEvent(NetworkEvent::WifiConfigModeExit);
                    break;
            }
        });

        ESP_LOGI(TAG, "Skipping automatic WiFi provisioning; showing action cards by default");
        xTaskCreate([](void*) {
            vTaskDelay(pdMS_TO_TICKS(300));
            auto& cards = ActionCards::GetInstance();
            if (!cards.IsActive()) {
                cards.Toggle();
            }
            vTaskDelete(nullptr);
        }, "show_cards", 3072, nullptr, 2, nullptr);
        xTaskCreate([](void* arg) {
            auto* board = static_cast<XINGZHI_CUBE_1_54TFT_WIFI*>(arg);
            vTaskDelay(pdMS_TO_TICKS(800));
            board->ShowMpu6050ValidationResult();
            vTaskDelete(nullptr);
        }, "mpu6050_report", 3072, this, 2, nullptr);
        StartMpu6050Task();
    }

    virtual AudioCodec* GetAudioCodec() override {
        static NoAudioCodecSimplex audio_codec(AUDIO_INPUT_SAMPLE_RATE, AUDIO_OUTPUT_SAMPLE_RATE,
            AUDIO_I2S_SPK_GPIO_BCLK, AUDIO_I2S_SPK_GPIO_LRCK, AUDIO_I2S_SPK_GPIO_DOUT, AUDIO_I2S_MIC_GPIO_SCK, AUDIO_I2S_MIC_GPIO_WS, AUDIO_I2S_MIC_GPIO_DIN);
        return &audio_codec;
    }

    virtual Display* GetDisplay() override {
        return display_;
    }
    
    virtual Backlight* GetBacklight() override {
        static PwmBacklight backlight(DISPLAY_BACKLIGHT_PIN, DISPLAY_BACKLIGHT_OUTPUT_INVERT);
        return &backlight;
    }

    virtual bool GetBatteryLevel(int& level, bool& charging, bool& discharging) override {
        static bool last_discharging = false;
        charging = power_manager_->IsCharging();
        discharging = power_manager_->IsDischarging();
        if (discharging != last_discharging) {
            power_save_timer_->SetEnabled(discharging);
            last_discharging = discharging;
        }
        level = power_manager_->GetBatteryLevel();
        return true;
    }

    virtual void SetPowerSaveLevel(PowerSaveLevel level) override {
        if (level != PowerSaveLevel::LOW_POWER) {
            power_save_timer_->WakeUp();
        }
        WifiBoard::SetPowerSaveLevel(level);
    }

    virtual void SetApplicationSleepDisplayDimmed(bool dimmed) override {
        if (panel_ == nullptr) {
            Board::SetApplicationSleepDisplayDimmed(dimmed);
            return;
        }
        if (dimmed) {
            if (!app_sleep_lcd_off_) {
                GetBacklight()->SetBrightness(0);
                esp_lcd_panel_disp_on_off(panel_, false);
                app_sleep_lcd_off_ = true;
            }
        } else {
            if (app_sleep_lcd_off_) {
                esp_lcd_panel_disp_on_off(panel_, true);
                app_sleep_lcd_off_ = false;
            }
            Board::SetApplicationSleepDisplayDimmed(false);
        }
    }
};

DECLARE_BOARD(XINGZHI_CUBE_1_54TFT_WIFI);
