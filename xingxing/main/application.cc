#include "application.h"
#include "board.h"
#include "display.h"
#include "system_info.h"
#include "audio_codec.h"
#include "mqtt_protocol.h"
#include "websocket_protocol.h"
#include "assets/lang_config.h"
#include "mcp_server.h"
#include "assets.h"
#include "settings.h"
#include "adhd_remote_cmd.h"
#include "action_cards.h"

#include <cstring>
#include <cstdlib>
#include <ctime>
#include <sys/time.h>
#include <esp_log.h>
#include <esp_app_desc.h>
#include <cJSON.h>
#include <driver/gpio.h>
#include <arpa/inet.h>
#include <font_awesome.h>
#include <sdkconfig.h>

#if HAVE_LVGL
#include "action_cards/choice_hint_images_generated.h"
#include "lcd_display.h"
#include <atomic>
#include <functional>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include <esp_timer.h>
#endif

#define TAG "Application"

#if HAVE_LVGL
static std::atomic<bool> g_power_on_welcome_armed{true};
/// 0=正常；1=全屏欢迎等 BOOT；2=已按 BOOT，播「摇摇我」并再等 2s，仍禁止 MPU 换作息图。
static std::atomic<int> g_power_welcome_shake_gate{0};

static void RunUiSync(std::function<void()> fn) {
    SemaphoreHandle_t sem = xSemaphoreCreateBinary();
    if (sem == nullptr) {
        fn();
        return;
    }
    auto* heap_fn = new std::function<void()>(std::move(fn));
    Application::GetInstance().Schedule([heap_fn, sem]() {
        (*heap_fn)();
        delete heap_fn;
        xSemaphoreGive(sem);
    });
    (void)xSemaphoreTake(sem, pdMS_TO_TICKS(8000));
    vSemaphoreDelete(sem);
}

static void PowerOnWelcomePostBootTask(void*) {
    RunUiSync([]() {
        auto* d = Board::GetInstance().GetDisplay();
        if (d != nullptr) {
            d->HideFullscreenImage();
        }
    });
    Application::GetInstance().PlaySound(Lang::Sounds::OGG_HINT_TRY_SHAKE);
    vTaskDelay(pdMS_TO_TICKS(120));
    auto& audio = Application::GetInstance().GetAudioService();
    const int64_t deadline_us = esp_timer_get_time() + 15000LL * 1000LL;
    while (!audio.IsIdle() && esp_timer_get_time() < deadline_us) {
        vTaskDelay(pdMS_TO_TICKS(80));
    }
    vTaskDelay(pdMS_TO_TICKS(2000));
    Application::GetInstance().Schedule([]() {
        ActionCards::GetInstance().EnterRoutineFromPowerWelcome();
        g_power_welcome_shake_gate.store(3);
    });
    vTaskDelete(nullptr);
}

static void PowerOnWelcomeTask(void*) {
    auto* display = Board::GetInstance().GetDisplay();
    if (display != nullptr) {
        display->ShowFullscreenImage(&welcome_ni);
    }
    Application::GetInstance().PlaySound(Lang::Sounds::OGG_HINT_WELCOME);
    vTaskDelay(pdMS_TO_TICKS(120));
    auto& audio = Application::GetInstance().GetAudioService();
    const int64_t deadline_us = esp_timer_get_time() + 8000LL * 1000LL;
    while (!audio.IsIdle() && esp_timer_get_time() < deadline_us) {
        vTaskDelay(pdMS_TO_TICKS(80));
    }
    vTaskDelay(pdMS_TO_TICKS(300));
    vTaskDelete(nullptr);
}
#endif

void Application::EnterChildVoluntaryWelcomeFromPathA() {
#if HAVE_LVGL
    g_power_welcome_shake_gate.store(1);
    Schedule([this]() {
        if (ActionCards::GetInstance().IsActive()) {
            ActionCards::GetInstance().Toggle();
        }
        auto* display = Board::GetInstance().GetDisplay();
        if (display != nullptr) {
            if (auto* lcd = dynamic_cast<LcdDisplay*>(display)) {
                lcd->SetPreviewImage(nullptr);
            }
            display->HideFullscreenImage();
        }
        if (xTaskCreate(PowerOnWelcomeTask, "pwr_welcome", 4096, nullptr, 3, nullptr) != pdPASS) {
            g_power_welcome_shake_gate.store(0);
#ifdef CONFIG_ADHD_KIDS_UI
            RefreshKidsDisplay();
#endif
        }
    });
#endif
}

static constexpr const char* kXiaoxingxingWakeOpeningLine =
    "你好，我是星星守护者，有什么可以帮助你的吗？我可以陪你聊天，给你讲故事。";

// 进入 Listening 后头多少 ms 的 VAD 抖动忽略（避免上一段 TTS 残音/开 mic 时
// 的杂音被误识别为孩子说话）。设小一点，否则孩子立刻回答会被这段忽略期吞掉。
static constexpr int64_t kAutoStopIgnoreInitialVadMs = 300;
// 至少说够多少 ms 才算"说过话"。孩子回答常是很短的「嗯」「会呀」
// 一类片段，阈值不能过高，否则会一直卡在 Listening 等下一段 VAD。
static constexpr int64_t kAutoStopMinSpeechMs = 450;
static constexpr int64_t kAutoStopMinSpeechAfterLongQuietMs = 700;
static constexpr int64_t kAutoStopLongQuietMs = 15000;
// 前几秒里的极短 VAD 片段多半是残留播放声/环境噪声，不立刻提交，避免越聊
// ASR 越碎。
static constexpr int64_t kAutoStopEarlySpeechMs = 450;
static constexpr int64_t kAutoStopAllowShortSpeechAfterMs = 7000;
// Listening 总时长不到这么久不允许 endpoint。
static constexpr int64_t kAutoStopMinListenMs = 800;
// 孩子停顿多久算讲完一句 → 触发 listen stop / ASR / 回复。等待越久才出现的人声，
// 句尾静音也等越久，避免"没人说话但噪声触发一轮回复"。
static constexpr int64_t kAutoStopBaseSilenceMs = 1000;
static constexpr int64_t kAutoStopMaxSilenceMs = 2200;
static constexpr int64_t kAutoStopSilenceGrowthDivisor = 16;
// 兜底：如果 VAD 已经看到过说话但一直没稳定 endpoint，到这个时长强制提交。
static constexpr int64_t kAutoStopMaxUtteranceMs = 15000;
// 如果 VAD 多次只抓到短片段，也要提交给 ASR；否则孩子断续说话会被当作噪声，
// 直到 60s 空闲休眠，看起来像机器人卡死。
static constexpr int64_t kAutoStopForceShortFragmentsAfterMs = 8000;
static constexpr int64_t kAutoStopForceShortFragmentsSpeechMs = 700;
// 进入 Listening 后多久没听到任何说话 → 自动关闭会话，避免无限轮询。
static constexpr int64_t kAutoCloseIdleTimeoutMs = 60000;

// 进入「休眠省电」后多久关背光/面板。休眠期间 WiFi 保持 PERFORMANCE 档，避免关会话后
// OnAudioChannelClosed 把 STA 打成 LOW_POWER 导致掉线（计划表到点、HTTP 校时、长轮询依赖联网）。
static constexpr int64_t kAppSleepDisplayOffAfterUs = 30LL * 1000000LL;

static int64_t AutoStopEndpointDelayMs(int64_t quiet_before_voice_ms) {
    int64_t delay = kAutoStopBaseSilenceMs + quiet_before_voice_ms / kAutoStopSilenceGrowthDivisor;
    if (delay > kAutoStopMaxSilenceMs) {
        delay = kAutoStopMaxSilenceMs;
    }
    return delay;
}

static int64_t AutoStopRequiredSpeechMs(int64_t quiet_before_voice_ms) {
    return quiet_before_voice_ms >= kAutoStopLongQuietMs
        ? kAutoStopMinSpeechAfterLongQuietMs
        : kAutoStopMinSpeechMs;
}


Application::Application() {
    event_group_ = xEventGroupCreate();

#if CONFIG_USE_DEVICE_AEC && CONFIG_USE_SERVER_AEC
#error "CONFIG_USE_DEVICE_AEC and CONFIG_USE_SERVER_AEC cannot be enabled at the same time"
#elif CONFIG_USE_DEVICE_AEC
    aec_mode_ = kAecOnDeviceSide;
#elif CONFIG_USE_SERVER_AEC
    aec_mode_ = kAecOnServerSide;
#else
    aec_mode_ = kAecOff;
#endif

    esp_timer_create_args_t clock_timer_args = {
        .callback = [](void* arg) {
            Application* app = (Application*)arg;
            xEventGroupSetBits(app->event_group_, MAIN_EVENT_CLOCK_TICK);
        },
        .arg = this,
        .dispatch_method = ESP_TIMER_TASK,
        .name = "clock_timer",
        .skip_unhandled_events = true
    };
    esp_timer_create(&clock_timer_args, &clock_timer_handle_);

    // One-shot endpoint detector: fires after the adaptive silence window.
    esp_timer_create_args_t endpoint_timer_args = {
        .callback = [](void* arg) {
            Application* app = (Application*)arg;
            app->Schedule([app]() { app->OnEndpointTimer(); });
        },
        .arg = this,
        .dispatch_method = ESP_TIMER_TASK,
        .name = "endpoint_timer",
        .skip_unhandled_events = true
    };
    esp_timer_create(&endpoint_timer_args, &endpoint_timer_handle_);

    esp_timer_create_args_t sleep_disp_timer_args = {
        .callback = [](void* arg) {
            Application* app = (Application*)arg;
            app->Schedule([app]() { app->OnSleepDisplayOffTimer(); });
        },
        .arg = this,
        .dispatch_method = ESP_TIMER_TASK,
        .name = "sleep_disp_off",
        .skip_unhandled_events = true,
    };
    esp_timer_create(&sleep_disp_timer_args, &sleep_display_off_timer_);
}

