#include "pch.h"
#include "Controller.h"
#include "AutoStart.h"
#include "Diagnostics.h"
#include "DdcBackends.h"
#include "SettingsWindow.xaml.h"
#include "SystemActions.h"
#include "TrayIcon.h"
#include "UsbWatcher.h"

using namespace winrt;

namespace
{
    int64_t NowMilliseconds()
    {
        return static_cast<int64_t>(std::llround(::DisplaySwitcher::Native::UdpPeer::TimestampNow() * 1000.0));
    }

}

namespace DisplaySwitcher::Native
{
    std::shared_ptr<Controller> Controller::Create(Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher,
        std::function<void()> exitApplication)
    {
        auto controller = std::shared_ptr<Controller>(new Controller(dispatcher, std::move(exitApplication)));
        controller->Initialize();
        return controller;
    }

    Controller::Controller(Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher, std::function<void()> exitApplication) :
        dispatcher_(dispatcher), exitApplication_(std::move(exitApplication)), config_(AppConfig::Load())
    {
    }

    void Controller::Initialize()
    {
        ResetDiagnosticLog();
        std::weak_ptr<Controller> weak = shared_from_this();
        usbWatcher_ = std::make_unique<UsbWatcher>(-1, -1, [weak](bool present)
        {
            if (auto self = weak.lock()) self->Enqueue([weak, present] { if (auto value = weak.lock()) value->OnUsbPresenceChanged(present); });
        });
        peer_ = std::make_unique<UdpPeer>([weak](PeerMessage const& message)
        {
            if (auto self = weak.lock()) self->Enqueue([weak, message] { if (auto value = weak.lock()) value->HandlePeerMessage(message); });
        }, [weak](std::wstring const& error)
        {
            if (auto self = weak.lock())
            {
                self->SetStatus(error);
                self->SetPeerConnectionStatus(L"连接错误：" + error, false);
            }
        });
        trayIcon_ = std::make_unique<TrayIcon>(
            [weak] { if (auto self = weak.lock()) self->ShowSettings(); },
            [weak](std::wstring const& profileId) { if (auto self = weak.lock()) self->ManualSwitch(profileId); },
            [weak] { if (auto self = weak.lock()) { auto exit = self->exitApplication_; if (exit) exit(); } });
        ApplyConfiguration();
    }

    Controller::~Controller() { Dispose(); }

    AppConfig Controller::Config() const
    {
        std::scoped_lock lock(configMutex_);
        return config_;
    }

    void Controller::ApplyConfiguration(bool applyAutoStart)
    {
        auto config = Config();
        if (config.displayConfigurationSafeMode) sideEffectGate_.Block();
        else sideEffectGate_.Allow();
        std::vector<std::pair<std::wstring, std::wstring>> menuProfiles;
        for (auto const& profile : config.EnabledCompleteProfiles()) menuProfiles.emplace_back(profile.id, profile.name);
        trayIcon_->SetProfiles(std::move(menuProfiles));
        StopPeerHealthCheck();
        peer_->Stop();
        auto usbConfigured = config.HasUsbDeviceConfiguration();
        auto displayConfigured = config.HasDisplayConfiguration();
        auto automationConfigured = usbConfigured && displayConfigured;
        usbWatcher_->Reconfigure(config.usbAutomationEnabled && automationConfigured ? config.usbVendorId : -1,
            config.usbAutomationEnabled && automationConfigured ? config.usbProductId : -1);
        auto coordinationConfigured = automationConfigured && !config.peerHost.empty() &&
            config.port >= 1 && config.port <= 65535 && config.pairingCode.size() >= 8;
        StateMachineInitialState initial{
            .localPlatform = L"windows",
            .coordinationEnabled = config.usbAutomationEnabled && config.coordinationEnabled && coordinationConfigured,
            .usbAutomationEnabled = config.usbAutomationEnabled && automationConfigured,
            .usbPresent = usbWatcher_->IsPresent(),
        };
        stateMachine_ = std::make_unique<HandoverStateMachine>(StateMachineConfig{
            L"windows", config.pairingCode, initial.coordinationEnabled, initial.usbAutomationEnabled, 0.0, {}
        }, initial, [] { return Controller::NewEventId(); });
        if (config.usbAutomationEnabled && config.coordinationEnabled && coordinationConfigured)
        {
            peer_->Start(config.port);
        }
        else SetPeerConnectionStatus(config.coordinationEnabled ? L"协同配置不完整" : L"协同未启用", false);
        if (initial.usbAutomationEnabled) StartPeerHealthCheck();
        if (applyAutoStart)
        {
            try { ApplyAutoStart(config.startWithWindows); }
            catch (hresult_error const& error) { ShowError(L"登录启动设置失败", error.message().c_str()); }
        }
        if (config.usbAutomationEnabled && !usbConfigured) SetStatus(L"USB 自动切换未配置");
        else if (config.usbAutomationEnabled && !displayConfigured) SetStatus(L"显示器切换未配置");
        else if (!config.usbAutomationEnabled) SetStatus(L"USB 自动切换未开启");
        else
        {
            wchar_t ids[16]{}; swprintf_s(ids, L"%04X:%04X", config.usbVendorId, config.usbProductId);
            if (config.coordinationEnabled && coordinationConfigured) SetStatus(L"协同已开启 · USB " + std::wstring(ids));
            else SetStatus(L"USB 自动切换已开启 · USB " + std::wstring(ids));
        }
    }

