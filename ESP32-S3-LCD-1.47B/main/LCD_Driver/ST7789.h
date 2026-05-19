#pragma once
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_panel_ops.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_err.h"
#include "esp_log.h"
#include "lvgl.h"
#include "driver/ledc.h"

#include "Vernon_ST7789T.h"
#include "LVGL_Driver.h"
// LCD SPI GPIO
// Using SPI2 
#define LCD_HOST  SPI3_HOST

#define EXAMPLE_LCD_PIXEL_CLOCK_HZ     (12 * 1000 * 1000)
#define EXAMPLE_LCD_BK_LIGHT_ON_LEVEL  1
#define EXAMPLE_LCD_BK_LIGHT_OFF_LEVEL !EXAMPLE_LCD_BK_LIGHT_ON_LEVEL
#define EXAMPLE_PIN_NUM_SCLK           40
#define EXAMPLE_PIN_NUM_MOSI           45
#define EXAMPLE_PIN_NUM_MISO           -1
#define EXAMPLE_PIN_NUM_LCD_DC         41
#define EXAMPLE_PIN_NUM_LCD_RST        39
#define EXAMPLE_PIN_NUM_LCD_CS         42
#define EXAMPLE_PIN_NUM_BK_LIGHT       46
#define EXAMPLE_PIN_NUM_TOUCH_CS       -1
// The pixel number in horizontal and vertical
#define EXAMPLE_LCD_H_RES              172
#define EXAMPLE_LCD_V_RES              320
// Bit number used to represent command and parameter
#define EXAMPLE_LCD_CMD_BITS           8
#define EXAMPLE_LCD_PARAM_BITS         8

#define Offset_X 34
#define Offset_Y 0


#define LEDC_TIMER              LEDC_TIMER_0
#define LEDC_MODE               LEDC_LOW_SPEED_MODE
#define LEDC_OUTPUT_IO          EXAMPLE_PIN_NUM_BK_LIGHT      // Define the output GPIO
#define LEDC_CHANNEL            LEDC_CHANNEL_0
#define LEDC_DUTY_RES           LEDC_TIMER_13_BIT // Set duty resolution to 13 bits
#define LEDC_DUTY               (2000)    // Set duty to 50%. (2 ** 13) * 50% = 4096
#define LEDC_FREQUENCY          (4000) // Frequency in Hertz. Set frequency at 4 kHz
#define BACKLIGHT_FADE_TIME_MS  2000
#define BACKLIGHT_BRIGHT_HOLD_MS 2000
#define BACKLIGHT_DARK_HOLD_MS   2000
#define BACKLIGHT_WAIT_MS        7000
#define Backlight_MAX   100


extern uint8_t LCD_Backlight; 
extern esp_lcd_panel_handle_t panel_handle;

void LCD_Init(void);                     // Call this function to initialize the screen (must be called in the main function) !!!!!
/********************* BackLight *********************/
void Backlight_Init(void);
void Backlight_Example(void);
void Set_Backlight(uint8_t Light);