Application::~Application() {
    if (clock_timer_handle_ != nullptr) {
        esp_timer_stop(clock_timer_handle_);
        esp_timer_delete(clock_timer_handle_);
    }
    if (endpoint_timer_handle_ != nullptr) {
        esp_timer_stop(endpoint_timer_handle_);
        esp_timer_delete(endpoint_timer_handle_);
    }
    if (sleep_display_off_timer_ != nullptr) {
        esp_timer_stop(sleep_display_off_timer_);
        esp_timer_delete(sleep_display_off_timer_);
    }
    vEventGroupDelete(event_group_);
}

bool Application::SetDeviceState(DeviceState state) {
    return state_machine_.TransitionTo(state);
}

void Application::Initialize() {
    auto& board = Board::GetInstance();
    SetDeviceState(kDeviceStateStarting);

    // Setup the display
    auto display = board.GetDisplay();
    display->SetupUI();
#ifdef CONFIG_ADHD_KIDS_UI
    display->SetWelcomeTitle(Lang::Strings::WELCOME_TITLE);
    RefreshKidsDisplay();
#endif
#ifdef CONFIG_ADHD_KIDS_UI
    // Kids UI uses the existing bottom scrolling bar for the welcome text.
    display->SetChatMessage("system", Lang::Strings::WELCOME_TITLE);
#else
    // Print board name/version info
    display->SetChatMessage("system", SystemInfo::GetUserAgent().c_str());
#endif

    // Setup the audio service
    auto codec = board.GetAudioCodec();
    audio_service_.Initialize(codec);
    audio_service_.Start();

    AudioServiceCallbacks callbacks;
    callbacks.on_send_queue_available = [this]() {
        xEventGroupSetBits(event_group_, MAIN_EVENT_SEND_AUDIO);
    };
    callbacks.on_wake_word_detected = [this](const std::string& wake_word) {
        xEventGroupSetBits(event_group_, MAIN_EVENT_WAKE_WORD_DETECTED);
    };
    callbacks.on_vad_change = [this](bool speaking) {
        xEventGroupSetBits(event_group_, MAIN_EVENT_VAD_CHANGE);
    };
    audio_service_.SetCallbacks(callbacks);

    // Add state change listeners
    state_machine_.AddStateChangeListener([this](DeviceState old_state, DeviceState new_state) {
        OnStateChanged(old_state, new_state);
    });

    // Start the clock timer to update the status bar
    esp_timer_start_periodic(clock_timer_handle_, 1000000);

    // Add MCP common tools (only once during initialization)
    auto& mcp_server = McpServer::GetInstance();
    mcp_server.AddCommonTools();
    mcp_server.AddUserOnlyTools();

    // Set network event callback for UI updates and network state handling
    board.SetNetworkEventCallback([this](NetworkEvent event, const std::string& data) {
        auto display = Board::GetInstance().GetDisplay();
        
        switch (event) {
            case NetworkEvent::Scanning:
                display->ShowNotification(Lang::Strings::SCANNING_WIFI, 30000);
                xEventGroupSetBits(event_group_, MAIN_EVENT_NETWORK_DISCONNECTED);
                break;
            case NetworkEvent::Connecting: {
                if (data.empty()) {
                    // Cellular network - registering without carrier info yet
                    display->SetStatus(Lang::Strings::REGISTERING_NETWORK);
                } else {
                    // WiFi or cellular with carrier info
                    std::string msg = Lang::Strings::CONNECT_TO;
                    msg += data;
                    msg += "...";
                    display->ShowNotification(msg.c_str(), 30000);
                }
                break;
            }
            case NetworkEvent::Connected: {
                last_connected_network_ = data;
                ESP_LOGW(TAG, "==== Application: WiFi 已连上 SSID: %s ====", data.c_str());
                xEventGroupSetBits(event_group_, MAIN_EVENT_NETWORK_CONNECTED);
#ifdef CONFIG_ADHD_KIDS_UI
                RefreshKidsDisplay();
#else
                std::string msg = Lang::Strings::CONNECTED_TO;
                msg += data;
                display->ShowNotification(msg.c_str(), 30000);
#endif
                audio_service_.PlaySound(Lang::Sounds::OGG_SUCCESS);
                break;
            }
            case NetworkEvent::Disconnected:
#ifdef CONFIG_ADHD_KIDS_UI
                last_connected_network_.clear();
                RefreshKidsDisplay();
#endif
                xEventGroupSetBits(event_group_, MAIN_EVENT_NETWORK_DISCONNECTED);
                break;
            case NetworkEvent::WifiConfigModeEnter:
                // WiFi config mode enter is handled by WifiBoard internally
                break;
            case NetworkEvent::WifiConfigModeExit:
                // WiFi config mode exit is handled by WifiBoard internally
                break;
            // Cellular modem specific events
            case NetworkEvent::ModemDetecting:
                display->SetStatus(Lang::Strings::DETECTING_MODULE);
                break;
            case NetworkEvent::ModemErrorNoSim:
                Alert(Lang::Strings::ERROR, Lang::Strings::PIN_ERROR, "triangle_exclamation", Lang::Sounds::OGG_ERR_PIN);
                break;
            case NetworkEvent::ModemErrorRegDenied:
                Alert(Lang::Strings::ERROR, Lang::Strings::REG_ERROR, "triangle_exclamation", Lang::Sounds::OGG_ERR_REG);
                break;
            case NetworkEvent::ModemErrorInitFailed:
                Alert(Lang::Strings::ERROR, Lang::Strings::MODEM_INIT_ERROR, "triangle_exclamation", Lang::Sounds::OGG_EXCLAMATION);
                break;
            case NetworkEvent::ModemErrorTimeout:
                display->SetStatus(Lang::Strings::REGISTERING_NETWORK);
                break;
        }
    });

    // Start network asynchronously
    board.StartNetwork();

    // Update the status bar immediately to show the network state
    display->UpdateStatusBar(true);
}

