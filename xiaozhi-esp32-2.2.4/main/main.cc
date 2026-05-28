/*
 * Minimal LCD test - uses custom Vernon ST7789T driver matching the
 * ESP32-S3-LCD-1.47B hardware.
 */

#include <esp_log.h>
#include <esp_err.h>
#include <nvs_flash.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <driver/ledc.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_vendor.h>
#include <esp_lcd_panel_ops.h>

static const char *TAG = "LCD_TEST";

// Pinout matches ESP32-S3-LCD-1.47B (verified against working ST7789.c)
#define PIN_SCLK    GPIO_NUM_40
#define PIN_MOSI    GPIO_NUM_45
#define PIN_MISO    GPIO_NUM_NC
#define PIN_DC      GPIO_NUM_41
#define PIN_RST     GPIO_NUM_39
#define PIN_CS      GPIO_NUM_42
#define PIN_BK      GPIO_NUM_46

#define LCD_WIDTH   172
#define LCD_HEIGHT  320

static void fill_screen(esp_lcd_panel_handle_t panel, uint16_t color)
{
    uint16_t *row = (uint16_t *)heap_caps_malloc(LCD_WIDTH * sizeof(uint16_t), MALLOC_CAP_DMA);
    if (!row) {
        ESP_LOGE(TAG, "Failed to allocate row buffer!");
        return;
    }
    for (int x = 0; x < LCD_WIDTH; x++) {
        row[x] = color;
    }
    for (int y = 0; y < LCD_HEIGHT; y++) {
        esp_lcd_panel_draw_bitmap(panel, 0, y, LCD_WIDTH, y + 1, row);
    }
    free(row);
}

extern "C" void app_main(void)
{
    ESP_LOGI(TAG, "=== LCD Test Starting ===");

    // 1. Init NVS flash
    nvs_flash_init();

    // 2. Init SPI bus (SPI3) — use 12 MHz as verified in working ST7789.c
    ESP_LOGI(TAG, "Init SPI bus...");
    spi_bus_config_t buscfg = {};
    buscfg.mosi_io_num     = PIN_MOSI;
    buscfg.miso_io_num     = PIN_MISO;
    buscfg.sclk_io_num     = PIN_SCLK;
    buscfg.quadwp_io_num   = GPIO_NUM_NC;
    buscfg.quadhd_io_num   = GPIO_NUM_NC;
    buscfg.max_transfer_sz = LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t);
    ESP_ERROR_CHECK(spi_bus_initialize(SPI3_HOST, &buscfg, SPI_DMA_CH_AUTO));

    // 3. Init LCD panel IO
    ESP_LOGI(TAG, "Init panel IO...");
    esp_lcd_panel_io_handle_t io_handle = NULL;
    esp_lcd_panel_io_spi_config_t io_config = {};
    io_config.cs_gpio_num      = PIN_CS;
    io_config.dc_gpio_num      = PIN_DC;
    io_config.spi_mode         = 0;
    io_config.pclk_hz          = 12 * 1000 * 1000;  // 12 MHz (matches working ST7789.c)
    io_config.trans_queue_depth = 10;
    io_config.lcd_cmd_bits     = 8;
    io_config.lcd_param_bits   = 8;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI3_HOST, &io_config, &io_handle));

    // 4. Init ST7789T panel using the custom Vernon driver (matches working code)
    ESP_LOGI(TAG, "Init ST7789T driver...");
    esp_lcd_panel_handle_t panel = NULL;
    esp_lcd_panel_dev_config_t panel_config = {};
    panel_config.reset_gpio_num     = PIN_RST;
    panel_config.rgb_ele_order      = LCD_RGB_ELEMENT_ORDER_BGR;
    panel_config.bits_per_pixel     = 16;
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789(io_handle, &panel_config, &panel));

    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel, true, false));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));

    // 5. Init backlight (LEDC PWM, matches working ST7789.c)
    ESP_LOGI(TAG, "Init backlight on GPIO %d...", PIN_BK);

    ledc_timer_config_t ledc_timer = {};
    ledc_timer.speed_mode      = LEDC_LOW_SPEED_MODE;
    ledc_timer.timer_num       = LEDC_TIMER_0;
    ledc_timer.duty_resolution = LEDC_TIMER_13_BIT;
    ledc_timer.freq_hz         = 4000;
    ledc_timer.clk_cfg         = LEDC_AUTO_CLK;
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));

    ledc_channel_config_t ledc_channel = {};
    ledc_channel.speed_mode = LEDC_LOW_SPEED_MODE;
    ledc_channel.channel    = LEDC_CHANNEL_0;
    ledc_channel.timer_sel  = LEDC_TIMER_0;
    ledc_channel.gpio_num   = PIN_BK;
    ledc_channel.duty       = 8191;   // 100% (13-bit max)
    ledc_channel.hpoint     = 0;
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel));

    ESP_LOGI(TAG, "Backlight ON — screen should be lit!");

    // 6. Fill screen with colors
    while (1) {
        ESP_LOGI(TAG, "WHITE");
        fill_screen(panel, 0xFFFF);
        vTaskDelay(pdMS_TO_TICKS(2000));

        ESP_LOGI(TAG, "RED");
        fill_screen(panel, 0xF800);
        vTaskDelay(pdMS_TO_TICKS(2000));

        ESP_LOGI(TAG, "GREEN");
        fill_screen(panel, 0x07E0);
        vTaskDelay(pdMS_TO_TICKS(2000));

        ESP_LOGI(TAG, "BLUE");
        fill_screen(panel, 0x001F);
        vTaskDelay(pdMS_TO_TICKS(2000));

        ESP_LOGI(TAG, "BLACK");
        fill_screen(panel, 0x0000);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}
