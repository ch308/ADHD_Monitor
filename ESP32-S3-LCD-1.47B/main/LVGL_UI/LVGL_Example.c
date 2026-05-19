#include "LVGL_Example.h"

/**********************
 *      TYPEDEFS
 **********************/
typedef enum {
    DISP_SMALL,
    DISP_MEDIUM,
    DISP_LARGE,
} disp_size_t;

/**********************
 *  STATIC PROTOTYPES
 **********************/
static void Onboard_create(lv_obj_t * parent);

static void ta_event_cb(lv_event_t * e);
void example1_increase_lvgl_tick(lv_timer_t * t);
/**********************
 *  STATIC VARIABLES
 **********************/
static disp_size_t disp_size;

lv_obj_t * tv;
lv_style_t style_text_muted;
lv_style_t style_title;
static lv_style_t style_icon;
static lv_style_t style_bullet;



static const lv_font_t * font_large;
static const lv_font_t * font_normal;

static lv_timer_t * auto_step_timer;
static lv_obj_t * amber_overlay;
static uint8_t backlight_slider_last_value;

static lv_timer_t * meter2_timer;

lv_obj_t * SD_Size;
lv_obj_t * FlashSize;
lv_obj_t * BAT_Volts;
lv_obj_t * Board_deflection;
lv_obj_t * Wireless_Scan;
lv_obj_t * Backlight_add;
lv_obj_t * Backlight_subtract;
lv_obj_t * Backlight_slider;


lv_obj_t *Page_panel[50];
lv_obj_t *Simulated_panel1[100];
size_t Simulated_panel1_Size;

#define AMBER_OVERLAY_FADE_TIME_MS  3000
#define AMBER_OVERLAY_G_MIN         0
#define AMBER_OVERLAY_G_MAX         200
/* G 通道量化步长：越大 CPU 越省、阶梯越明显
 * 16 → 0..200 共 13 级，invalidate 更少；阶梯会比 8 更明显 */
#define AMBER_OVERLAY_G_STEP        16
/* 仅在本场景生效的 LVGL 刷新周期；越大 CPU 越省、响应越钝 */
#define AMBER_OVERLAY_REFR_PERIOD_MS  50
#define AMBER_OVERLAY_DEFAULT_REFR_MS 30

static int32_t amber_overlay_last_g = -1;

/* lv_anim 回调：把 0..200 的中间值塞回 R=255 / B=0 的琥珀色 G 通道。
 * 这里做两层省 CPU 处理：
 *  1) 按 AMBER_OVERLAY_G_STEP 量化，避免每个 anim tick 都改样式；
 *  2) 量化后的值若与上次相同则直接 return，连 invalidate 都不触发。 */
static void amber_overlay_color_anim_cb(void * var, int32_t value)
{
  if(var == NULL) {
    return;
  }
  int32_t q = (value / AMBER_OVERLAY_G_STEP) * AMBER_OVERLAY_G_STEP;
  if(q == amber_overlay_last_g) {
    return;
  }
  amber_overlay_last_g = q;
  lv_color_t c = lv_color_make(255, (uint8_t)q, 0);
  lv_obj_set_style_bg_color((lv_obj_t *)var, c, 0);
}