void Application::Run() {
    // Set the priority of the main task to 10
    vTaskPrioritySet(nullptr, 10);

    const EventBits_t ALL_EVENTS = 
        MAIN_EVENT_SCHEDULE |
        MAIN_EVENT_SEND_AUDIO |
        MAIN_EVENT_WAKE_WORD_DETECTED |
        MAIN_EVENT_VAD_CHANGE |
        MAIN_EVENT_CLOCK_TICK |
        MAIN_EVENT_ERROR |
        MAIN_EVENT_NETWORK_CONNECTED |
        MAIN_EVENT_NETWORK_DISCONNECTED |
        MAIN_EVENT_TOGGLE_CHAT |
        MAIN_EVENT_START_LISTENING |
        MAIN_EVENT_STOP_LISTENING |
        MAIN_EVENT_ACTIVATION_DONE |
        MAIN_EVENT_STATE_CHANGED;

    while (true) {
        auto bits = xEventGroupWaitBits(event_group_, ALL_EVENTS, pdTRUE, pdFALSE, portMAX_DELAY);

        if (bits & MAIN_EVENT_ERROR) {
            SetDeviceState(kDeviceStateIdle);
            Alert(Lang::Strings::ERROR, last_error_message_.c_str(), "circle_xmark", Lang::Sounds::OGG_EXCLAMATION);
        }

        if (bits & MAIN_EVENT_NETWORK_CONNECTED) {
            HandleNetworkConnectedEvent();
        }

        if (bits & MAIN_EVENT_NETWORK_DISCONNECTED) {
            HandleNetworkDisconnectedEvent();
        }

        if (bits & MAIN_EVENT_ACTIVATION_DONE) {
            HandleActivationDoneEvent();
        }

        if (bits & MAIN_EVENT_STATE_CHANGED) {
            HandleStateChangedEvent();
        }

        if (bits & MAIN_EVENT_TOGGLE_CHAT) {
            HandleToggleChatEvent();
        }

        if (bits & MAIN_EVENT_START_LISTENING) {
            HandleStartListeningEvent();
        }

        if (bits & MAIN_EVENT_STOP_LISTENING) {
            HandleStopListeningEvent();
        }

        if (bits & MAIN_EVENT_SEND_AUDIO) {
            while (auto packet = audio_service_.PopPacketFromSendQueue()) {
                if (protocol_ && !protocol_->SendAudio(std::move(packet))) {
                    break;
                }
            }
        }

        if (bits & MAIN_EVENT_WAKE_WORD_DETECTED) {
            HandleWakeWordDetectedEvent();
        }

        if (bits & MAIN_EVENT_VAD_CHANGE) {
            if (GetDeviceState() == kDeviceStateListening) {
                const bool voice_detected = IsVoiceDetected();
                if (listening_mode_ == kListeningModeAutoStop) {
                    const int64_t now_ms = esp_timer_get_time() / 1000;
                    const int64_t listening_ms = now_ms - auto_stop_listen_started_ms_;
                    if (voice_detected) {
                        if (listening_ms >= kAutoStopIgnoreInitialVadMs) {
                            if (!auto_stop_voice_seen_) {
                                auto_stop_voice_started_ms_ = now_ms;
                                auto_stop_voice_quiet_before_ms_ = listening_ms;
                                auto_stop_endpoint_delay_ms_ =
                                    AutoStopEndpointDelayMs(auto_stop_voice_quiet_before_ms_);
                                ESP_LOGI(TAG, "VAD voice (listen=%lldms, endpoint_delay=%lldms)",
                                         listening_ms, auto_stop_endpoint_delay_ms_);
                            }
                            auto_stop_voice_seen_ = true;
                        } else {
                            ESP_LOGI(TAG, "VAD voice ignored (listen=%lldms < %lldms)",
                                     listening_ms, kAutoStopIgnoreInitialVadMs);
                        }
                        // 仍在说话：只有 endpoint 倒计时尚未启动时才清静音点。
                        // 启动后不再被 VAD 抖动取消，否则静音中的假 speech 会让
                        // 这一轮永远等不到 SendStopListening。
                        if (!auto_stop_endpoint_timer_armed_) {
                            auto_stop_silence_started_ms_ = 0;
                        }
                    } else if (auto_stop_voice_seen_ && !auto_stop_endpoint_timer_armed_) {
                        // 第一次进入静音：启动 one-shot endpoint 倒计时。
                        // 后续 VAD 抖动不重启这个 timer，让 timer 自己裁决。
                        auto_stop_silence_started_ms_ = now_ms;
                        auto_stop_endpoint_timer_armed_ = true;
                        const int64_t spoke_ms = now_ms - auto_stop_voice_started_ms_;
                        ESP_LOGI(TAG, "VAD silent → endpoint timer armed (spoke=%lldms)",
                                 spoke_ms);
                        if (endpoint_timer_handle_ != nullptr) {
                            esp_timer_stop(endpoint_timer_handle_);
                            esp_timer_start_once(endpoint_timer_handle_,
                                                 auto_stop_endpoint_delay_ms_ * 1000);
                        }
                    }
                }
                auto led = Board::GetInstance().GetLed();
                led->OnStateChanged();
            }
        }

        if (bits & MAIN_EVENT_SCHEDULE) {
            std::unique_lock<std::mutex> lock(mutex_);
            auto tasks = std::move(main_tasks_);
            lock.unlock();
            for (auto& task : tasks) {
                task();
            }
        }

        if (bits & MAIN_EVENT_CLOCK_TICK) {
            clock_ticks_++;
            auto display = Board::GetInstance().GetDisplay();
            display->UpdateStatusBar();

            // 真正的 endpoint 检测改用 one-shot esp_timer（OnEndpointTimer）；
            // 这里 1 Hz 只做兜底：
            //   (a) 已经听到过说话但 VAD 一直没稳定 endpoint，最长 12s 提交。
            //   (b) 一直没有有效回答，达到 60s 关闭本轮，避免机器人自言自语。
            if (GetDeviceState() == kDeviceStateListening &&
                listening_mode_ == kListeningModeAutoStop && protocol_) {
                const int64_t now_ms = esp_timer_get_time() / 1000;
                const int64_t listening_ms = now_ms - auto_stop_listen_started_ms_;
                const int64_t utterance_ms = auto_stop_voice_started_ms_ > 0
                    ? now_ms - auto_stop_voice_started_ms_
                    : listening_ms;
                if (auto_stop_voice_seen_ &&
                    utterance_ms >= kAutoStopMaxUtteranceMs &&
                    protocol_->IsAudioChannelOpened()) {
                    ESP_LOGI(TAG, "Max utterance: %lldms voice / %lldms listening → stop",
                             utterance_ms, listening_ms);
                    auto_stop_endpoint_timer_armed_ = false;
                    if (endpoint_timer_handle_ != nullptr) {
                        esp_timer_stop(endpoint_timer_handle_);
                    }
                    protocol_->SendStopListening();
                    SetDeviceState(kDeviceStateIdle);
                } else if (!auto_stop_voice_seen_ &&
                           listening_ms >= kAutoCloseIdleTimeoutMs &&
                           protocol_->IsAudioChannelOpened()) {
                    ESP_LOGI(TAG, "Sleep idle timeout: %lldms no voice in Listening", listening_ms);
                    EnterSleepPowerSaveMode("idle 60s no voice", false);
                }
            }

            // Print debug info every 10 seconds
            if (clock_ticks_ % 10 == 0) {
                SystemInfo::PrintHeapStats();
            }
        }
    }
}

void Application::HandleNetworkConnectedEvent() {
    ESP_LOGI(TAG, "Network connected");
    auto state = GetDeviceState();

    if (state == kDeviceStateStarting || state == kDeviceStateWifiConfiguring) {
        // Network is ready, start activation
        SetDeviceState(kDeviceStateActivating);
        if (activation_task_handle_ != nullptr) {
            ESP_LOGW(TAG, "Activation task already running");
            return;
        }

        xTaskCreate([](void* arg) {
            Application* app = static_cast<Application*>(arg);
            app->ActivationTask();
            app->activation_task_handle_ = nullptr;
            vTaskDelete(NULL);
        }, "activation", 4096 * 2, this, 2, &activation_task_handle_);
    }

    // Update the status bar immediately to show the network state
    auto display = Board::GetInstance().GetDisplay();
    display->UpdateStatusBar(true);
#ifdef CONFIG_ADHD_KIDS_UI
    RefreshKidsDisplay();
#endif
}

void Application::HandleNetworkDisconnectedEvent() {
    // Close current conversation when network disconnected
    auto state = GetDeviceState();
    if (state == kDeviceStateConnecting || state == kDeviceStateListening || state == kDeviceStateSpeaking) {
        ESP_LOGI(TAG, "Closing audio channel due to network disconnection");
        protocol_->CloseAudioChannel();
    }

    // Update the status bar immediately to show the network state
    auto display = Board::GetInstance().GetDisplay();
    display->UpdateStatusBar(true);
#ifdef CONFIG_ADHD_KIDS_UI
    RefreshKidsDisplay();
#endif
}

void Application::HandleActivationDoneEvent() {
    ESP_LOGI(TAG, "Activation done");

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
    // 在用户的串口里强制留下一行，便于确认实际烧录的固件是否包含 Path A 集成。
    // 之前用户多次反映"Flutter 显示配网失败"，但日志里完全没有 adhd_cmd 行，
    // 往往是 c:\adhd_monitor\... 这个独立 checkout 没有同步最新代码就 rebuild。
    ESP_LOGW(TAG, "ADHD path A active: announce host=%s:%d ws=%s",
             CONFIG_ADHD_MONITOR_CMD_HOST,
             CONFIG_ADHD_MONITOR_CMD_PORT,
             CONFIG_ADHD_MONITOR_WS_URL);
#endif

    SystemInfo::PrintHeapStats();
    bool welcome_pending = false;
#if HAVE_LVGL
    welcome_pending = g_power_on_welcome_armed.exchange(false);
    if (welcome_pending) {
        g_power_welcome_shake_gate.store(1);
    }
#endif
    SetDeviceState(kDeviceStateIdle);

    auto display = Board::GetInstance().GetDisplay();
    // 屏幕上显式打出"已连接到云端 + 当前 AP 名 + 固件版本"，6 秒。
    // 之前这里只显示 "版本 2.2.4" 一条，没有云端就绪的反馈，
    // 也没有把 AP 名留在屏幕上。把 SSID 一并打出来，可以一眼看出
    // 板子是不是真的接到了配网时填的那个热点（防止串号 / 邻居热点
    // 把 BSSID 抢走的小概率坑）。
    std::string message;
    if (!last_connected_network_.empty()) {
        message += "云端已连接\n";
        message += last_connected_network_;
        message += "\n";
    }
    auto app_desc = esp_app_get_description();
    const char* app_version = app_desc != nullptr ? app_desc->version : "unknown";
    message += std::string(Lang::Strings::VERSION) + app_version;
    display->ShowNotification(message.c_str(), 6000);
    display->SetChatMessage("system", "");
    ESP_LOGI(TAG, "Cloud ready, ssid=%s, version=%s",
             last_connected_network_.c_str(),
             app_version);
    auto& board = Board::GetInstance();
    board.SetPowerSaveLevel(PowerSaveLevel::LOW_POWER);

#if HAVE_LVGL
    bool welcome_started = false;
    if (welcome_pending) {
        if (xTaskCreate(PowerOnWelcomeTask, "pwr_welcome", 4096, nullptr, 3, nullptr) == pdPASS) {
            welcome_started = true;
        } else {
            g_power_on_welcome_armed = true;
            g_power_welcome_shake_gate.store(0);
        }
    }
    if (!welcome_started) {
        Schedule([this]() { audio_service_.PlaySound(Lang::Sounds::OGG_SUCCESS); });
    }
#else
    Schedule([this]() {
        // Play the success sound to indicate the device is ready
        audio_service_.PlaySound(Lang::Sounds::OGG_SUCCESS);
    });
#endif

#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
    // 同步登记：避免仅依赖后台任务时序（或烧录了与 build 不一致的 elf）
    // 导致 App 拉 esp32/list 时库里还没有 device 行。
    adhd_remote_cmd_announce_sync_once();
#endif
    adhd_remote_cmd_start();

}