    void Controller::EnterSafeStateAfterSaveFailure()
    {
        // Close the gate before stopping components so already queued callbacks and
        // detached hardware work cannot race the transition into the safe state.
        ++sideEffectGeneration_;
        sideEffectGate_.Block();
        auto safe = Config();
        safe.EnterSafeState();
        {
            std::scoped_lock lock(configMutex_);
            config_ = std::move(safe);
        }
        ApplyConfiguration(false);
    }

    void Controller::BeginUsbLearning()
    {
        if (usbLearningActive_.exchange(true)) return;
        ++sideEffectGeneration_;
        sideEffectGate_.Block();
        StopPeerHealthCheck();
        peer_->Stop();
        usbWatcher_->Reconfigure(-1, -1);
        stateMachine_.reset();
        SetPeerConnectionStatus(L"USB 学习中，协同已暂停", false);
        SetStatus(L"正在学习 USB 设备；自动协同和硬件操作已暂停");
    }

    void Controller::EndUsbLearning()
    {
        if (!usbLearningActive_.exchange(false)) return;
        ApplyConfiguration(false);
    }

    bool Controller::AllowsSideEffects(uint64_t generation) const noexcept
    {
        return sideEffectGate_.AllowsSideEffects() && sideEffectGeneration_.load() == generation;
    }

