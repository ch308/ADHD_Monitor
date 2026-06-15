#ifndef ACTION_CARDS_H
#define ACTION_CARDS_H

// Daily-routine "action cards": ten fullscreen 240x240 pictures embedded in the
// firmware as RGB565 C arrays. The user advances with shake or button; confirming
// the current card is a single tap on the touch LCD (or boot flow); plays an offline
// Ogg/Opus clip ("妈妈，我要" + the card's Chinese label) via AudioService::PlaySound().
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

    // Play the confirmation voice for the current card (e.g. single tap on image).
    void ConfirmSelection();

    /// After power-on welcome + BOOT flow: enter routine slideshow at first card (shake = Next).
    void EnterRoutineFromPowerWelcome();

private:
    ActionCards() = default;
    ActionCards(const ActionCards&) = delete;
    ActionCards& operator=(const ActionCards&) = delete;

    static void ConfirmCallbackThunk(void* user_data);
    static void IdleDimTask(void* user_data);
    void MarkActivity();
    void RestoreBacklight();
    void DimBacklight();
    void ShowWaitingPrompt();
    void ShowCurrent();
    void Announce();

    bool active_ = false;
    bool display_dimmed_ = false;
    int activity_seq_ = 0;
    int index_ = -1;
};

#endif // ACTION_CARDS_H