bool Application::SyncClockFromMonitorServer() {
#if CONFIG_ADHD_MONITOR_REMOTE_CMD || CONFIG_ADHD_MONITOR_BYPASS_OTA
    // Ask the ADHD Monitor Flask service for a small UTC timestamp.
    setenv("TZ", "CST-8", 1);
    tzset();

    std::string url = std::string("http://") + CONFIG_ADHD_MONITOR_CMD_HOST + ":" +
                      std::to_string(CONFIG_ADHD_MONITOR_CMD_PORT) + "/time";
    auto http = Board::GetInstance().GetNetwork()->CreateHttp(0);
    http->SetTimeout(5000);
    if (!http->Open("GET", url)) {
        ESP_LOGW(TAG, "Clock sync open failed: %s", url.c_str());
        return false;
    }
    const int status_code = http->GetStatusCode();
    std::string body = http->ReadAll();
    http->Close();
    if (status_code != 200) {
        ESP_LOGW(TAG, "Clock sync failed, status=%d body=%s", status_code, body.c_str());
        return false;
    }

    cJSON* root = cJSON_Parse(body.c_str());
    if (root == nullptr) {
        ESP_LOGW(TAG, "Clock sync invalid JSON: %s", body.c_str());
        return false;
    }
    cJSON* timestamp_ms = cJSON_GetObjectItem(root, "timestamp_ms");
    if (!cJSON_IsNumber(timestamp_ms)) {
        cJSON_Delete(root);
        ESP_LOGW(TAG, "Clock sync response missing timestamp_ms");
        return false;
    }

    const double ms = timestamp_ms->valuedouble;
    struct timeval tv;
    tv.tv_sec = static_cast<time_t>(ms / 1000);
    tv.tv_usec = static_cast<suseconds_t>(static_cast<long long>(ms) % 1000) * 1000;
    settimeofday(&tv, nullptr);
    has_server_time_ = true;
    cJSON_Delete(root);

    char buf[32] = {0};
    time_t now = time(nullptr);
    struct tm* tm = localtime(&now);
    if (tm != nullptr) {
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", tm);
    }
    ESP_LOGI(TAG, "Clock synced from ADHD Monitor: %s", buf);
    Board::GetInstance().GetDisplay()->UpdateStatusBar(true);
    return true;
#else
    return false;
#endif
}

void Application::ActivationTask() {
#if CONFIG_ADHD_MONITOR_BYPASS_OTA
    ESP_LOGI(TAG, "ADHD local firmware mode: seeding websocket NVS from Kconfig");
    adhd_remote_cmd_seed_settings();
    SyncClockFromMonitorServer();
#else
    CheckAssetsVersion();
#endif

    // Initialize the protocol
    InitializeProtocol();

    // Signal completion to main loop
    xEventGroupSetBits(event_group_, MAIN_EVENT_ACTIVATION_DONE);
}

void Application::CheckAssetsVersion() {
    // Only allow CheckAssetsVersion to be called once
    if (assets_version_checked_) {
        return;
    }
    assets_version_checked_ = true;

    auto& board = Board::GetInstance();
    auto display = board.GetDisplay();
    auto& assets = Assets::GetInstance();

    if (!assets.partition_valid()) {
        ESP_LOGW(TAG, "Assets partition is disabled for board %s", BOARD_NAME);
        return;
    }
    
    Settings settings("assets", true);
    // Check if there is a new assets need to be downloaded
    std::string download_url = settings.GetString("download_url");

    if (!download_url.empty()) {
        settings.EraseKey("download_url");

        char message[256];
        snprintf(message, sizeof(message), Lang::Strings::FOUND_NEW_ASSETS, download_url.c_str());
        Alert(Lang::Strings::LOADING_ASSETS, message, "cloud_arrow_down", Lang::Sounds::OGG_UPGRADE);
        
        // Wait for the audio service to be idle for 3 seconds
        vTaskDelay(pdMS_TO_TICKS(3000));
        SetDeviceState(kDeviceStateUpgrading);
        board.SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);
        display->SetChatMessage("system", Lang::Strings::PLEASE_WAIT);

        bool success = assets.Download(download_url, [this, display](int progress, size_t speed) -> void {
            char buffer[32];
            snprintf(buffer, sizeof(buffer), "%d%% %uKB/s", progress, speed / 1024);
            Schedule([display, message = std::string(buffer)]() {
                display->SetChatMessage("system", message.c_str());
            });
        });

        board.SetPowerSaveLevel(PowerSaveLevel::LOW_POWER);
        vTaskDelay(pdMS_TO_TICKS(1000));

        if (!success) {
            Alert(Lang::Strings::ERROR, Lang::Strings::DOWNLOAD_ASSETS_FAILED, "circle_xmark", Lang::Sounds::OGG_EXCLAMATION);
            vTaskDelay(pdMS_TO_TICKS(2000));
            SetDeviceState(kDeviceStateActivating);
            return;
        }
    }

    // Apply assets
    assets.Apply();
    display->SetChatMessage("system", "");
    display->SetEmotion("microchip_ai");
}

void Application::InitializeProtocol() {
    auto& board = Board::GetInstance();
    auto display = board.GetDisplay();
    auto codec = board.GetAudioCodec();

    display->SetStatus(Lang::Strings::LOADING_PROTOCOL);

#if CONFIG_ADHD_MONITOR_BYPASS_OTA
    // Path A always speaks WebSocket against ADHD_Monitor Flask.
    ESP_LOGI(TAG, "ADHD local firmware mode: forcing WebsocketProtocol");
    protocol_ = std::make_unique<WebsocketProtocol>();
#else
    ESP_LOGI(TAG, "Using MQTT protocol");
    protocol_ = std::make_unique<MqttProtocol>();
#endif

    protocol_->OnConnected([this]() {
        DismissAlert();
    });

    protocol_->OnNetworkError([this](const std::string& message) {
        last_error_message_ = message;
        xEventGroupSetBits(event_group_, MAIN_EVENT_ERROR);
    });
    
    protocol_->OnIncomingAudio([this](std::unique_ptr<AudioStreamPacket> packet) {
        // 下行 Opus 与 JSON 在同一条 WebSocket 回调链里顺序到达：服务器先发
        // `tts state=start`，固件里用 Schedule() 异步切到 kDeviceStateSpeaking；
        // 若紧接着就发二进制帧，此时状态往往仍是 Listening/Connecting，
        // 旧逻辑「仅 Speaking 才入队」会把整段 TTS 全部丢光 → 星星机器人完全没声音。
        const auto st = GetDeviceState();
        const bool ch_open = protocol_->IsAudioChannelOpened();
        if (st == kDeviceStateSpeaking) {
            audio_service_.PushPacketToDecodeQueue(std::move(packet), true);
        } else if (ch_open && (st == kDeviceStateConnecting || st == kDeviceStateListening || st == kDeviceStateIdle)) {
            audio_service_.PushPacketToDecodeQueue(std::move(packet), true);
        }
    });
    
    protocol_->OnAudioChannelOpened([this, codec, &board]() {
        board.SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);
        if (protocol_->server_sample_rate() != codec->output_sample_rate()) {
            ESP_LOGW(TAG, "Server sample rate %d does not match device output sample rate %d, resampling may cause distortion",
                protocol_->server_sample_rate(), codec->output_sample_rate());
        }
    });
    
    protocol_->OnAudioChannelClosed([this, &board]() {
        // 休眠省电时关会话会走到这里；LOW_POWER modem 休眠在部分路由器上易断线，
        // 计划表与 Path A 长轮询需要稳定 STA，故休眠中维持 PERFORMANCE。
        board.SetPowerSaveLevel(sleep_power_save_mode_ ? PowerSaveLevel::PERFORMANCE
                                                       : PowerSaveLevel::LOW_POWER);
        Schedule([this]() {
            auto display = Board::GetInstance().GetDisplay();
            display->SetChatMessage("system", "");
            SetDeviceState(kDeviceStateIdle);
        });
    });
    
    protocol_->OnIncomingJson([this, display](const cJSON* root) {
        // Parse JSON data
        auto type = cJSON_GetObjectItem(root, "type");
        if (strcmp(type->valuestring, "tts") == 0) {
            auto state = cJSON_GetObjectItem(root, "state");
            if (strcmp(state->valuestring, "start") == 0) {
                Schedule([this]() {
                    if (session_termination_requested_) {
                        return;
                    }
                    aborted_ = false;
                    SetDeviceState(kDeviceStateSpeaking);
                });
            } else if (strcmp(state->valuestring, "stop") == 0) {
                Schedule([this]() {
                    if (session_termination_requested_) {
                        return;
                    }
                    if (GetDeviceState() == kDeviceStateSpeaking) {
                        audio_service_.WaitForPlaybackQueueEmpty();
                        if (listening_mode_ == kListeningModeManualStop) {
                            SetDeviceState(kDeviceStateIdle);
                        } else {
                            SetDeviceState(kDeviceStateListening);
                        }
                    }
                });
            } else if (strcmp(state->valuestring, "sentence_start") == 0) {
                auto text = cJSON_GetObjectItem(root, "text");
                if (cJSON_IsString(text)) {
                    ESP_LOGI(TAG, "<< %s", text->valuestring);
                    Schedule([display, message = std::string(text->valuestring)]() {
                        display->SetChatMessage("assistant", message.c_str());
                    });
                }
            }
        } else if (strcmp(type->valuestring, "stt") == 0) {
            auto text = cJSON_GetObjectItem(root, "text");
            if (cJSON_IsString(text)) {
                ESP_LOGI(TAG, ">> %s", text->valuestring);
                const std::string message(text->valuestring);
                const bool stop_session = IsSessionStopCommand(message);
                Schedule([this, display, message, stop_session]() {
                    display->SetChatMessage("user", message.c_str());
                    if (stop_session) {
                        EnterSleepPowerSaveMode("user stop command", true);
                    }
                });
            }
        } else if (strcmp(type->valuestring, "llm") == 0) {
            auto emotion = cJSON_GetObjectItem(root, "emotion");
            if (cJSON_IsString(emotion)) {
                Schedule([display, emotion_str = std::string(emotion->valuestring)]() {
#ifdef CONFIG_ADHD_KIDS_UI
                    display->SetEmotion(SoftEmotionForKids(emotion_str.c_str()));
#else
                    display->SetEmotion(emotion_str.c_str());
#endif
                });
            }
        } else if (strcmp(type->valuestring, "mcp") == 0) {
            auto payload = cJSON_GetObjectItem(root, "payload");
            if (cJSON_IsObject(payload)) {
                McpServer::GetInstance().ParseMessage(payload);
            }
        } else if (strcmp(type->valuestring, "system") == 0) {
            auto command = cJSON_GetObjectItem(root, "command");
            if (cJSON_IsString(command)) {
                ESP_LOGI(TAG, "System command: %s", command->valuestring);
                if (strcmp(command->valuestring, "reboot") == 0) {
                    Schedule([this]() {
                        Reboot();
                    });
                } else {
                    ESP_LOGW(TAG, "Unknown system command: %s", command->valuestring);
                }
            }
        } else if (strcmp(type->valuestring, "alert") == 0) {
            auto status = cJSON_GetObjectItem(root, "status");
            auto message = cJSON_GetObjectItem(root, "message");
            auto emotion = cJSON_GetObjectItem(root, "emotion");
            if (cJSON_IsString(status) && cJSON_IsString(message) && cJSON_IsString(emotion)) {
                Alert(status->valuestring, message->valuestring, emotion->valuestring, Lang::Sounds::OGG_VIBRATION);
            } else {
                ESP_LOGW(TAG, "Alert command requires status, message and emotion");
            }
#if CONFIG_RECEIVE_CUSTOM_MESSAGE
        } else if (strcmp(type->valuestring, "custom") == 0) {
            auto payload = cJSON_GetObjectItem(root, "payload");
            ESP_LOGI(TAG, "Received custom message: %s", cJSON_PrintUnformatted(root));
            if (cJSON_IsObject(payload)) {
                Schedule([this, display, payload_str = std::string(cJSON_PrintUnformatted(payload))]() {
                    display->SetChatMessage("system", payload_str.c_str());
                });
            } else {
                ESP_LOGW(TAG, "Invalid custom message format: missing payload");
            }
#endif
        } else {
            ESP_LOGW(TAG, "Unknown message type: %s", type->valuestring);
        }
    });
    
    protocol_->Start();
}

