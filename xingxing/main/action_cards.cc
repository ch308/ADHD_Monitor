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

void ActionCards::ConfirmCallbackThunk(void* user_data) {
    (void)user_data;
    ActionCards::GetInstance().ConfirmSelection();
}

void ActionCards::ConfirmSelection() {
    if (!active_) {
        return;
    }
    Announce();
}

void ActionCards::Toggle() {
    auto* display = Board::GetInstance().GetDisplay();
    if (!active_) {
        active_ = true;
        index_ = 0;
        ESP_LOGI(TAG, "Entering action cards mode");
        ShowCurrent();
    } else {
        active_ = false;
        if (display != nullptr) {
            display->SetActionCardConfirmCallback(nullptr, nullptr);
            display->HideFullscreenImage();
        }
        ESP_LOGI(TAG, "Leaving action cards mode");
    }
}

void ActionCards::Next() {
    if (!active_) {
        return;
    }
    index_ = (index_ + 1) % static_cast<int>(kActionCards.size());
    ShowCurrent();
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
    if (!active_) {
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
void ActionCards::Toggle() {}
void ActionCards::Next() {}
void ActionCards::ShowCurrent() {}
void ActionCards::ConfirmSelection() {}
void ActionCards::Announce() {}

#endif  // HAVE_LVGL
