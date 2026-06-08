#include "display/display.h"  // pulls in HAVE_LVGL (defined unless emote UI)
#include "action_cards.h"

#include <esp_log.h>

#define TAG "ActionCards"

// How long a picture stays before its name is announced.
#define ACTION_CARD_ANNOUNCE_DELAY_MS 1000

ActionCards& ActionCards::GetInstance() {
    static ActionCards instance;
    return instance;
}

#ifdef HAVE_LVGL

#include "action_cards/action_cards_generated.h"
#include "board.h"
#include "application.h"

void ActionCards::EnsureTimer() {
    if (announce_timer_ != nullptr) {
        return;
    }
    esp_timer_create_args_t args = {};
    args.callback = [](void* arg) { static_cast<ActionCards*>(arg)->Announce(); };
    args.arg = this;
    args.dispatch_method = ESP_TIMER_TASK;
    args.name = "action_announce";
    esp_timer_create(&args, &announce_timer_);
}

void ActionCards::Toggle() {
    if (!active_) {
        active_ = true;
        index_ = 0;
        ESP_LOGI(TAG, "Entering action cards mode");
        ShowCurrent();
    } else {
        active_ = false;
        if (announce_timer_ != nullptr) {
            esp_timer_stop(announce_timer_);
        }
        auto display = Board::GetInstance().GetDisplay();
        if (display != nullptr) {
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
    auto display = Board::GetInstance().GetDisplay();
    if (display != nullptr) {
        display->ShowFullscreenImage(card.image);
    }
    EnsureTimer();
    if (announce_timer_ != nullptr) {
        esp_timer_stop(announce_timer_);
        esp_timer_start_once(announce_timer_, ACTION_CARD_ANNOUNCE_DELAY_MS * 1000);
    }
    ESP_LOGI(TAG, "Showing card %d/%d: %s", index_ + 1,
             static_cast<int>(kActionCards.size()), card.name);
}

void ActionCards::Announce() {
    if (!active_) {
        return;
    }
    const auto& card = kActionCards[index_];
#if ACTION_CARDS_HAVE_AUDIO
    Application::GetInstance().PlaySound(card.sound);
#else
    ESP_LOGW(TAG, "No embedded voice clip for '%s' - run "
             "scripts/gen_action_cards.py --audio to generate the ogg files",
             card.name);
#endif
}

#else  // !HAVE_LVGL: feature needs an LVGL display, so these are no-ops.

void ActionCards::EnsureTimer() {}
void ActionCards::Toggle() {}
void ActionCards::Next() {}
void ActionCards::ShowCurrent() {}
void ActionCards::Announce() {}

#endif  // HAVE_LVGL