void Application::ShowActivationCode(const std::string& code, const std::string& message) {
    struct digit_sound {
        char digit;
        const std::string_view& sound;
    };
    static const std::array<digit_sound, 10> digit_sounds{{
        digit_sound{'0', Lang::Sounds::OGG_0},
        digit_sound{'1', Lang::Sounds::OGG_1}, 
        digit_sound{'2', Lang::Sounds::OGG_2},
        digit_sound{'3', Lang::Sounds::OGG_3},
        digit_sound{'4', Lang::Sounds::OGG_4},
        digit_sound{'5', Lang::Sounds::OGG_5},
        digit_sound{'6', Lang::Sounds::OGG_6},
        digit_sound{'7', Lang::Sounds::OGG_7},
        digit_sound{'8', Lang::Sounds::OGG_8},
        digit_sound{'9', Lang::Sounds::OGG_9}
    }};

    // This sentence uses 9KB of SRAM, so we need to wait for it to finish
    Alert(Lang::Strings::ACTIVATION, message.c_str(), "link", Lang::Sounds::OGG_ACTIVATION);

    for (const auto& digit : code) {
        auto it = std::find_if(digit_sounds.begin(), digit_sounds.end(),
            [digit](const digit_sound& ds) { return ds.digit == digit; });
        if (it != digit_sounds.end()) {
            audio_service_.PlaySound(it->sound);
        }
    }
}

void Application::Alert(const char* status, const char* message, const char* emotion, const std::string_view& sound) {
    ESP_LOGW(TAG, "Alert [%s] %s: %s", emotion, status, message);
    auto display = Board::GetInstance().GetDisplay();
#ifdef CONFIG_ADHD_KIDS_UI
    display->SetWelcomeTitle(Lang::Strings::WELCOME_TITLE);
    if (message != nullptr && message[0] != '\0') {
        display->SetCenterStatus(message);
    } else {
        display->SetCenterStatus(status);
    }
    display->SetEmotion(SoftEmotionForKids(emotion));
#else
    display->SetStatus(status);
    display->SetEmotion(emotion);
#endif
    display->SetChatMessage("system", message);
    if (!sound.empty()) {
        audio_service_.PlaySound(sound);
    }
}

void Application::DismissAlert() {
    if (GetDeviceState() == kDeviceStateIdle) {
        auto display = Board::GetInstance().GetDisplay();
#ifdef CONFIG_ADHD_KIDS_UI
        display->SetChatMessage("system", "");
        RefreshKidsDisplay();
#else
        display->SetStatus(Lang::Strings::STANDBY);
        display->SetEmotion("neutral");
        display->SetChatMessage("system", "");
#endif
    }
}

void Application::ToggleChatState() {
    xEventGroupSetBits(event_group_, MAIN_EVENT_TOGGLE_CHAT);
}

void Application::StartListening() {
    xEventGroupSetBits(event_group_, MAIN_EVENT_START_LISTENING);
}

void Application::StopListening() {
    xEventGroupSetBits(event_group_, MAIN_EVENT_STOP_LISTENING);
}

void Application::HandleToggleChatEvent() {
    auto state = GetDeviceState();
    
    if (state == kDeviceStateActivating) {
        SetDeviceState(kDeviceStateIdle);
        return;
    } else if (state == kDeviceStateWifiConfiguring) {
        audio_service_.EnableAudioTesting(true);
        SetDeviceState(kDeviceStateAudioTesting);
        return;
    } else if (state == kDeviceStateAudioTesting) {
        audio_service_.EnableAudioTesting(false);
        SetDeviceState(kDeviceStateWifiConfiguring);
        return;
    }

    if (!protocol_) {
        ESP_LOGE(TAG, "Protocol not initialized");
        return;
    }

    if (state == kDeviceStateIdle) {
        ListeningMode mode = GetDefaultListeningMode();
        if (!protocol_->IsAudioChannelOpened()) {
            SetDeviceState(kDeviceStateConnecting);
            // Schedule to let the state change be processed first (UI update)
            Schedule([this, mode]() {
                ContinueOpenAudioChannel(mode);
            });
            return;
        }
        SetListeningMode(mode);
    } else if (state == kDeviceStateSpeaking) {
        AbortSpeaking(kAbortReasonNone);
    } else if (state == kDeviceStateListening) {
        protocol_->CloseAudioChannel();
    }
}

void Application::ContinueOpenAudioChannel(ListeningMode mode) {
    // Check state again in case it was changed during scheduling
    if (GetDeviceState() != kDeviceStateConnecting) {
        return;
    }

    if (!protocol_->IsAudioChannelOpened()) {
        if (!protocol_->OpenAudioChannel()) {
            return;
        }
    }

    SetListeningMode(mode);
}

void Application::HandleStartListeningEvent() {
    auto state = GetDeviceState();
    
    if (state == kDeviceStateActivating) {
        SetDeviceState(kDeviceStateIdle);
        return;
    } else if (state == kDeviceStateWifiConfiguring) {
        audio_service_.EnableAudioTesting(true);
        SetDeviceState(kDeviceStateAudioTesting);
        return;
    }

    if (!protocol_) {
        ESP_LOGE(TAG, "Protocol not initialized");
        return;
    }
    
    if (state == kDeviceStateIdle) {
        if (!protocol_->IsAudioChannelOpened()) {
            SetDeviceState(kDeviceStateConnecting);
            // Schedule to let the state change be processed first (UI update)
            Schedule([this]() {
                ContinueOpenAudioChannel(kListeningModeManualStop);
            });
            return;
        }
        SetListeningMode(kListeningModeManualStop);
    } else if (state == kDeviceStateSpeaking) {
        AbortSpeaking(kAbortReasonNone);
        SetListeningMode(kListeningModeManualStop);
    }
}

void Application::HandleStopListeningEvent() {
    auto state = GetDeviceState();
    
    if (state == kDeviceStateAudioTesting) {
        audio_service_.EnableAudioTesting(false);
        SetDeviceState(kDeviceStateWifiConfiguring);
        return;
    } else if (state == kDeviceStateListening) {
        if (protocol_) {
            protocol_->SendStopListening();
        }
        SetDeviceState(kDeviceStateIdle);
    }
}

