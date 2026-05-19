#include "ST7789.h"
#include <stdbool.h>
#include "freertos/event_groups.h"

static const char *TAG_LCD = "WS_LCD";

#define BACKLIGHT_FULL_EV_BIT   BIT0
#define BACKLIGHT_EMPTY_EV_BIT  BIT1
#define BACKLIGHT_DUTY_MAX      ((1U << LEDC_DUTY_RES) - 1U)

esp_lcd_panel_handle_t panel_handle = NULL;

void LCD_Init(void)
{
    ESP_LOGI(TAG_LCD, "Initialize SPI bus");                                            
    spi_bus_config_t buscfg = {                                                         
        .sclk_io_num = EXAMPLE_PIN_NUM_SCLK,                                            
        .mosi_io_num = EXAMPLE_PIN_NUM_MOSI,                                            
        .miso_io_num = EXAMPLE_PIN_NUM_MISO,                                            
        .quadwp_io_num = -1,                                                            
        .quadhd_io_num = -1,                                                            
        .max_transfer_sz = EXAMPLE_LCD_H_RES * EXAMPLE_LCD_V_RES * sizeof(uint16_t),    
    };
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_HOST, &buscfg, SPI_DMA_CH_AUTO));            

    ESP_LOGI(TAG_LCD, "Install panel IO");                                              
    esp_lcd_panel_io_handle_t io_handle = NULL;                                         
    esp_lcd_panel_io_spi_config_t io_config = {                                             
        .dc_gpio_num = EXAMPLE_PIN_NUM_LCD_DC,
        .cs_gpio_num = EXAMPLE_PIN_NUM_LCD_CS,
        .pclk_hz = EXAMPLE_LCD_PIXEL_CLOCK_HZ,
        .lcd_cmd_bits = EXAMPLE_LCD_CMD_BITS,
        .lcd_param_bits = EXAMPLE_LCD_PARAM_BITS,
        .spi_mode = 0,
        .trans_queue_depth = 10,
        .on_color_trans_done = example_notify_lvgl_flush_ready,
        .user_ctx = &disp_drv,
    };
    // Attach the LCD to the SPI bus
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &io_handle));

    esp_lcd_panel_dev_st7789t_config_t panel_config = {
        .reset_gpio_num = EXAMPLE_PIN_NUM_LCD_RST,
        .rgb_endian = LCD_RGB_ELEMENT_ORDER_BGR,
        .bits_per_pixel = 16,
    };
    ESP_LOGI(TAG_LCD, "Install ST7789T panel driver");
    ESP_ERROR_CHECK(esp_lcd_new_panel_st7789t(io_handle, &panel_config, &panel_handle));


    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel_handle));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel_handle));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel_handle, true, false));

    // user can flush pre-defined pattern to the screen before we turn on the screen or backlight
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel_handle, true));

    ESP_LOGI(TAG_LCD, "Turn on LCD backlight");
    // gpio_set_level(EXAMPLE_PIN_NUM_BK_LIGHT, EXAMPLE_LCD_BK_LIGHT_ON_LEVEL);
    
    Backlight_Init();
}

/********************* BackLight *********************/

uint8_t LCD_Backlight = 90;
static EventGroupHandle_t backlight_event_group;
static TaskHandle_t backlight_task_handle;
static bool backlight_initialized;
static bool backlight_effect_enabled;
static bool backlight_fade_service_installed;

static uint32_t backlight_percent_to_duty(uint8_t light)
{
    if (light >= Backlight_MAX) {
        return BACKLIGHT_DUTY_MAX;
    }

    return ((uint32_t)light * BACKLIGHT_DUTY_MAX) / Backlight_MAX;
}

static void backlight_set_raw_duty(uint32_t duty)
{
    ESP_ERROR_CHECK(ledc_set_duty(LEDC_MODE, LEDC_CHANNEL, duty));
    ESP_ERROR_CHECK(ledc_update_duty(LEDC_MODE, LEDC_CHANNEL));
}

static void configure_backlight_gpio(void)
{
    gpio_config_t gpio_cfg = {
        .pin_bit_mask = 1ULL << LEDC_OUTPUT_IO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };

    ESP_ERROR_CHECK(gpio_config(&gpio_cfg));
}

static void configure_backlight_timer(void)
{
    ledc_timer_config_t ledc_timer = {
        .speed_mode       = LEDC_MODE,
        .timer_num        = LEDC_TIMER,
        .duty_resolution  = LEDC_DUTY_RES,
        .freq_hz          = LEDC_FREQUENCY,  // Set output frequency at 4 kHz
        .clk_cfg          = LEDC_AUTO_CLK
    };
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));
}

static void configure_backlight_channel(void)
{
    ledc_channel_config_t ledc_channel = {
        .speed_mode     = LEDC_MODE,
        .channel        = LEDC_CHANNEL,
        .timer_sel      = LEDC_TIMER,
        .intr_type      = LEDC_INTR_DISABLE,
        .gpio_num       = LEDC_OUTPUT_IO,
        .duty           = 0, // Set duty to 0%
        .hpoint         = 0
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel));
}

