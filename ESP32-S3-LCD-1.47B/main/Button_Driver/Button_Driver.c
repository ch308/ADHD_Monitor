#include "Button_Driver.h"
#include "Wireless.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include <stdbool.h>

static const char *BTN_TAG = "Btn";

/** 长按 ≥ 5 秒触发 ESP32 重新配网（恢复 BLE 广播）。
 *  避免误触：必须连续 hold 满 5 s，松手或被 LVGL/仿真触摸打断都会取消。 */
#define RESET_PROV_HOLD_US   (5LL * 1000 * 1000)

static int64_t s_long_press_start_us = 0;
static bool    s_reset_prov_triggered = false;

void  ESP32_Button_init(void){
  gpio_reset_pin(Button_PIN1);
  gpio_set_direction(Button_PIN1, GPIO_MODE_INPUT);
  gpio_set_pull_mode(Button_PIN1, GPIO_PULLUP_ONLY);
}
uint8_t Button_GPIO_Get_Level(int GPIO_PIN){
  return (uint8_t)(gpio_get_level(GPIO_PIN));
}
void Timer_Callback(void *arg){
  button_ticks();
}



struct Button BUTTON1;
PressEvent BOOT_KEY_State,PWR_KEY_State;
uint8_t Read_Button_GPIO_Level(uint8_t button_id)
{
  if(!button_id)
    return (uint8_t)(gpio_get_level(Button_PIN1));
  return 0;
}
void Button_SINGLE_CLICK_Callback(void* btn){
  struct Button *user_button = (struct Button *)btn;
  if(user_button == &BUTTON1){
    BOOT_KEY_State = SINGLE_CLICK;
  }
}
void Button_DOUBLE_CLICK_Callback(void* btn){
  struct Button *user_button = (struct Button *)btn;
  if(user_button == &BUTTON1){
    BOOT_KEY_State = DOUBLE_CLICK;
  }
}
void Button_LONG_PRESS_START_Callback(void* btn){
  struct Button *user_button = (struct Button *)btn;
  if(user_button == &BUTTON1){
    BOOT_KEY_State = LONG_PRESS_START;
    s_long_press_start_us = esp_timer_get_time();
    s_reset_prov_triggered = false;
    ESP_LOGI(BTN_TAG, "boot key long-press start, hold 5s to reset provisioning");
  }
}

/** 进入长按状态后，multi_button 每个 tick (~5ms) 都会触发 HOLD。
 *  hold 满 5 s 视为"重新配网"请求。 */
void Button_LONG_PRESS_HOLD_Callback(void* btn){
  struct Button *user_button = (struct Button *)btn;
  if(user_button != &BUTTON1) {
    return;
  }
  if (s_reset_prov_triggered) {
    return;
  }
  if (s_long_press_start_us == 0) {
    return;
  }
  int64_t held_us = esp_timer_get_time() - s_long_press_start_us;
  if (held_us >= RESET_PROV_HOLD_US) {
    s_reset_prov_triggered = true;
    ESP_LOGW(BTN_TAG, "boot key held %lld ms → reset provisioning + reboot",
             (long long)(held_us / 1000));
    /* 该函数内部会清掉 NVS 凭据并 esp_restart()，不会返回 */
    Wireless_ResetProvisioning();
  }
}

void Button_PRESS_UP_Callback(void* btn){
  struct Button *user_button = (struct Button *)btn;
  if(user_button == &BUTTON1){
    /* 松手就清零，避免上一次的累计影响下一次判定 */
    s_long_press_start_us = 0;
    s_reset_prov_triggered = false;
  }
}

void button_Init(void)
{
  ESP32_Button_init();
  button_init(&BUTTON1, Read_Button_GPIO_Level, 0 , 0);
  button_attach(&BUTTON1, SINGLE_CLICK,     Button_SINGLE_CLICK_Callback);
  button_attach(&BUTTON1, DOUBLE_CLICK,     Button_DOUBLE_CLICK_Callback);
  button_attach(&BUTTON1, LONG_PRESS_START, Button_LONG_PRESS_START_Callback);
  button_attach(&BUTTON1, LONG_PRESS_HOLD,  Button_LONG_PRESS_HOLD_Callback);
  button_attach(&BUTTON1, PRESS_UP,         Button_PRESS_UP_Callback);

  const esp_timer_create_args_t clock_tick_timer_args =
  {
    .callback = &Timer_Callback,
    .name = "Timer_task",
    .arg = NULL,
  };
  esp_timer_handle_t clock_tick_timer = NULL;
  ESP_ERROR_CHECK(esp_timer_create(&clock_tick_timer_args, &clock_tick_timer));
  ESP_ERROR_CHECK(esp_timer_start_periodic(clock_tick_timer, 1000 * 5));

  BOOT_KEY_State = NONE_PRESS;
  button_start(&BUTTON1);
}