void Application::HandleWakeWordDetectedEvent() {
    if (!protocol_) {
        return;
    }

    auto state = GetDeviceState();
    auto wake_word = audio_service_.GetLastWakeWord();
    ESP_LOGI(TAG, "Wake word detected: %s (state: %d)", wake_word.c_str(), (int)state);

    if (state == kDeviceStateIdle) {
        audio_service_.EncodeWakeWord();
        // Treat any built-in local wake-word hit as the child calling
        // "你好小星星", then start the same server-side flow as the Flutter
        // "wake Star" button.
        std::string wake_word = kXiaoxingxingWakeOpeningLine;

        if (!protocol_->IsAudioChannelOpened()) {
            SetDeviceState(kDeviceStateConnecting);
            // Schedule to let the state change be processed first (UI update),
            // then continue with OpenAudioChannel which may block for ~1 second
            Schedule([this, wake_word]() {
                ContinueWakeWordInvoke(wake_word);
            });
            return;
        }
        // Channel already opened, continue directly
        ContinueWakeWordInvoke(wake_word);
    } else if (state == kDeviceStateSpeaking || state == kDeviceStateListening) {
        AbortSpeaking(kAbortReasonWakeWordDetected);
        // Clear send queue to avoid sending residues to server
        audio_service_.ClearSendQueue();

        if (state == kDeviceStateListening) {
            protocol_->SendStartListening(GetDefaultListeningMode());
            audio_service_.ResetDecoder();
            audio_service_.PlaySound(Lang::Sounds::OGG_POPUP);
            // Re-enable wake word detection as it was stopped by the detection itself
            audio_service_.EnableWakeWordDetection(true);
        } else {
            // Play popup sound and start listening again
            play_popup_on_listening_ = true;
            SetListeningMode(GetDefaultListeningMode());
        }
    } else if (state == kDeviceStateActivating) {
        // Restart the activation check if the wake word is detected during activation
        SetDeviceState(kDeviceStateIdle);
    }
}

void Application::ContinueWakeWordInvoke(const std::string& wake_word) {
    // Check state again in case it was changed during scheduling
    if (GetDeviceState() != kDeviceStateConnecting) {
        return;
    }

    if (!protocol_->IsAudioChannelOpened()) {
        if (!protocol_->OpenAudioChannel()) {
            audio_service_.EnableWakeWordDetection(true);
            return;
        }
    }

    ESP_LOGI(TAG, "Wake word detected: %s", wake_word.c_str());
#if CONFIG_SEND_WAKE_WORD_DATA
    // Encode and send the wake word data to the server
    while (auto packet = audio_service_.PopWakeWordPacket()) {
        protocol_->SendAudio(std::move(packet));
    }
    // Set the chat state to wake word detected
    protocol_->SendWakeWordDetected(wake_word);

    // Set flag to play popup sound after state changes to listening
    play_popup_on_listening_ = true;
    SetListeningMode(GetDefaultListeningMode());
#else
    // Set flag to play popup sound after state changes to listening
    // (PlaySound here would be cleared by ResetDecoder in EnableVoiceProcessing)
    play_popup_on_listening_ = true;
    SetListeningMode(GetDefaultListeningMode());
#endif
}

void Application::OnStateChanged(DeviceState old_state, DeviceState new_state) {
    last_state_transition_from_ = old_state;
    // Any state transition out of Listening invalidates a pending endpoint
    // timer (esp_timer_stop is safe to call when the timer is not running).
    if (new_state != kDeviceStateListening && endpoint_timer_handle_ != nullptr) {
        esp_timer_stop(endpoint_timer_handle_);
    }
    xEventGroupSetBits(event_group_, MAIN_EVENT_STATE_CHANGED);
}

#ifdef CONFIG_ADHD_KIDS_UI
const char* Application::SoftEmotionForKids(const char* emotion) {
    if (emotion == nullptr || emotion[0] == '\0') {
        return "happy";
    }
    if (strcmp(emotion, "angry") == 0 || strcmp(emotion, "crying") == 0) {
        return "surprised";
    }
    if (strcmp(emotion, "sad") == 0) {
        return "thinking";
    }
    return emotion;
}

static const char* PickKidsStatusLine(const char* const* lines, size_t count) {
    if (count == 0) {
        return "";
    }
    const int64_t seconds = esp_timer_get_time() / 1000000;
    return lines[(seconds / 8) % count];
}

void Application::RefreshKidsDisplay() {
#if HAVE_LVGL
    const int gate = g_power_welcome_shake_gate.load();
    if (gate == 1 || gate == 2) {
        return;
    }
    // 行动卡片全屏图期间勿用 Kids 中心表情/文案盖住画面（否则会像「只剩小笑脸」）。
    if (ActionCards::GetInstance().IsActive()) {
        return;
    }
    if (adhd_path_a_intro_suppresses_kids()) {
        return;
    }
#endif
    if (visual_choice_mode_) {
        return;
    }
    auto display = Board::GetInstance().GetDisplay();
    display->SetWelcomeTitle("");

    // MAIN_EVENT_NETWORK_CONNECTED is cleared after HandleNetworkConnectedEvent;
    // use last_connected_network_ as the persistent "have Wi-Fi SSID" signal.
    const bool have_wifi_ssid = !last_connected_network_.empty();

    const char* emotion = "neutral";
    std::string center;

    if (sleep_power_save_mode_) {
        center = "休眠省电中";
        emotion = "sleepy";
    } else {
        switch (state_machine_.GetState()) {
            case kDeviceStateWifiConfiguring:
                if (have_wifi_ssid) {
                    center = "网络准备好了";
                    emotion = "relaxed";
                } else {
                    center = Lang::Strings::WAITING_WIFI_CONFIG;
                    emotion = "winking";
                }
                break;
            case kDeviceStateListening:
                {
                    static const char* const kListeningLines[] = {
                        "我在听，慢慢说",
                        "不用急，我会等你"
                    };
                    center = PickKidsStatusLine(kListeningLines,
                                                sizeof(kListeningLines) / sizeof(kListeningLines[0]));
                }
                emotion = "thinking";
                break;
            case kDeviceStateSpeaking:
                {
                    static const char* const kSpeakingLines[] = {
                        "我慢慢说完这一句",
                        "一边想，一边陪你"
                    };
                    center = PickKidsStatusLine(kSpeakingLines,
                                                sizeof(kSpeakingLines) / sizeof(kSpeakingLines[0]));
                }
                emotion = "happy";
                break;
            case kDeviceStateConnecting:
                center = Lang::Strings::CONNECTING;
                emotion = "neutral";
                break;
            case kDeviceStateIdle:
                if (have_wifi_ssid) {
                    static const char* const kIdleLines[] = {
                        reinterpret_cast<const char*>(u8"\u671f\u5f85\u4f60\u7684\u4e3b\u52a8\u9009\u62e9\u54e6"),
                        "准备好了就说一声",
                        "今天也可以慢慢来"
                    };
                    center = PickKidsStatusLine(kIdleLines,
                                                sizeof(kIdleLines) / sizeof(kIdleLines[0]));
                    emotion = "relaxed";
                } else {
                    center = Lang::Strings::WAITING_WIFI_CONFIG;
                    emotion = "winking";
                }
                break;
            default:
                if (have_wifi_ssid) {
                    center = "我在准备下一句话";
                    emotion = "happy";
                } else {
                    center = Lang::Strings::WAITING_WIFI_CONFIG;
                    emotion = "winking";
                }
                break;
        }
    }

    display->SetCenterStatus(center.c_str());
    display->SetEmotion(emotion);
}
#endif