    void Controller::OnUsbPresenceChanged(bool present)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        WriteDiagnostic(present ? "controller.usb_presence present=1" : "controller.usb_presence present=0");
        if (!stateMachine_) return;
        SetStatus(present ? L"USB 已接入 Windows" : L"USB 已离开 Windows，等待确认…");
        ApplyStateMachineActions(stateMachine_->OnUsbPresenceChanged(NowMilliseconds(), present));
    }

    void Controller::ApplyStateMachineActions(std::vector<StateMachineAction> actions)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        for (auto const& action : actions)
        {
            switch (action.kind)
            {
            case StateMachineAction::Kind::AcceptMessage:
                if (action.type != L"status_probe" && action.type != L"status_response")
                    WriteDiagnostic("state_machine.message accepted=1");
                break;
            case StateMachineAction::Kind::RejectMessage:
                WriteDiagnostic("state_machine.message rejected=1");
                break;
            case StateMachineAction::Kind::SendMessage:
                Send(action.type, action.eventId,
                    action.type == L"committed" ? std::optional<bool>{ action.wakeSucceeded } : std::nullopt);
                break;
            case StateMachineAction::Kind::SendBurst:
                SendRepeated(action.type, action.eventId, action.wakeSucceeded);
                break;
            case StateMachineAction::Kind::RequestWake:
            {
                auto eventId = action.eventId;
                auto generation = sideEffectGeneration_.load();
                std::weak_ptr<Controller> weak = shared_from_this();
                std::thread([weak, eventId, generation]
                {
                    auto controller = weak.lock();
                    if (!controller || controller->disposed_ || !controller->AllowsSideEffects(generation)) return;
                    auto success = WakeDisplay();
                    if (auto self = weak.lock(); self && !self->disposed_)
                        self->Enqueue([weak, eventId, success, generation]
                        {
                            if (auto value = weak.lock(); value && value->stateMachine_ && value->AllowsSideEffects(generation))
                                value->ApplyStateMachineActions(value->stateMachine_->OnWakeCompleted(NowMilliseconds(), eventId, success));
                        });
                }).detach();
                break;
            }
            case StateMachineAction::Kind::RequestSwitch:
                SwitchToMac(action.eventId.empty() ? std::nullopt : std::optional<std::wstring>{ action.eventId }, false);
                break;
            case StateMachineAction::Kind::SetPeerReachable:
                SetPeerConnectionStatus(action.value ? L"已连接到对端" : L"连接已中断", action.value);
                break;
            case StateMachineAction::Kind::CancelOutgoing:
                WriteDiagnostic("state_machine.outgoing canceled=1");
                break;
            }
        }
    }

    void Controller::AdvanceStateMachine()
    {
        if (sideEffectGate_.AllowsSideEffects() && stateMachine_)
            ApplyStateMachineActions(stateMachine_->Advance(NowMilliseconds()));
    }

    void Controller::SwitchToMac(std::optional<std::wstring> eventId, bool manual)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        if (!config.HasDisplayConfiguration())
        {
            WriteDiagnostic("display.switch_blocked configuration_missing=1");
            SetStatus(L"显示器尚未配置，未执行切换");
            if (manual) ShowError(L"无法切换显示器", L"请先在设置的“显示器”页完成配置。");
            return;
        }
        WriteDiagnostic(manual ? "display.switch_begin manual=1" : "display.switch_begin manual=0");
        SetStatus(manual ? L"正在手动切换显示器到对端…" : L"正在切换显示器到对端…");
        auto generation = sideEffectGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, config, eventId, manual, generation]
        {
            auto controller = weak.lock();
            if (!controller || controller->disposed_ || !controller->AllowsSideEffects(generation)) return;
            auto result = SwitchDisplaysToMac(config);
            if (auto self = weak.lock(); self && !self->disposed_)
            {
                self->Enqueue([weak, result, manual, eventId, generation]
                {
                    if (auto value = weak.lock(); value && value->AllowsSideEffects(generation))
                    {
                        if (eventId && value->stateMachine_)
                            value->ApplyStateMachineActions(value->stateMachine_->OnSwitchCompleted(NowMilliseconds(), *eventId, result.success));
                        std::wstring success = manual ? L"已手动切换到对端" : L"已切换到对端";
                        std::wstring failure = manual ? L"切换失败：" : L"部分切换失败：";
                        value->SetStatus(result.success ? success : failure + result.error);
                        if (!result.success) value->ShowError(L"显示器切换失败", result.error.empty() ? L"未知错误" : result.error);
                    }
                });
            }
        }).detach();
    }

    void Controller::StartPeerHealthCheck()
    {
        StopPeerHealthCheck();
        if (!sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        if (config.coordinationEnabled) SetPeerConnectionStatus(L"正在连接对端…", false);
        std::weak_ptr<Controller> weak = shared_from_this();
        peerHealthThread_ = std::jthread([weak](std::stop_token token)
        {
            int elapsedSinceProbe = 2000;
            while (!token.stop_requested())
            {
                auto self = weak.lock();
                if (!self || self->disposed_) return;
                self->Enqueue([weak] { if (auto value = weak.lock()) value->AdvanceStateMachine(); });
                if (elapsedSinceProbe >= 2000 && self->Config().coordinationEnabled)
                {
                    self->Send(L"status_probe", self->NewEventId(), std::nullopt);
                    elapsedSinceProbe = 0;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
                elapsedSinceProbe += 25;
            }
        });
    }

    void Controller::StopPeerHealthCheck()
    {
        peerHealthThread_.request_stop();
        if (peerHealthThread_.joinable()) peerHealthThread_.join();
    }

    void Controller::HandlePeerMessage(PeerMessage const& message)
    {
        if (!sideEffectGate_.AllowsSideEffects() || !stateMachine_) return;
        ApplyStateMachineActions(stateMachine_->OnPeerMessage(NowMilliseconds(), message));
    }

    void Controller::Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded)
    {
        if (disposed_ || !peer_ || !sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        if (!config.coordinationEnabled || config.pairingCode.size() < 8) return;
        peer_->Send(PeerMessage{ 1, type, eventId, L"windows", L"mac", UdpPeer::TimestampNow(), config.pairingCode, wakeSucceeded },
            config.peerHost, config.port);
    }

    void Controller::SendRepeated(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded)
    {
        Send(type, eventId, wakeSucceeded);
        auto generation = sideEffectGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, type, eventId, wakeSucceeded, generation]
        {
            for (int attempt = 1; attempt < 3; ++attempt)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(120));
                if (auto self = weak.lock(); self && !self->disposed_ && self->AllowsSideEffects(generation))
                    self->Send(type, eventId, wakeSucceeded);
                else return;
            }
        }).detach();
    }

    void Controller::SwitchToProfile(std::wstring const& profileId)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        auto profile = config.FindCollaborationProfile(profileId);
        if (!profile || !profile->coordinationEnabled)
        {
            SetStatus(L"协同配置不可用"); return;
        }
        auto selection = config.SelectProfileDisplays(profileId);
        if (selection.mappedDisplays.empty())
        {
            SetStatus(L"该配置没有可用的显示器映射"); return;
        }
        auto actionConfig = config; actionConfig.displays = selection.mappedDisplays;
        auto name = profile->name; auto missing = selection.missingDisplayIds.size();
        SetStatus(L"正在切换到 " + name + L"…");
        auto generation = sideEffectGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, actionConfig, name, missing, generation]
        {
            auto controller = weak.lock();
            if (!controller || controller->disposed_ || !controller->AllowsSideEffects(generation)) return;
            auto result = SwitchDisplaysToMac(actionConfig);
            if (auto self = weak.lock(); self && !self->disposed_)
                self->Enqueue([weak, result, name, missing, generation]
                {
                    if (auto value = weak.lock(); value && value->AllowsSideEffects(generation))
                    {
                        auto text = result.success ? L"已切换到 " + name : L"切换到 " + name + L" 失败：" + result.error;
                        if (missing) text += L"；有 " + std::to_wstring(missing) + L" 台显示器缺少映射";
                        value->SetStatus(text);
                        if (!result.success) value->ShowError(L"显示器切换失败", result.error.empty() ? L"未知错误" : result.error);
                    }
                });
        }).detach();
    }

    void Controller::ManualSwitch(std::wstring const& profileId)
    {
        // DS-004 only selects the requested local profile mapping. It does not send a
        // v1 handover_request to emulate the DS-005 manual coordination intent.
        SwitchToProfile(profileId);
    }

    void Controller::ShowSettings()
    {
        if (settingsWindow_)
        {
            auto projected = settingsWindow_.as<::winrt::DisplaySwitcher::Native::SettingsWindow>();
            get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->ShowWindow();
            return;
        }
        auto projected = make<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>();
        settingsWindow_ = projected;
        std::weak_ptr<Controller> weak = shared_from_this();
        get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->Initialize(Config(),
            [weak](AppConfig const& config) -> bool
            {
                if (auto self = weak.lock())
                {
                    try { config.Save(); }
                    catch (...)
                    {
                        self->EnterSafeStateAfterSaveFailure();
                        self->ShowError(L"保存设置失败", L"无法写入设置文件；自动协同和硬件操作已安全停用。");
                        return false;
                    }
                    { std::scoped_lock lock(self->configMutex_); self->config_ = config; }
                    self->ApplyConfiguration();
                    return true;
                }
                return false;
            },
            [weak](AppConfig& config, std::vector<std::wstring> const& displayIds,
                DdcCancellationToken const& cancellation)
            {
                if (auto self = weak.lock())
                {
                    DdcBackendSet backends(config);
                    DdcControlService service([&](std::wstring const& key) { return backends.Lookup(key); },
                        [weak] { if (auto value = weak.lock()) return value->sideEffectGate_.AllowsSideEffects(); return false; });
                    return service.Read(config, displayIds, cancellation);
                }
                DdcControlBatchResult result; result.canceled = true; return result;
            },
            [weak](AppConfig& config, std::wstring const& displayId, DdcVcpCode code, int value,
                bool linkAllDisplays, DdcCancellationToken const& cancellation)
            {
                if (auto self = weak.lock())
                {
                    DdcBackendSet backends(config);
                    DdcControlService service([&](std::wstring const& key) { return backends.Lookup(key); },
                        [weak] { if (auto current = weak.lock()) return current->sideEffectGate_.AllowsSideEffects(); return false; });
                    return service.Write(config, displayId, code, value, linkAllDisplays, cancellation);
                }
                DdcControlBatchResult result; result.canceled = true; return result;
            },
            [weak](std::vector<DisplayConfig> const& displays)
            {
                auto self = weak.lock(); if (!self || !self->sideEffectGate_.AllowsSideEffects()) return false;
                auto config = self->Config();
                for (auto const& source : displays)
                {
                    auto target = FindDisplayById(config.displays, source.id); if (!target) continue;
                    auto& destination = config.displays[*target];
                    destination.brightnessValue = source.brightnessValue; destination.brightnessMax = source.brightnessMax;
                    destination.contrastValue = source.contrastValue; destination.contrastMax = source.contrastMax;
                    destination.volumeValue = source.volumeValue; destination.volumeMax = source.volumeMax;
                }
                try { config.Save(); }
                catch (...)
                {
                    self->EnterSafeStateAfterSaveFailure();
                    self->ShowError(L"保存 DDC 缓存失败", L"无法安全保存 DDC 估计值；自动协同和硬件操作已停用。");
                    return false;
                }
                { std::scoped_lock lock(self->configMutex_); self->config_ = std::move(config); }
                return true;
            },
            [weak] { if (auto self = weak.lock()) self->BeginUsbLearning(); },
            [weak] { if (auto self = weak.lock()) self->EndUsbLearning(); },
            [weak] { if (auto self = weak.lock()) self->settingsWindow_ = nullptr; });
        {
            std::scoped_lock lock(stateMutex_);
            get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->SetConnectionStatus(
                peerConnectionStatus_, peerConnected_);
        }
        get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->ShowWindow();
    }

    void Controller::SetStatus(std::wstring const& text)
    {
        if (disposed_) return;
        if (dispatcher_.HasThreadAccess()) trayIcon_->SetStatus(text);
        else Enqueue([weak = weak_from_this(), text]
        {
            if (auto self = weak.lock(); self && !self->disposed_ && self->trayIcon_) self->trayIcon_->SetStatus(text);
        });
    }

    void Controller::SetPeerConnectionStatus(std::wstring const& text, bool connected)
    {
        if (disposed_) return;
        if (!dispatcher_.HasThreadAccess())
        {
            Enqueue([weak = weak_from_this(), text, connected]
            {
                if (auto self = weak.lock()) self->SetPeerConnectionStatus(text, connected);
            });
            return;
        }
        {
            std::scoped_lock lock(stateMutex_);
            peerConnectionStatus_ = text;
            peerConnected_ = connected;
        }
        if (settingsWindow_)
        {
            auto projected = settingsWindow_.as<::winrt::DisplaySwitcher::Native::SettingsWindow>();
            get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->SetConnectionStatus(text, connected);
        }
    }

    void Controller::ShowError(std::wstring const& title, std::wstring const& message)
    {
        if (disposed_) return;
        if (dispatcher_.HasThreadAccess()) trayIcon_->ShowBalloon(title, message);
        else Enqueue([weak = weak_from_this(), title, message]
        {
            if (auto self = weak.lock(); self && !self->disposed_ && self->trayIcon_) self->trayIcon_->ShowBalloon(title, message);
        });
    }

    void Controller::Enqueue(std::function<void()> action)
    {
        if (!disposed_) dispatcher_.TryEnqueue([action = std::move(action)] { action(); });
    }

    std::wstring Controller::NewEventId()
    {
        GUID guid{}; check_hresult(CoCreateGuid(&guid)); wchar_t value[40]{}; StringFromGUID2(guid, value, ARRAYSIZE(value));
        std::wstring result(value); if (!result.empty() && result.front() == L'{') result = result.substr(1, result.size() - 2);
        std::transform(result.begin(), result.end(), result.begin(), ::towlower); return result;
    }

    void Controller::Dispose()
    {
        if (disposed_.exchange(true)) return;
        StopPeerHealthCheck();
        if (peer_) peer_->Stop();
        if (settingsWindow_)
        {
            auto projected = settingsWindow_.as<::winrt::DisplaySwitcher::Native::SettingsWindow>();
            get_self<::winrt::DisplaySwitcher::Native::implementation::SettingsWindow>(projected)->CloseForExit();
            settingsWindow_ = nullptr;
        }
        // Detached handover work holds a shared Controller reference. Keep the stopped
        // peer and watcher alive until that work releases the Controller, avoiding a
        // use-after-free during application shutdown.
        trayIcon_.reset();
    }
}
