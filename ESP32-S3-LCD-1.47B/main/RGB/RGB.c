#include "RGB.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_err.h"
#include "esp_log.h"
#include "led_strip.h"

static const char *TAG = "RGB";

#define RGB_STRIP_RESOLUTION_HZ 10000000

/* 宁静蓝（10–7 s） */
#define RGB_CALM_BLUE_R   28
#define RGB_CALM_BLUE_G   72
#define RGB_CALM_BLUE_B   140

/* 琥珀橙（6–4 s） */
#define RGB_AMBER_R       255
#define RGB_AMBER_G       118
#define RGB_AMBER_B       28

/* 淡珊瑚粉（3–1 s） */
#define RGB_CORAL_R       255
#define RGB_CORAL_G       138
#define RGB_CORAL_B       118

/* 薄荷绿（0 s 闪一次） */
#define RGB_MINT_R        72
#define RGB_MINT_G        255
#define RGB_MINT_B        178

/* 呼吸：在宁静蓝基调上亮度起伏 */
#define RGB_BREATH_PERIOD_MS     2800
#define RGB_BREATH_STEP_MS       40
#define RGB_BREATH_MIN_SCALE     70
#define RGB_BREATH_MAX_SCALE     255

static led_strip_handle_t led_strip;
static SemaphoreHandle_t s_rgb_mutex;
static bool rgb_strip_initialized = false;
static bool rgb_countdown_task_started = false;
static bool rgb_breathing_task_started = false;

/** 倒计时任务占用灯效时为 true，呼吸任务仅在此为假时更新 */
static volatile bool s_countdown_led_active = false;

static uint8_t rgb_scale_u8(uint8_t v, uint32_t scale_0_255)
{
    return (uint8_t)(((uint32_t)v * scale_0_255) / 255U);
}

static void rgb_apply_countdown_phase(uint32_t elapsed_ms)
{
    uint8_t r, g, b;
    if(elapsed_ms < RGB_PHASE_BLUE_END_MS) {
        r = RGB_CALM_BLUE_R;
        g = RGB_CALM_BLUE_G;
        b = RGB_CALM_BLUE_B;
    }
    else if(elapsed_ms < RGB_PHASE_AMBER_END_MS) {
        r = RGB_AMBER_R;
        g = RGB_AMBER_G;
        b = RGB_AMBER_B;
    }
    else {
        r = RGB_CORAL_R;
        g = RGB_CORAL_G;
        b = RGB_CORAL_B;
    }
    Set_RGB(r, g, b);
}

static void rgb_mint_flash_once(void)
{
    Set_RGB(RGB_MINT_R, RGB_MINT_G, RGB_MINT_B);
    vTaskDelay(pdMS_TO_TICKS(RGB_MINT_FLASH_MS));
    Set_RGB(0, 0, 0);
}

static void rgb_countdown_task(void *arg)
{
    (void)arg;
    while(1) {
        s_countdown_led_active = true;
        Set_RGB(0, 0, 0);

        for(uint32_t elapsed_ms = 0; elapsed_ms < RGB_COUNTDOWN_TOTAL_MS; elapsed_ms += RGB_COUNTDOWN_STEP_MS) {
            rgb_apply_countdown_phase(elapsed_ms);
            vTaskDelay(pdMS_TO_TICKS(RGB_COUNTDOWN_STEP_MS));
        }

        rgb_mint_flash_once();
        s_countdown_led_active = false;

        vTaskDelay(pdMS_TO_TICKS(RGB_COUNTDOWN_RESTART_MS));
    }
}

static void rgb_breathing_task(void *arg)
{
    (void)arg;
    uint32_t t = 0;

    while(1) {
        if(s_countdown_led_active) {
            vTaskDelay(pdMS_TO_TICKS(80));
            continue;
        }

        uint32_t period = RGB_BREATH_PERIOD_MS;
        uint32_t tri = t % (period * 2U);
        if(tri >= period) {
            tri = (period * 2U) - 1U - tri;
        }
        uint32_t scale = RGB_BREATH_MIN_SCALE +
            ((uint32_t)(RGB_BREATH_MAX_SCALE - RGB_BREATH_MIN_SCALE) * tri) / period;

        Set_RGB(
            rgb_scale_u8(RGB_CALM_BLUE_R, scale),
            rgb_scale_u8(RGB_CALM_BLUE_G, scale),
            rgb_scale_u8(RGB_CALM_BLUE_B, scale));

        t += RGB_BREATH_STEP_MS;
        vTaskDelay(pdMS_TO_TICKS(RGB_BREATH_STEP_MS));
    }
}

void RGB_Init(void)
{
    if(rgb_strip_initialized) {
        return;
    }

    s_rgb_mutex = xSemaphoreCreateMutex();
    if(s_rgb_mutex == NULL) {
        ESP_LOGE(TAG, "RGB mutex create failed");
        return;
    }

    led_strip_config_t strip_config = {
        .strip_gpio_num = BLINK_GPIO,
        .max_leds = 1,
        .led_pixel_format = LED_PIXEL_FORMAT_GRB,
        .led_model = LED_MODEL_WS2812,
    };
    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = RGB_STRIP_RESOLUTION_HZ,
        .flags.with_dma = false,
    };
    ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip));
    ESP_ERROR_CHECK(led_strip_clear(led_strip));

    rgb_strip_initialized = true;
    ESP_LOGI(TAG, "WS2812 on GPIO%d (countdown + breathing tasks use Set_RGB mutex)", BLINK_GPIO);
}

void Set_RGB(uint8_t red_val, uint8_t green_val, uint8_t blue_val)
{
    if(!rgb_strip_initialized || s_rgb_mutex == NULL) {
        return;
    }

    /* 整灯 G 通道偏亮：统一衰减，避免只改表色仍发灰绿 */
    uint32_t g = ((uint32_t)green_val * (uint32_t)RGB_GREEN_GAIN_PERCENT) / 100U;
    if(g > 255U) {
        g = 255U;
    }

    if(xSemaphoreTake(s_rgb_mutex, portMAX_DELAY) != pdTRUE) {
        return;
    }

    ESP_ERROR_CHECK(led_strip_set_pixel(led_strip, 0, red_val, (uint8_t)g, blue_val));
    ESP_ERROR_CHECK(led_strip_refresh(led_strip));

    xSemaphoreGive(s_rgb_mutex);
}

void RGB_Start_Countdown_Task(void)
{
    if(!rgb_strip_initialized) {
        RGB_Init();
    }
    if(!rgb_strip_initialized || rgb_countdown_task_started) {
        return;
    }

    BaseType_t created = xTaskCreatePinnedToCore(
        rgb_countdown_task,
        "rgb_countdown",
        3072,
        NULL,
        4,
        NULL,
        0);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_FAIL);
    rgb_countdown_task_started = true;
    ESP_LOGI(TAG, "Countdown task started (10 s phases + mint flash)");
}

void RGB_Start_Breathing_Task(void)
{
    if(!rgb_strip_initialized) {
        RGB_Init();
    }
    if(!rgb_strip_initialized || rgb_breathing_task_started) {
        return;
    }

    BaseType_t created = xTaskCreatePinnedToCore(
        rgb_breathing_task,
        "rgb_breath",
        2048,
        NULL,
        2,
        NULL,
        0);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_FAIL);
    rgb_breathing_task_started = true;
    ESP_LOGI(TAG, "Breathing task started (pauses while countdown holds LED)");
}

void RGB_Example(void)
{
    RGB_Start_Countdown_Task();
}