void Application::HandleStateChangedEvent() {
    DeviceState new_state = state_machine_.GetState();
    clock_ticks_ = 0;

    auto& board = Board::GetInstance();
    auto display = board.GetDisplay();
    auto led = board.GetLed();
    led->OnStateChanged();
    
    switch (new_state) {
        case kDeviceStateUnknown:
        case kDeviceStateIdle:
#ifndef CONFIG_ADHD_KIDS_UI
            display->SetStatus(sleep_power_save_mode_ ? "休眠省电中" : Lang::Strings::STANDBY);
            display->ClearChatMessages();  // Clear messages first
            display->SetEmotion("neutral"); // Then set emotion (wechat mode checks child count)
#endif
            audio_service_.EnableVoiceProcessing(false);
            audio_service_.EnableWakeWordDetection(true);
            break;
        case kDeviceStateConnecting:
            sleep_power_save_mode_ = false;
            RestoreApplicationSleepDisplay();
#ifndef CONFIG_ADHD_KIDS_UI
            display->SetStatus(Lang::Strings::CONNECTING);
            display->SetEmotion("neutral");
            display->SetChatMessage("system", "");
#endif
            break;
        case kDeviceStateListening:
            sleep_power_save_mode_ = false;
            RestoreApplicationSleepDisplay();
#ifndef CONFIG_ADHD_KIDS_UI
            display->SetStatus(Lang::Strings::LISTENING);
            display->SetEmotion("neutral");
#endif
            session_termination_requested_ = false;
            auto_stop_voice_seen_ = false;
            auto_stop_listen_started_ms_ = esp_timer_get_time() / 1000;
            auto_stop_voice_started_ms_ = 0;
            auto_stop_silence_started_ms_ = 0;
            auto_stop_voice_quiet_before_ms_ = 0;
            auto_stop_endpoint_delay_ms_ = kAutoStopBaseSilenceMs;
            auto_stop_endpoint_timer_armed_ = false;
            auto_stop_short_speech_total_ms_ = 0;
            auto_stop_short_speech_count_ = 0;
            // Cancel any leftover endpoint timer from a previous turn.
            if (endpoint_timer_handle_ != nullptr) {
                esp_timer_stop(endpoint_timer_handle_);
            }

            if (visual_choice_mode_) {
                audio_service_.EnableVoiceProcessing(false);
                audio_service_.EnableWakeWordDetection(false);
                break;
            }

            // Make sure the audio processor is running
            if (play_popup_on_listening_ || !audio_service_.IsAudioProcessorRunning()) {
                // For auto mode, wait for playback queue to be empty before enabling voice processing
                // This prevents audio truncation when STOP arrives late due to network jitter
                if (listening_mode_ == kListeningModeAutoStop) {
                    audio_service_.WaitForPlaybackQueueEmpty();
                }
                
                // Send the start listening command
                audio_service_.ClearSendQueue();
                protocol_->SendStartListening(listening_mode_);
                audio_service_.EnableVoiceProcessing(true);
            }

#ifdef CONFIG_WAKE_WORD_DETECTION_IN_LISTENING
            // Enable wake word detection in listening mode (configured via Kconfig)
            audio_service_.EnableWakeWordDetection(audio_service_.IsAfeWakeWord());
#else
            // Disable wake word detection in listening mode
            audio_service_.EnableWakeWordDetection(false);
#endif
            
            // Play popup sound after ResetDecoder (in EnableVoiceProcessing) has been called
            if (play_popup_on_listening_) {
                play_popup_on_listening_ = false;
                audio_service_.PlaySound(Lang::Sounds::OGG_POPUP);
            }
            break;
        case kDeviceStateSpeaking:
#ifndef CONFIG_ADHD_KIDS_UI
            display->SetStatus(Lang::Strings::SPEAKING);
#endif

            if (listening_mode_ != kListeningModeRealtime) {
                audio_service_.EnableVoiceProcessing(false);
                // Only AFE wake word can be detected in speaking mode
                audio_service_.EnableWakeWordDetection(audio_service_.IsAfeWakeWord());
            }
            // Downlink Opus can be queued while still Listening (WS thread vs Schedule delay
            // before Speaking). Clearing here would drop the entire TTS → only UI sounds.
            if (last_state_transition_from_ != kDeviceStateListening) {
                audio_service_.ResetDecoder();
            } else {
                ESP_LOGI(TAG, "Speaking after Listening: skip ResetDecoder (preserve TTS queue)");
            }
            break;
        case kDeviceStateWifiConfiguring:
            audio_service_.EnableVoiceProcessing(false);
            audio_service_.EnableWakeWordDetection(false);
            break;
        default:
            // Do nothing
            break;
    }

#ifdef CONFIG_ADHD_KIDS_UI
    if (new_state == kDeviceStateUnknown || new_state == kDeviceStateIdle) {
        display->ClearChatMessages();
    }
    RefreshKidsDisplay();
#endif
}

void Application::Schedule(std::function<void()>&& callback) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        main_tasks_.push_back(std::move(callback));
    }
    xEventGroupSetBits(event_group_, MAIN_EVENT_SCHEDULE);
}

bool Application::IsSessionStopCommand(const std::string& text) const {
    // 只保留唯一休眠口令。不要把"休息"这类泛词当成停止，否则
    // "我想休息一下再写作业"会误触发。
    std::string normalized = text;
    const char* puncts[] = {" ", "\t", "\r", "\n", "。", "，", "！", "？", "!", "?", ",", ".", "～", "~"};
    for (const auto* p : puncts) {
        size_t pos = 0;
        while ((pos = normalized.find(p, pos)) != std::string::npos) {
            normalized.erase(pos, strlen(p));
        }
    }
    return normalized == "休息吧小星星";
}

void Application::TerminateCurrentSession(const char* reason, bool notify_server) {
    ESP_LOGI(TAG, "Terminate session: %s", reason ? reason : "");
    session_termination_requested_ = true;
    auto_stop_voice_seen_ = false;
    auto_stop_silence_started_ms_ = 0;
    auto_stop_voice_quiet_before_ms_ = 0;
    auto_stop_endpoint_delay_ms_ = kAutoStopBaseSilenceMs;
    auto_stop_endpoint_timer_armed_ = false;
    auto_stop_short_speech_total_ms_ = 0;
    auto_stop_short_speech_count_ = 0;
    if (endpoint_timer_handle_ != nullptr) {
        esp_timer_stop(endpoint_timer_handle_);
    }
    audio_service_.EnableVoiceProcessing(false);
    audio_service_.ClearSendQueue();
    if (protocol_) {
        if (notify_server && protocol_->IsAudioChannelOpened()) {
            protocol_->SendAbortSpeaking(kAbortReasonNone);
        }
        protocol_->CloseAudioChannel();
    }
    SetDeviceState(kDeviceStateIdle);
}

void Application::EnterSleepPowerSaveMode(const char* reason, bool notify_server) {
    ESP_LOGI(TAG, "Enter sleep power-save mode: %s", reason ? reason : "");
    RestoreApplicationSleepDisplay();
    sleep_power_save_mode_ = true;
    auto& board = Board::GetInstance();
    auto display = board.GetDisplay();
    display->SetStatus("休眠省电中");
    display->SetChatMessage("system", "休眠省电中");
    TerminateCurrentSession(reason, notify_server);
    // 关会话会触发 OnAudioChannelClosed；上面已让休眠态下保持 PERFORMANCE。
    // 若通道本就未打开，这里再显式拉高档位，避免仍停留在 LOW_POWER。
    board.SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);
#ifdef CONFIG_ADHD_KIDS_UI
    RefreshKidsDisplay();
#endif
    if (sleep_display_off_timer_ != nullptr) {
        esp_timer_stop(sleep_display_off_timer_);
        esp_err_t err = esp_timer_start_once(sleep_display_off_timer_, kAppSleepDisplayOffAfterUs);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "sleep display off timer start: %s", esp_err_to_name(err));
        }
    }
}

void Application::ExitSleepPowerSaveForAlarm(const char* reason) {
    if (!sleep_power_save_mode_) {
        return;
    }
    ESP_LOGI(TAG, "Exit sleep power-save for alarm: %s", reason ? reason : "");
    sleep_power_save_mode_ = false;
    RestoreApplicationSleepDisplay();
    Board::GetInstance().SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);
#ifdef CONFIG_ADHD_KIDS_UI
    RefreshKidsDisplay();
#endif
}

void Application::RestoreApplicationSleepDisplay() {
    if (sleep_display_off_timer_ != nullptr) {
        esp_timer_stop(sleep_display_off_timer_);
    }
    Board::GetInstance().SetApplicationSleepDisplayDimmed(false);
}

void Application::OnSleepDisplayOffTimer() {
    if (!sleep_power_save_mode_) {
        return;
    }
    if (GetDeviceState() != kDeviceStateIdle) {
        return;
    }
    ESP_LOGI(TAG, "App sleep power-save: dimming display after 30s idle in sleep mode");
    Board::GetInstance().SetApplicationSleepDisplayDimmed(true);
}