static void amber_overlay_create(void)
{
  amber_overlay = lv_obj_create(lv_scr_act());
  lv_obj_remove_style_all(amber_overlay);
  lv_obj_set_size(amber_overlay, LV_PCT(100), LV_PCT(100));
  lv_obj_set_pos(amber_overlay, 0, 0);
  lv_obj_set_style_radius(amber_overlay, 0, 0);
  lv_obj_set_style_bg_opa(amber_overlay, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(amber_overlay, lv_color_make(255, AMBER_OVERLAY_G_MIN, 0), 0);
  lv_obj_set_style_border_width(amber_overlay, 0, 0);
  lv_obj_add_flag(amber_overlay, LV_OBJ_FLAG_IGNORE_LAYOUT);
  lv_obj_clear_flag(amber_overlay, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
  lv_obj_move_foreground(amber_overlay);

  amber_overlay_last_g = -1;

  /* 把显示刷新 timer 周期拉到 50 ms（20 fps），给 WiFi/BLE 让出 CPU。
   * 这个 LVGL 版本还没有 lv_disp_set_refr_period() 的便捷封装，
   * 直接对 display 的 refresh timer 改 period 即可达到同样效果。 */
  lv_timer_t * refr_timer = _lv_disp_get_refr_timer(disp);
  if(refr_timer != NULL) {
    lv_timer_set_period(refr_timer, AMBER_OVERLAY_REFR_PERIOD_MS);
  }

  /* 用 LVGL 动画引擎做呼吸：G 通道在 0..200 之间往返
   * time + playback_time = 3000 + 3000，无限重复，路径用 ease_in_out 拿到呼吸感
   * 由于是 LV_OPA_COVER 的全屏层，每次回调都会触发整屏 flush——这是
   * 「整块 LCD 一起按这个颜色方案变化」必然付出的代价 */
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, amber_overlay);
  lv_anim_set_values(&a, AMBER_OVERLAY_G_MIN, AMBER_OVERLAY_G_MAX);
  lv_anim_set_time(&a, AMBER_OVERLAY_FADE_TIME_MS);
  lv_anim_set_playback_time(&a, AMBER_OVERLAY_FADE_TIME_MS);
  lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
  lv_anim_set_exec_cb(&a, amber_overlay_color_anim_cb);
  lv_anim_start(&a);
}

void Lvgl_Example1(void){

  disp_size = DISP_SMALL;                            

  font_large = LV_FONT_DEFAULT;                             
  font_normal = LV_FONT_DEFAULT;                         
  
  lv_coord_t tab_h;
  tab_h = 45;
  #if LV_FONT_MONTSERRAT_18
    font_large     = &lv_font_montserrat_18;
  #else
    LV_LOG_WARN("LV_FONT_MONTSERRAT_18 is not enabled for the widgets demo. Using LV_FONT_DEFAULT instead.");
  #endif
  #if LV_FONT_MONTSERRAT_12
    font_normal    = &lv_font_montserrat_12;
  #else
    LV_LOG_WARN("LV_FONT_MONTSERRAT_12 is not enabled for the widgets demo. Using LV_FONT_DEFAULT instead.");
  #endif
  
  lv_style_init(&style_text_muted);
  lv_style_set_text_opa(&style_text_muted, LV_OPA_90);

  lv_style_init(&style_title);
  lv_style_set_text_font(&style_title, font_large);

  lv_style_init(&style_icon);
  lv_style_set_text_color(&style_icon, lv_theme_get_color_primary(NULL));
  lv_style_set_text_font(&style_icon, font_large);

  lv_style_init(&style_bullet);
  lv_style_set_border_width(&style_bullet, 0);
  lv_style_set_radius(&style_bullet, LV_RADIUS_CIRCLE);

  tv = lv_tabview_create(lv_scr_act(), LV_DIR_TOP, tab_h);

  lv_obj_set_style_text_font(lv_scr_act(), font_normal, 0);


  Page_panel[0]  = lv_tabview_add_tab(tv, "Onboard");
  
  
  Onboard_create(Page_panel[0] );
  amber_overlay_create();
  
  lv_obj_t *temp_objects[] = {SD_Size, FlashSize, BAT_Volts, Board_deflection, Wireless_Scan, Backlight_subtract, Backlight_add};
  memcpy(Simulated_panel1, temp_objects, sizeof(temp_objects));
  Simulated_panel1_Size = sizeof(temp_objects)/sizeof(lv_obj_t*);
  backlight_slider_last_value = LCD_Backlight;
}

void Lvgl_Example1_close(void)
{
  /*Delete all animation*/
  lv_anim_del(NULL, NULL);

  lv_timer_del(meter2_timer);
  meter2_timer = NULL;

  lv_obj_clean(lv_scr_act());
  amber_overlay = NULL;
  amber_overlay_last_g = -1;
  backlight_slider_last_value = 0;

  /* 还原默认刷新周期，避免后续场景被波及 */
  lv_timer_t * refr_timer = _lv_disp_get_refr_timer(disp);
  if(refr_timer != NULL) {
    lv_timer_set_period(refr_timer, AMBER_OVERLAY_DEFAULT_REFR_MS);
  }

  lv_style_reset(&style_text_muted);
  lv_style_reset(&style_title);
  lv_style_reset(&style_icon);
  lv_style_reset(&style_bullet);
}


/**********************
*   STATIC FUNCTIONS
**********************/

static void Onboard_create(lv_obj_t * parent)
{

  /*Create a panel*/
  lv_obj_t * panel1 = lv_obj_create(parent);
  lv_obj_set_height(panel1, LV_SIZE_CONTENT);

  lv_obj_t * panel1_title = lv_label_create(panel1);
  lv_label_set_text(panel1_title, "Onboard parameter");
  lv_obj_add_style(panel1_title, &style_title, 0);

  lv_obj_t * SD_label = lv_label_create(panel1);
  lv_label_set_text(SD_label, "SD Card");
  lv_obj_add_style(SD_label, &style_text_muted, 0);

  SD_Size = lv_textarea_create(panel1);
  lv_textarea_set_one_line(SD_Size, true);
  lv_textarea_set_placeholder_text(SD_Size, "SD Size");
  lv_obj_add_event_cb(SD_Size, ta_event_cb, LV_EVENT_ALL, NULL);

  lv_obj_t * Flash_label = lv_label_create(panel1);
  lv_label_set_text(Flash_label, "Flash Size");
  lv_obj_add_style(Flash_label, &style_text_muted, 0);

  FlashSize = lv_textarea_create(panel1);
  lv_textarea_set_one_line(FlashSize, true);
  lv_textarea_set_placeholder_text(FlashSize, "Flash Size");
  lv_obj_add_event_cb(FlashSize, ta_event_cb, LV_EVENT_ALL, NULL);

  lv_obj_t * BAT_label = lv_label_create(panel1);
  lv_label_set_text(BAT_label, "Battery Voltage");
  lv_obj_add_style(BAT_label, &style_text_muted, 0);

  BAT_Volts = lv_textarea_create(panel1);
  lv_textarea_set_one_line(BAT_Volts, true);
  lv_textarea_set_placeholder_text(BAT_Volts, "BAT Volts");
  lv_obj_add_event_cb(BAT_Volts, ta_event_cb, LV_EVENT_ALL, NULL);

  lv_obj_t * deflection_label1 = lv_label_create(panel1);
  lv_label_set_text(deflection_label1, "Angular deflection");
  lv_obj_add_style(deflection_label1, &style_text_muted, 0);
  lv_obj_t * deflection_label2 = lv_label_create(panel1);
  lv_label_set_text(deflection_label2, "       x          y          z");
  lv_obj_add_style(deflection_label2, &style_text_muted, 0);

  Board_deflection = lv_textarea_create(panel1);
  lv_textarea_set_one_line(Board_deflection, true);
  lv_textarea_set_placeholder_text(Board_deflection, "Board deflection");
  lv_obj_add_event_cb(Board_deflection, ta_event_cb, LV_EVENT_ALL, NULL);

  lv_obj_t * Wireless_label = lv_label_create(panel1);
  lv_label_set_text(Wireless_label, "Wireless scan");
  lv_obj_add_style(Wireless_label, &style_text_muted, 0);

  Wireless_Scan = lv_textarea_create(panel1);
  lv_textarea_set_one_line(Wireless_Scan, true);
  lv_textarea_set_placeholder_text(Wireless_Scan, "Wireless number");
  lv_obj_add_event_cb(Wireless_Scan, ta_event_cb, LV_EVENT_ALL, NULL);


  lv_obj_t * Backlight_label = lv_label_create(panel1);
  lv_label_set_text(Backlight_label, "Backlight brightness");
  lv_obj_add_style(Backlight_label, &style_text_muted, 0);

 
  Backlight_subtract = lv_label_create(panel1);                   
  lv_label_set_text(Backlight_subtract, LV_SYMBOL_MINUS); 
  lv_obj_set_style_text_font(Backlight_subtract, &lv_font_montserrat_14, 0); 
  lv_obj_align(Backlight_subtract, LV_ALIGN_CENTER, 0, 0); 
  lv_obj_add_event_cb(Backlight_subtract, Backlight_adjustment_event_cb, LV_EVENT_CLICKED, NULL);
  lv_obj_add_flag(Backlight_subtract, LV_OBJ_FLAG_CLICKABLE); 


  Backlight_slider = lv_slider_create(panel1);                                 
  lv_obj_add_flag(Backlight_slider, LV_OBJ_FLAG_CLICKABLE);    
  lv_obj_set_size(Backlight_slider, 100, 20);              
  lv_obj_set_style_radius(Backlight_slider, 3, LV_PART_KNOB);               // Adjust the value for more or less rounding                                            
  lv_obj_set_style_bg_opa(Backlight_slider, LV_OPA_TRANSP, LV_PART_KNOB);                               
  // lv_obj_set_style_pad_all(Backlight_slider, 0, LV_PART_KNOB);                                            
  lv_obj_set_style_bg_color(Backlight_slider, lv_color_hex(0xAAAAAA), LV_PART_KNOB);               
  lv_obj_set_style_bg_color(Backlight_slider, lv_color_hex(0xFFFFFF), LV_PART_INDICATOR);             
  lv_obj_set_style_outline_width(Backlight_slider, 2, LV_PART_INDICATOR);  
  lv_obj_set_style_outline_color(Backlight_slider, lv_color_hex(0xD3D3D3), LV_PART_INDICATOR);      
  lv_slider_set_range(Backlight_slider, 0, Backlight_MAX);              
  lv_slider_set_value(Backlight_slider, LCD_Backlight, LV_ANIM_OFF);  


  Backlight_add = lv_label_create(panel1);                   
  lv_label_set_text(Backlight_add, LV_SYMBOL_PLUS); 
  lv_obj_set_style_text_font(Backlight_add, &lv_font_montserrat_14, 0); 
  lv_obj_align(Backlight_add, LV_ALIGN_CENTER, 0, 0); 
  lv_obj_add_event_cb(Backlight_add, Backlight_adjustment_event_cb, LV_EVENT_CLICKED, NULL);
  lv_obj_add_flag(Backlight_add, LV_OBJ_FLAG_CLICKABLE); 


  // 器件布局
  static lv_coord_t grid_main_col_dsc[] = {LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
  static lv_coord_t grid_main_row_dsc[] = {LV_GRID_CONTENT, LV_GRID_CONTENT, LV_GRID_CONTENT, LV_GRID_TEMPLATE_LAST};
  lv_obj_set_grid_dsc_array(parent, grid_main_col_dsc, grid_main_row_dsc);

  static lv_coord_t grid_1_col_dsc[] = {LV_GRID_FR(5), LV_GRID_FR(5), LV_GRID_FR(50), LV_GRID_FR(5), LV_GRID_FR(5), LV_GRID_TEMPLATE_LAST};
  static lv_coord_t grid_1_row_dsc[] = {
    LV_GRID_CONTENT,  /*Title*/
    5,                /*Separator*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_CONTENT,  /*Box title*/
    40,               /*Box*/
    LV_GRID_TEMPLATE_LAST          
  };

  lv_obj_set_grid_cell(panel1, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_START, 0, 1);
  lv_obj_set_grid_dsc_array(panel1, grid_1_col_dsc, grid_1_row_dsc);
  lv_obj_set_grid_cell(panel1_title, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_CENTER, 0, 1);
  lv_obj_set_grid_cell(SD_label, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 2, 1);
  lv_obj_set_grid_cell(SD_Size, LV_GRID_ALIGN_STRETCH, 0, 5, LV_GRID_ALIGN_CENTER, 3, 1);
  lv_obj_set_grid_cell(Flash_label, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 4, 1);
  lv_obj_set_grid_cell(FlashSize, LV_GRID_ALIGN_STRETCH, 0, 5, LV_GRID_ALIGN_CENTER, 5, 1);
  lv_obj_set_grid_cell(BAT_label, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 6, 1);
  lv_obj_set_grid_cell(BAT_Volts, LV_GRID_ALIGN_STRETCH, 0, 5, LV_GRID_ALIGN_CENTER, 7, 1);
  lv_obj_set_grid_cell(deflection_label1, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 8, 1);
  lv_obj_set_grid_cell(deflection_label2, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 9, 1);
  lv_obj_set_grid_cell(Board_deflection, LV_GRID_ALIGN_STRETCH, 0, 5, LV_GRID_ALIGN_CENTER, 10, 1);
  lv_obj_set_grid_cell(Wireless_label, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 11, 1);
  lv_obj_set_grid_cell(Wireless_Scan, LV_GRID_ALIGN_STRETCH, 0, 5, LV_GRID_ALIGN_CENTER, 12, 1);
  lv_obj_set_grid_cell(Backlight_label, LV_GRID_ALIGN_START, 0, 5, LV_GRID_ALIGN_START, 13, 1);
  lv_obj_set_grid_cell(Backlight_subtract, LV_GRID_ALIGN_CENTER, 0, 1, LV_GRID_ALIGN_CENTER, 14, 1);
  lv_obj_set_grid_cell(Backlight_slider, LV_GRID_ALIGN_STRETCH, 2, 1, LV_GRID_ALIGN_CENTER, 14, 1);
  lv_obj_set_grid_cell(Backlight_add, LV_GRID_ALIGN_CENTER, 4, 1, LV_GRID_ALIGN_CENTER, 14, 1);
  // 器件布局 END
  
  auto_step_timer = lv_timer_create(example1_increase_lvgl_tick, 500, NULL);
}

void example1_increase_lvgl_tick(lv_timer_t * t)
{
  char buf[100]={0}; 
  
  snprintf(buf, sizeof(buf), "%ld MB\r\n", SDCard_Size);
  lv_textarea_set_placeholder_text(SD_Size, buf);
  snprintf(buf, sizeof(buf), "%ld MB\r\n", Flash_Size);
  lv_textarea_set_placeholder_text(FlashSize, buf);
  snprintf(buf, sizeof(buf), "%.2f V\r\n", BAT_analogVolts);
  lv_textarea_set_placeholder_text(BAT_Volts, buf);
  snprintf(buf, sizeof(buf), "%.2f   %.2f   %.2f\r\n", Accel.x, Accel.y, Accel.z);
  lv_textarea_set_placeholder_text(Board_deflection, buf);
  if(Scan_finish)
    snprintf(buf, sizeof(buf), "W: %d  B: %d    OK.\r\n",WIFI_NUM,BLE_NUM);
    // snprintf(buf, sizeof(buf), "WIFI: %d     ..OK.\r\n",WIFI_NUM);
  else
    snprintf(buf, sizeof(buf), "W: %d  B: %d\r\n",WIFI_NUM,BLE_NUM);
    // snprintf(buf, sizeof(buf), "WIFI: %d  \r\n",WIFI_NUM);
  lv_textarea_set_placeholder_text(Wireless_Scan, buf);
  if(backlight_slider_last_value != LCD_Backlight) {
    lv_slider_set_value(Backlight_slider, LCD_Backlight, LV_ANIM_OFF);
    backlight_slider_last_value = LCD_Backlight;
  }
  /* 琥珀圆呼吸效果由 LVGL 动画引擎驱动，无需在这里手动驱动 */
}

static void ta_event_cb(lv_event_t * e)
{
}



void Backlight_adjustment_event_cb(lv_event_t * e) {

  lv_obj_t * target = lv_event_get_target(e);
  uint8_t Backlight = lv_slider_get_value(Backlight_slider);  
  if(target == Backlight_add){
    if(Backlight < 99)
      Backlight = Backlight + 2;
    else{
      printf("Backlight out of range: %d\n", Backlight);
      Backlight = 100;
    }
    
  }
  else if(target == Backlight_subtract){
    if(Backlight > 1)
      Backlight = Backlight - 2;
    else{
      printf("Backlight out of range: %d\n", Backlight);
      Backlight = 0;
    }
  }
  if ((Backlight > 0 && Backlight <= Backlight_MAX) || Backlight == 0 ) {
    lv_slider_set_value(Backlight_slider, Backlight, LV_ANIM_OFF); 
    backlight_slider_last_value = Backlight;
    LCD_Backlight = Backlight;
    LVGL_Backlight_adjustment(Backlight);
  }

}

void LVGL_Backlight_adjustment(uint8_t Backlight) {
  Set_Backlight(Backlight);                                 
}






