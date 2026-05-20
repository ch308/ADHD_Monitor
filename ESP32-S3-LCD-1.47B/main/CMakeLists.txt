idf_component_register(
                         SRCS "main.c"
                              "LCD_Driver/Vernon_ST7789T/Vernon_ST7789T.c"
                              "LCD_Driver/ST7789.c"
                              "LVGL_Driver/LVGL_Driver.c"
                              "LVGL_UI/LVGL_Example.c"
                              "SD_Card/SD_MMC.c"
                              "RGB/RGB.c"
                              "Wireless/Wireless.c"
                              "Cloud/Cloud.c"
                              "Button_Driver/multi_button.c"
                              "Button_Driver/Button_Driver.c"
                              "Simulated_Gesture/Simulated_Gesture.c"
                              "BAT_Driver/BAT_Driver.c"
                              "I2C_Driver/I2C_Driver.c"
                              "QMI8658/QMI8658.c"

                         INCLUDE_DIRS
                              "./LCD_Driver/Vernon_ST7789T"
                              "./LCD_Driver"
                              "./LVGL_Driver"
                              "./LVGL_UI"
                              "./SD_Card"
                              "./RGB"
                              "./Wireless"
                              "./Cloud"
                              "./I2C_Driver"
                              "./QMI8658"
                              "./BAT_Driver"
                              "./Button_Driver"
                              "./Simulated_Gesture"
                              "."
                         REQUIRES esp_http_client esp_netif esp_wifi esp_event nvs_flash
                                  bt protocomm cjson esp_timer esp_lcd esp_driver_ledc
                                 fatfs spi_flash esp_adc sdmmc driver
                       )