void Application::OnEndpointTimer() {
    // Endpoint timer fired after the adaptive silence window.
    // We re-check the world from the main task because state may have changed
    // in the meantime (user resumed speaking, server replied, channel closed).
    auto_stop_endpoint_timer_armed_ = false;
    if (GetDeviceState() != kDeviceStateListening ||
        listening_mode_ != kListeningModeAutoStop || !protocol_) {
        ESP_LOGI(TAG, "Endpoint timer: skip (state changed)");
        return;
    }
    if (!auto_stop_voice_seen_ || auto_stop_silence_started_ms_ == 0) {
        // Voice came back during the timer window — don't stop.
        ESP_LOGI(TAG, "Endpoint timer: skip (voice resumed)");
        return;
    }
    const int64_t now_ms = esp_timer_get_time() / 1000;
    const int64_t silence_ms = now_ms - auto_stop_silence_started_ms_;
    const int64_t speech_ms = auto_stop_silence_started_ms_ - auto_stop_voice_started_ms_;
    const int64_t listening_ms = now_ms - auto_stop_listen_started_ms_;
    const int64_t required_speech_ms =
        AutoStopRequiredSpeechMs(auto_stop_voice_quiet_before_ms_);
    const int64_t required_silence_ms = auto_stop_endpoint_delay_ms_ > 0
        ? auto_stop_endpoint_delay_ms_
        : kAutoStopBaseSilenceMs;
    if (speech_ms < kAutoStopEarlySpeechMs &&
        listening_ms < kAutoStopAllowShortSpeechAfterMs) {
        auto_stop_short_speech_total_ms_ += speech_ms > 0 ? speech_ms : 0;
        auto_stop_short_speech_count_++;
        if (listening_ms >= kAutoStopForceShortFragmentsAfterMs &&
            auto_stop_short_speech_total_ms_ >= kAutoStopForceShortFragmentsSpeechMs &&
            protocol_->IsAudioChannelOpened()) {
            ESP_LOGI(TAG, "Auto-stop (short fragments): count=%d total=%lldms listen=%lldms",
                     auto_stop_short_speech_count_, auto_stop_short_speech_total_ms_,
                     listening_ms);
            auto_stop_voice_seen_ = false;
            auto_stop_silence_started_ms_ = 0;
            auto_stop_voice_quiet_before_ms_ = 0;
            auto_stop_short_speech_total_ms_ = 0;
            auto_stop_short_speech_count_ = 0;
            protocol_->SendStopListening();
            SetDeviceState(kDeviceStateIdle);
            return;
        }
        ESP_LOGI(TAG, "Endpoint timer: ignore short early speech (speech=%lld listen=%lld)",
                 speech_ms, listening_ms);
        auto_stop_voice_seen_ = false;
        auto_stop_silence_started_ms_ = 0;
        auto_stop_voice_quiet_before_ms_ = 0;
        return;
    }
    if (silence_ms < required_silence_ms ||
        speech_ms < required_speech_ms ||
        listening_ms < kAutoStopMinListenMs) {
        auto_stop_short_speech_total_ms_ += speech_ms > 0 ? speech_ms : 0;
        auto_stop_short_speech_count_++;
        if (listening_ms >= kAutoStopForceShortFragmentsAfterMs &&
            auto_stop_short_speech_total_ms_ >= kAutoStopForceShortFragmentsSpeechMs &&
            protocol_->IsAudioChannelOpened()) {
            ESP_LOGI(TAG, "Auto-stop (short fragments): count=%d total=%lldms listen=%lldms",
                     auto_stop_short_speech_count_, auto_stop_short_speech_total_ms_,
                     listening_ms);
            auto_stop_voice_seen_ = false;
            auto_stop_silence_started_ms_ = 0;
            auto_stop_voice_quiet_before_ms_ = 0;
            auto_stop_short_speech_total_ms_ = 0;
            auto_stop_short_speech_count_ = 0;
            protocol_->SendStopListening();
            SetDeviceState(kDeviceStateIdle);
            return;
        }
        ESP_LOGI(TAG, "Endpoint timer: skip (silence=%lld/%lld speech=%lld/%lld listen=%lld quiet_before=%lld)",
                 silence_ms, required_silence_ms, speech_ms, required_speech_ms,
                 listening_ms, auto_stop_voice_quiet_before_ms_);
        auto_stop_voice_seen_ = false;
        auto_stop_silence_started_ms_ = 0;
        auto_stop_voice_quiet_before_ms_ = 0;
        return;
    }
    ESP_LOGI(TAG, "Auto-stop (one-shot): silence=%lldms speech=%lldms quiet_before=%lldms",
             silence_ms, speech_ms, auto_stop_voice_quiet_before_ms_);
    auto_stop_voice_seen_ = false;
    auto_stop_silence_started_ms_ = 0;
    auto_stop_voice_quiet_before_ms_ = 0;
    auto_stop_short_speech_total_ms_ = 0;
    auto_stop_short_speech_count_ = 0;
    protocol_->SendStopListening();
    SetDeviceState(kDeviceStateIdle);
}

void Application::AbortSpeaking(AbortReason reason) {
    ESP_LOGI(TAG, "Abort speaking");
    aborted_ = true;
    if (protocol_) {
        protocol_->SendAbortSpeaking(reason);
    }
}

void Application::SetListeningMode(ListeningMode mode) {
    listening_mode_ = mode;
    SetDeviceState(kDeviceStateListening);
}

ListeningMode Application::GetDefaultListeningMode() const {
    return aec_mode_ == kAecOff ? kListeningModeAutoStop : kListeningModeRealtime;
}

void Application::Reboot() {
    ESP_LOGI(TAG, "Rebooting...");
    // Disconnect the audio channel
    if (protocol_ && protocol_->IsAudioChannelOpened()) {
        protocol_->CloseAudioChannel();
    }
    protocol_.reset();
    audio_service_.Stop();

    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
}

void Application::WakeWordInvoke(const std::string& wake_word) {
    if (!protocol_) {
        return;
    }

    auto state = GetDeviceState();
    
    if (state == kDeviceStateIdle) {
        audio_service_.EncodeWakeWord();

        if (!protocol_->IsAudioChannelOpened()) {
            SetDeviceState(kDeviceStateConnecting);
            // Schedule to let the state change be processed first (UI update)
            Schedule([this, wake_word]() {
                ContinueWakeWordInvoke(wake_word);
            });
            return;
        }
        // Channel already opened, continue directly
        ContinueWakeWordInvoke(wake_word);
    } else if (state == kDeviceStateSpeaking) {
        Schedule([this]() {
            AbortSpeaking(kAbortReasonNone);
        });
    } else if (state == kDeviceStateListening) {   
        Schedule([this]() {
            if (protocol_) {
                protocol_->CloseAudioChannel();
            }
        });
    }
}

void Application::SetVisualChoiceMode(bool enabled) {
    Schedule([this, enabled]() {
        visual_choice_mode_ = enabled;
        if (enabled) {
            audio_service_.EnableVoiceProcessing(false);
            audio_service_.EnableWakeWordDetection(false);
        } else if (GetDeviceState() == kDeviceStateListening) {
            audio_service_.EnableVoiceProcessing(true);
            audio_service_.EnableWakeWordDetection(false);
        }
        ESP_LOGI(TAG, "Visual choice mode: %s", enabled ? "on" : "off");
    });
}

void Application::SubmitChildTextInput(const std::string& text) {
    if (!protocol_ || text.empty()) {
        return;
    }

    Schedule([this, text]() {
        if (!protocol_) {
            return;
        }
        auto state = GetDeviceState();
        const ListeningMode submit_mode = visual_choice_mode_ ? kListeningModeManualStop : GetDefaultListeningMode();
        if (!protocol_->IsAudioChannelOpened()) {
            SetDeviceState(kDeviceStateConnecting);
            Schedule([this, text, submit_mode]() {
                if (!protocol_ || GetDeviceState() != kDeviceStateConnecting) {
                    return;
                }
                if (!protocol_->IsAudioChannelOpened() && !protocol_->OpenAudioChannel()) {
                    SetDeviceState(kDeviceStateIdle);
                    return;
                }
                protocol_->SendStartListening(submit_mode);
                protocol_->SendWakeWordDetected(text);
                SetListeningMode(submit_mode);
            });
            return;
        }
        if (state == kDeviceStateSpeaking) {
            AbortSpeaking(kAbortReasonNone);
        }
        protocol_->SendStartListening(submit_mode);
        protocol_->SendWakeWordDetected(text);
        if (visual_choice_mode_) {
            SetListeningMode(submit_mode);
        }
    });
}

bool Application::CanEnterSleepMode() {
    // 孤独症选图 / 计划表全屏选图（含 60s 仅关屏黑屏等待）期间：不让板级 PowerSaveTimer
    // 累计进入「省电睡眠」回调，避免与选图关屏逻辑竞态，且保持与 Path A 一致——
    // 选图黑屏只灭背光/面板，不走 Application 休眠省电、不断 WiFi、不深睡。
    if (visual_choice_mode_) {
        return false;
    }

    if (GetDeviceState() != kDeviceStateIdle) {
        return false;
    }

    if (protocol_ && protocol_->IsAudioChannelOpened()) {
        return false;
    }

    if (!audio_service_.IsIdle()) {
        return false;
    }

    // Now it is safe to enter sleep mode
    return true;
}

void Application::SendMcpMessage(const std::string& payload) {
    // Always schedule to run in main task for thread safety
    Schedule([this, payload = std::move(payload)]() {
        if (protocol_) {
            protocol_->SendMcpMessage(payload);
        }
    });
}

void Application::SetAecMode(AecMode mode) {
    aec_mode_ = mode;
    Schedule([this]() {
        auto& board = Board::GetInstance();
        auto display = board.GetDisplay();
        switch (aec_mode_) {
        case kAecOff:
            audio_service_.EnableDeviceAec(false);
            display->ShowNotification(Lang::Strings::RTC_MODE_OFF);
            break;
        case kAecOnServerSide:
            audio_service_.EnableDeviceAec(false);
            display->ShowNotification(Lang::Strings::RTC_MODE_ON);
            break;
        case kAecOnDeviceSide:
            audio_service_.EnableDeviceAec(true);
            display->ShowNotification(Lang::Strings::RTC_MODE_ON);
            break;
        }

        // If the AEC mode is changed, close the audio channel
        if (protocol_ && protocol_->IsAudioChannelOpened()) {
            protocol_->CloseAudioChannel();
        }
    });
}

void Application::PlaySound(const std::string_view& sound) {
    audio_service_.PlaySound(sound);
}

bool Application::TryConsumePowerOnWelcomeBootClick() {
#if HAVE_LVGL
    int expected = 1;
    if (!g_power_welcome_shake_gate.compare_exchange_strong(expected, 2)) {
        return false;
    }
    if (xTaskCreate(PowerOnWelcomePostBootTask, "pwr_wel_post", 6144, nullptr, 3, nullptr) != pdPASS) {
        g_power_welcome_shake_gate.store(1);
        return false;
    }
    return true;
#else
    return false;
#endif
}

bool Application::PowerOnWelcomeShakeBlocked() const {
#if HAVE_LVGL
    const int g = g_power_welcome_shake_gate.load();
    return g == 1 || g == 2;
#else
    return false;
#endif
}

void Application::ResetProtocol() {
    Schedule([this]() {
        // Close audio channel if opened
        if (protocol_ && protocol_->IsAudioChannelOpened()) {
            protocol_->CloseAudioChannel();
        }
        // Reset protocol
        protocol_.reset();
    });
}

