#include "display/display.h"  // pulls in HAVE_LVGL (defined unless emote UI)
#include "action_cards.h"

#include <esp_log.h>

#define TAG "ActionCards"

ActionCards& ActionCards::GetInstance() {
    static ActionCards instance;
    return instance;
}

#ifdef HAVE_LVGL

#include "action_cards/action_cards_generated.h"
#include "board.h"
#include "application.h"
#include "sdkconfig.h"
#include "adhd_remote_cmd.h"

#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

void ActionCards::ConfirmCallbackThunk(void* user_data) {
    (void)user_data;
    ActionCards::GetInstance().ConfirmSelection();
}

void ActionCards::ConfirmSelection() {
    if (!active_) {
        return;
    }
    if (display_dimmed_ || index_ < 0) {
        MarkActivity();
        return;
    }
    Announce();
}

void ActionCards::Toggle() {
    auto* display = Board::GetInstance().GetDisplay();
    if (!active_) {
        active_ = true;
        display_dimmed_ = false;
        activity_seq_ = 0;
        index_ = -1;
        ESP_LOGI(TAG, "Entering action cards mode");
        RestoreBacklight();
        ShowWaitingPrompt();
        (void)xTaskCreate(IdleDimTask, "cards_idle_dim", 3072, this, 2, nullptr);
    } else {
        active_ = false;
        display_dimmed_ = false;
        if (display != nullptr) {
            display->SetActionCardConfirmCallback(nullptr, nullptr);
            display->HideFullscreenImage();
        }
        RestoreBacklight();
        ESP_LOGI(TAG, "Leaving action cards mode");
    }
}

void ActionCards::Next() {
    if (!active_) {
        return;
    }
    if (display_dimmed_) {
        ESP_LOGI(TAG, "Shake ignored while action cards are dimmed");
        return;
    }
    MarkActivity();
    index_ = (index_ + 1) % static_cast<int>(kActionCards.size());
    ShowCurrent();
}

void ActionCards::IdleDimTask(void* user_data) {
    auto* self = static_cast<ActionCards*>(user_data);
    if (self == nullptr) {
        vTaskDelete(nullptr);
        return;
    }
    int last_activity_seq = self->activity_seq_;
    int64_t last_activity_us = esp_timer_get_time();
    while (self->active_) {
        if (self->activity_seq_ != last_activity_seq) {
            last_activity_seq = self->activity_seq_;
            last_activity_us = esp_timer_get_time();
        }
        if (!self->display_dimmed_ &&
            esp_timer_get_time() - last_activity_us >= 30LL * 1000LL * 1000LL) {
            self->DimBacklight();
            self->display_dimmed_ = true;
            ESP_LOGI(TAG, "Action cards idle dimmed index=%d", self->index_);
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
    vTaskDelete(nullptr);
}

void ActionCards::MarkActivity() {
    ++activity_seq_;
    if (display_dimmed_) {
        display_dimmed_ = false;
        RestoreBacklight();
    }
}

void ActionCards::RestoreBacklight() {
    Backlight* bl = Board::GetInstance().GetBacklight();
    if (bl != nullptr) {
        bl->RestoreBrightness();
    }
}

void ActionCards::DimBacklight() {
    Backlight* bl = Board::GetInstance().GetBacklight();
    if (bl != nullptr) {
        bl->SetBrightness(0);
    }
}

void ActionCards::ShowWaitingPrompt() {
    auto* display = Board::GetInstance().GetDisplay();
    if (display == nullptr) {
        return;
    }
    display->HideFullscreenImage();
    display->SetCenterStatus(reinterpret_cast<const char*>(u8"\u7b49\u5f85\u4f60\u7684\u9009\u62e9"));
    display->SetEmotion("happy");
}

void ActionCards::ShowCurrent() {
    const auto& card = kActionCards[index_];
    auto* display = Board::GetInstance().GetDisplay();
    if (display != nullptr) {
        display->ShowFullscreenImage(card.image);
        display->SetActionCardConfirmCallback(&ActionCards::ConfirmCallbackThunk, nullptr);
    }
    ESP_LOGI(TAG, "Showing card %d/%d: %s (BOOT 键确认，摇晃换图)",
             index_ + 1, static_cast<int>(kActionCards.size()), card.name);
}

void ActionCards::Announce() {
    if (!active_ || index_ < 0) {
        return;
    }
    const auto& card = kActionCards[index_];
    // 先清空本地播放队列，避免仍播上一张卡片的尾音 / 旧包
    Application::GetInstance().GetAudioService().ResetDecoder();
#if ACTION_CARDS_HAVE_AUDIO
    Application::GetInstance().PlaySound(card.sound);
    ESP_LOGI(TAG, "Confirmed card: 妈妈，我要%s", card.name);
#else
    ESP_LOGW(TAG, "No embedded voice clip for '%s' - run "
             "scripts/gen_action_cards.py --audio to generate the ogg files",
             card.name);
#endif
#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
    static const char* const kActionCardSlugs[] = {
        "get_up",
        "go_toilet",
        "brush_teeth",
        "wash_face",
        "comb_hair",
        "wear_clothes",
        "wear_shoes",
        "wash_hands",
        "take_bath",
        "sleep",
    };
    const char* slug = "unknown";
    if (index_ >= 0 && index_ < static_cast<int>(sizeof(kActionCardSlugs) / sizeof(kActionCardSlugs[0]))) {
        slug = kActionCardSlugs[index_];
    }
    (void)adhd_post_autism_need_event(slug, card.name, card.name);
#endif
}

#else  // !HAVE_LVGL: feature needs an LVGL display, so these are no-ops.

void ActionCards::ConfirmCallbackThunk(void*) {}
void ActionCards::IdleDimTask(void*) {}
void ActionCards::Toggle() {}
void ActionCards::Next() {}
void ActionCards::MarkActivity() {}
void ActionCards::RestoreBacklight() {}
void ActionCards::DimBacklight() {}
void ActionCards::ShowWaitingPrompt() {}
void ActionCards::ShowCurrent() {}
void ActionCards::ConfirmSelection() {}
void ActionCards::Announce() {}

#endif  // HAVE_LVGL
