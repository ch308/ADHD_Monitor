#ifndef _APPLICATION_H_
#define _APPLICATION_H_

#include <freertos/FreeRTOS.h>
#include <freertos/event_groups.h>
#include <freertos/task.h>
#include <esp_timer.h>
#include <sdkconfig.h>

#include <string>
#include <mutex>
#include <deque>
#include <memory>

#include "protocol.h"
#include "audio_service.h"
#include "device_state.h"
#include "device_state_machine.h"

// Main event bits
#define MAIN_EVENT_SCHEDULE             (1 << 0)
#define MAIN_EVENT_SEND_AUDIO           (1 << 1)
#define MAIN_EVENT_WAKE_WORD_DETECTED   (1 << 2)
#define MAIN_EVENT_VAD_CHANGE           (1 << 3)
#define MAIN_EVENT_ERROR                (1 << 4)
#define MAIN_EVENT_ACTIVATION_DONE      (1 << 5)
#define MAIN_EVENT_CLOCK_TICK           (1 << 6)
#define MAIN_EVENT_NETWORK_CONNECTED    (1 << 7)
#define MAIN_EVENT_NETWORK_DISCONNECTED (1 << 8)
#define MAIN_EVENT_TOGGLE_CHAT          (1 << 9)
#define MAIN_EVENT_START_LISTENING      (1 << 10)
#define MAIN_EVENT_STOP_LISTENING       (1 << 11)
#define MAIN_EVENT_STATE_CHANGED        (1 << 12)


enum AecMode {
    kAecOff,
    kAecOnDeviceSide,
    kAecOnServerSide,
};

class Application {
public:
    static Application& GetInstance() {
        static Application instance;
        return instance;
    }
    // Delete copy constructor and assignment operator
    Application(const Application&) = delete;
    Application& operator=(const Application&) = delete;

    /**
     * Initialize the application
     * This sets up display, audio, network callbacks, etc.
     * Network connection starts asynchronously.
     */
    void Initialize();

    /**
     * Run the main event loop
     * This function runs in the main task and never returns.
     * It handles all events including network, state changes, and user interactions.
     */
    void Run();

    DeviceState GetDeviceState() const { return state_machine_.GetState(); }
    bool IsVoiceDetected() const { return audio_service_.IsVoiceDetected(); }
    
    /**
     * Request state transition
     * Returns true if transition was successful
     */
    bool SetDeviceState(DeviceState state);

    /**
     * Schedule a callback to be executed in the main task
     */
    void Schedule(std::function<void()>&& callback);

    /**
     * Alert with status, message, emotion and optional sound
     */
    void Alert(const char* status, const char* message, const char* emotion = "", const std::string_view& sound = "");
    void DismissAlert();

    void AbortSpeaking(AbortReason reason);

    /**
     * Toggle chat state (event-based, thread-safe)
     * Sends MAIN_EVENT_TOGGLE_CHAT to be handled in Run()
     */
    void ToggleChatState();

    /**
     * Start listening (event-based, thread-safe)
     * Sends MAIN_EVENT_START_LISTENING to be handled in Run()
     */
    void StartListening();

    /**
     * Stop listening (event-based, thread-safe)
     * Sends MAIN_EVENT_STOP_LISTENING to be handled in Run()
     */
    void StopListening();

    void Reboot();
    void WakeWordInvoke(const std::string& wake_word);
    void SubmitChildTextInput(const std::string& text);
    bool CanEnterSleepMode();
    void SendMcpMessage(const std::string& payload);
    void SetAecMode(AecMode mode);
    AecMode GetAecMode() const { return aec_mode_; }
    void PlaySound(const std::string_view& sound);
    AudioService& GetAudioService() { return audio_service_; }
    
    /**
     * Reset protocol resources (thread-safe)
     * Can be called from any task to release resources allocated after network connected
     * This includes closing audio channel and resetting protocol objects
     */
    void ResetProtocol();

private:
    Application();
    ~Application();