static void enable_backlight_fade(void)
{
    if (backlight_fade_service_installed) {
        return;
    }

    ESP_ERROR_CHECK(ledc_fade_func_install(0));
    backlight_fade_service_installed = true;
}

static void backlight_start_fade(uint32_t target_duty, uint32_t fade_time_ms)
{
    ESP_ERROR_CHECK(ledc_set_fade_with_time(LEDC_MODE, LEDC_CHANNEL, target_duty, fade_time_ms));
    ESP_ERROR_CHECK(ledc_fade_start(LEDC_MODE, LEDC_CHANNEL, LEDC_FADE_NO_WAIT));
}

static bool IRAM_ATTR backlight_fade_done_cb(const ledc_cb_param_t *param, void *user_arg)
{
    BaseType_t task_woken = pdFALSE;
    EventGroupHandle_t event_group = (EventGroupHandle_t)user_arg;

    if (param->duty > 0) {
        xEventGroupSetBitsFromISR(event_group, BACKLIGHT_FULL_EV_BIT, &task_woken);
    } else {
        xEventGroupSetBitsFromISR(event_group, BACKLIGHT_EMPTY_EV_BIT, &task_woken);
    }

    return task_woken == pdTRUE;
}

static void backlight_breath_task(void *arg)
{
    while (1) {
        if (!backlight_effect_enabled) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }

        EventBits_t recv_event = xEventGroupWaitBits(
            backlight_event_group,
            BACKLIGHT_FULL_EV_BIT | BACKLIGHT_EMPTY_EV_BIT,
            pdTRUE,
            pdFALSE,
            pdMS_TO_TICKS(BACKLIGHT_WAIT_MS));

        if ((recv_event & (BACKLIGHT_FULL_EV_BIT | BACKLIGHT_EMPTY_EV_BIT)) == 0) {
            ESP_LOGW(TAG_LCD, "Backlight fade wait timed out");
            continue;
        }

        if (!backlight_effect_enabled) {
            continue;
        }

        if (recv_event & BACKLIGHT_FULL_EV_BIT) {
            LCD_Backlight = Backlight_MAX;
            vTaskDelay(pdMS_TO_TICKS(BACKLIGHT_BRIGHT_HOLD_MS));
            if (backlight_effect_enabled) {
                backlight_start_fade(0, BACKLIGHT_FADE_TIME_MS);
            }
        }

        if (recv_event & BACKLIGHT_EMPTY_EV_BIT) {
            LCD_Backlight = 0;
            vTaskDelay(pdMS_TO_TICKS(BACKLIGHT_DARK_HOLD_MS));
            if (backlight_effect_enabled) {
                backlight_start_fade(BACKLIGHT_DUTY_MAX, BACKLIGHT_FADE_TIME_MS);
            }
        }
    }
}

void Backlight_Init(void)
{
    if (backlight_initialized) {
        return;
    }

    configure_backlight_gpio();
    configure_backlight_timer();
    configure_backlight_channel();
    enable_backlight_fade();

    backlight_event_group = xEventGroupCreate();
    ESP_ERROR_CHECK(backlight_event_group != NULL ? ESP_OK : ESP_FAIL);

    ledc_cbs_t ledc_cb = {
        .fade_cb = backlight_fade_done_cb,
    };
    ESP_ERROR_CHECK(ledc_cb_register(LEDC_MODE, LEDC_CHANNEL, &ledc_cb, backlight_event_group));

    backlight_set_raw_duty(backlight_percent_to_duty(LCD_Backlight));
    backlight_initialized = true;
}

void Backlight_Example(void)
{
    if (!backlight_initialized) {
        Backlight_Init();
    }

    backlight_effect_enabled = true;
    LCD_Backlight = 0;
    xEventGroupClearBits(backlight_event_group, BACKLIGHT_FULL_EV_BIT | BACKLIGHT_EMPTY_EV_BIT);
    backlight_set_raw_duty(0);

    if (backlight_task_handle == NULL) {
        BaseType_t created = xTaskCreatePinnedToCore(
            backlight_breath_task,
            "backlight_breath",
            2048,
            NULL,
            10,
            &backlight_task_handle,
            1);
        ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_FAIL);
    }

    backlight_start_fade(BACKLIGHT_DUTY_MAX, BACKLIGHT_FADE_TIME_MS);
    ESP_LOGI(TAG_LCD, "Backlight LEDC breathing started on GPIO%d", LEDC_OUTPUT_IO);
}

void Set_Backlight(uint8_t Light)
{
    if (Light > Backlight_MAX) {
        printf("Set Backlight parameters in the range of 0 to 100 \r\n");
        return;
    }

    backlight_effect_enabled = false;
    LCD_Backlight = Light;
    backlight_set_raw_duty(backlight_percent_to_duty(Light));
}