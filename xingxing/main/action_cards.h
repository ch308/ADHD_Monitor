#ifndef ACTION_CARDS_H
#define ACTION_CARDS_H

#include <esp_timer.h>

// Daily-routine "action cards": ten fullscreen 240x240 pictures embedded in the
// firmware as RGB565 C arrays. Each picture is shown, then one second later its
// Chinese name is announced with an offline Ogg/Opus clip via
// AudioService::PlaySound(). The user steps to the next picture with a button.
//
// Assets are produced by scripts/gen_action_cards.py (pictures + voice clips +
// the action_cards/action_cards_generated.h table). Until the voice clips are
// generated the slideshow still runs silently (ACTION_CARDS_HAVE_AUDIO == 0).
class ActionCards {
public:
    static ActionCards& GetInstance();

    // Enter the slideshow (shows the first card) or leave it (hides the picture).
    void Toggle();
    // Advance to the next card, wrapping after the last one. No-op when inactive.
    void Next();
    bool IsActive() const { return active_; }

private:
    ActionCards() = default;
    ActionCards(const ActionCards&) = delete;
    ActionCards& operator=(const ActionCards&) = delete;

    void EnsureTimer();
    void ShowCurrent();
    void Announce();

    bool active_ = false;
    int index_ = 0;
    esp_timer_handle_t announce_timer_ = nullptr;
};

#endif // ACTION_CARDS_H