    std::mutex mutex_;
    std::deque<std::function<void()>> main_tasks_;
    std::unique_ptr<Protocol> protocol_;
    EventGroupHandle_t event_group_ = nullptr;
    esp_timer_handle_t clock_timer_handle_ = nullptr;
    /** AutoStop endpoint detector: fires once `kAutoStopSilenceMs` after the
     * child stops talking, used instead of waiting for the 1 Hz clock tick. */
    esp_timer_handle_t endpoint_timer_handle_ = nullptr;
    /** After EnterSleepPowerSaveMode: turn off LCD/backlight while staying on WiFi. */
    esp_timer_handle_t sleep_display_off_timer_ = nullptr;
    DeviceStateMachine state_machine_;
    ListeningMode listening_mode_ = kListeningModeAutoStop;
    AecMode aec_mode_ = kAecOff;
    std::string last_error_message_;
    // Last network name reported via NetworkEvent::Connected (WiFi SSID or
    // cellular APN/carrier label). Used by HandleActivationDoneEvent to put
    // the AP name onto the OLED so the user can tell at a glance which
    // network the board joined and that the cloud handshake succeeded.
    std::string last_connected_network_;
    AudioService audio_service_;

    bool has_server_time_ = false;
    bool aborted_ = false;
    bool assets_version_checked_ = false;
    bool play_popup_on_listening_ = false;  // Flag to play popup sound after state changes to listening
    bool auto_stop_voice_seen_ = false;
    bool auto_stop_endpoint_timer_armed_ = false;
    bool session_termination_requested_ = false;
    bool sleep_power_save_mode_ = false;
    int64_t auto_stop_listen_started_ms_ = 0;
    int64_t auto_stop_voice_started_ms_ = 0;
    int64_t auto_stop_silence_started_ms_ = 0;
    int64_t auto_stop_voice_quiet_before_ms_ = 0;
    int64_t auto_stop_endpoint_delay_ms_ = 0;
    int64_t auto_stop_short_speech_total_ms_ = 0;
    int auto_stop_short_speech_count_ = 0;
    /** Source state for the transition that last fired MAIN_EVENT_STATE_CHANGED (see OnStateChanged). */
    DeviceState last_state_transition_from_{kDeviceStateUnknown};
    int clock_ticks_ = 0;
    TaskHandle_t activation_task_handle_ = nullptr;


    // Event handlers
    void HandleStateChangedEvent();
    void HandleToggleChatEvent();
    void HandleStartListeningEvent();
    void HandleStopListeningEvent();
    void HandleNetworkConnectedEvent();
    void HandleNetworkDisconnectedEvent();
    void HandleActivationDoneEvent();
    void HandleWakeWordDetectedEvent();
    void ContinueOpenAudioChannel(ListeningMode mode);
    void ContinueWakeWordInvoke(const std::string& wake_word);

    // Activation task (runs in background)
    void ActivationTask();

    // Helper methods
    void CheckAssetsVersion();
    void InitializeProtocol();
    void ShowActivationCode(const std::string& code, const std::string& message);
    bool SyncClockFromMonitorServer();
    void SetListeningMode(ListeningMode mode);
    ListeningMode GetDefaultListeningMode() const;
    bool IsSessionStopCommand(const std::string& text) const;
    void TerminateCurrentSession(const char* reason, bool notify_server);
    void EnterSleepPowerSaveMode(const char* reason, bool notify_server);
    void RestoreApplicationSleepDisplay();
    void OnSleepDisplayOffTimer();

#ifdef CONFIG_ADHD_KIDS_UI
    void RefreshKidsDisplay();
    static const char* SoftEmotionForKids(const char* emotion);
#endif
    
    // State change handler called by state machine
    void OnStateChanged(DeviceState old_state, DeviceState new_state);

    // Endpoint detection: invoked from Schedule() once kAutoStopSilenceMs has
    // elapsed since the child stopped talking. Re-checks state (the user may
    // have started talking again, or left listening) and, if conditions still
    // hold, sends listen-stop and transitions to Idle.
    void OnEndpointTimer();
};


class TaskPriorityReset {
public:
    TaskPriorityReset(BaseType_t priority) {
        original_priority_ = uxTaskPriorityGet(NULL);
        vTaskPrioritySet(NULL, priority);
    }
    ~TaskPriorityReset() {
        vTaskPrioritySet(NULL, original_priority_);
    }

private:
    BaseType_t original_priority_;
};

#endif // _APPLICATION_H_
