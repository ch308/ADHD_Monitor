#ifndef ACTION_CARDS_H
#define ACTION_CARDS_H

// Daily-routine "action cards": ten fullscreen 240x240 pictures embedded in the
// firmware as RGB565 C arrays. The user advances with shake or button; confirming
// the current card (double-tap on touch LCD if present, or MPU6050 double knock)
// plays an offline Ogg/Opus clip ("妈妈，我要" + the card's Chinese label) via
// AudioService::PlaySound().
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

    // Play the confirmation voice for the current card (e.g. MPU6050 double knock).
    void ConfirmSelection();

private:
    ActionCards() = default;
    ActionCards(const ActionCards&) = delete;
    ActionCards& operator=(const ActionCards&) = delete;

    static void ConfirmCallbackThunk(void* user_data);
    void ShowCurrent();
    void Announce();

    bool active_ = false;
    int index_ = 0;
};

#endif // ACTION_CARDS_H
