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

    bool EqualId(std::wstring const& left, std::wstring const& right)
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
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
        dispatcher_(dispatcher), exitApplication_(std::move(exitApplication)), config_(AppConfig::Load(&firstRun_))
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
        peer_ = std::make_unique<UdpPeer>([weak](UdpPeer::Datagram const& datagram)
        {
            if (auto self = weak.lock()) self->Enqueue([weak, datagram] { if (auto value = weak.lock()) value->HandleDatagram(datagram); });
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
            [weak](std::wstring const& displayId, DdcVcpCode code, int value)
            { if (auto self = weak.lock()) self->WriteTrayDdc(displayId, code, value); },
            [weak] { if (auto self = weak.lock()) { auto exit = self->exitApplication_; if (exit) exit(); } });
        ApplyConfiguration();
        if (firstRun_) ShowSettings();
    }

    Controller::~Controller() { Dispose(); }

    AppConfig Controller::Config() const
    {
        std::scoped_lock lock(configMutex_);
        return config_;
    }

    void Controller::ApplyConfiguration(bool applyAutoStart)
    {
        ++configurationGeneration_;
        v2KeyCache_.Clear();
        ++sideEffectGeneration_;
        sideEffectGate_.Block();
        trayDdcWrites_.CancelPending();
        auto config = Config();
        if (!config.displayConfigurationSafeMode)
        {
            try
            {
                auto enumeration = EnumerateDdcMonitors();
                if (enumeration.IsTrustedNonEmptySnapshot())
                {
                    auto reconciled = ReconcileDisplayConfigurations(config.displays, enumeration.monitors, true);
                    config.displays = std::move(reconciled.displays);
                    auto mappingsChanged = RemoveOrphanedDisplayMappings(
                        config.displays, config.collaborationProfiles, config.usbSwitch);
                    if (reconciled.changed || mappingsChanged)
                    {
                        config.Save();
                        std::scoped_lock lock(configMutex_);
                        config_ = config;
                    }
                }
            }
            catch (...)
            {
                config.EnterSafeState();
                std::scoped_lock lock(configMutex_);
                config_ = config;
            }
        }
        std::vector<std::pair<std::wstring, std::wstring>> menuProfiles;
        for (auto const& profile : config.EnabledCompleteProfiles()) menuProfiles.emplace_back(profile.id, profile.name);
        trayIcon_->SetProfiles(std::move(menuProfiles));
        RefreshTrayDdcControls();
        StopPeerHealthCheck();
        {
            std::scoped_lock lock(peerLifecycleMutex_);
            peer_->Stop();
        }
        auto usbConfigured = config.HasUsbDeviceConfiguration();
        auto hasUsbMapping = std::any_of(config.usbSwitch.displayInputs.begin(), config.usbSwitch.displayInputs.end(),
            [&](auto const& mapping) { return mapping.targetInput && FindDisplayById(config.displays, mapping.displayId); });
        auto automationConfigured = usbConfigured && hasUsbMapping;
        usbWatcher_->Reconfigure(config.usbSwitch.enabled && automationConfigured ? config.usbSwitch.vendorId : -1,
            config.usbSwitch.enabled && automationConfigured ? config.usbSwitch.productId : -1,
            config.usbSwitch.enabled && automationConfigured ? config.usbSwitch.deviceLocalReference : L"");
        auto completeProfiles = config.EnabledCompleteProfiles();
        auto bootstrapProfiles = config.UnboundBootstrapProfiles();
        std::vector<V2Target> v2Targets;
        for (auto const& profile : completeProfiles)
            if (profile.peerProtocolVersion == 2 && IsValidDisplayId(profile.peerEndpointId) && !EqualId(profile.peerEndpointId, config.localEndpointId) &&
                std::count_if(completeProfiles.begin(), completeProfiles.end(), [&](auto const& candidate)
                { return candidate.peerProtocolVersion == 2 && EqualId(candidate.peerEndpointId, profile.peerEndpointId); }) == 1)
                v2Targets.push_back({ profile.peerEndpointId, 2, false });
        auto hasV2 = std::any_of(v2Targets.begin(), v2Targets.end(), [](auto const& target) { return target.protocolVersion == 2; });
        auto hasUnboundV2 = !bootstrapProfiles.empty();
        v2StateMachine_ = std::make_unique<V2StateMachine>(V2StateInitial{
            config.localEndpointId, hasV2, V2CoordinatorState::Idle, {}, {}, std::move(v2Targets) });
        bool collaborationValid{};
        if (config.usbSwitch.collaborationWakeEnabled)
        {
            auto profile = config.FindCollaborationProfile(config.usbSwitch.collaborationProfileId);
            collaborationValid = profile && profile->coordinationEnabled &&
                std::any_of(completeProfiles.begin(), completeProfiles.end(), [&](auto const& item) { return EqualId(item.id, profile->id); });
        }
        UsbSwitchInitialState usbInitial{ config.usbSwitch.enabled, usbLearningActive_.load(),
            config.displayConfigurationSafeMode, std::nullopt, config.usbSwitch.collaborationWakeEnabled, collaborationValid };
        for (auto const& display : config.displays)
            usbInitial.displayMappings.push_back({ display.id, config.UsbInputForDisplay(display.id),
                !display.nativeMonitorId.empty(), true });
        usbInitial.bindingKey = config.usbSwitch.deviceLocalReference + L"|" +
            std::to_wstring(config.usbSwitch.vendorId) + L"|" + std::to_wstring(config.usbSwitch.productId);
        if (usbSwitchCoordinator_) usbSwitchCoordinator_->UpdateConfiguration(std::move(usbInitial));
        else usbSwitchCoordinator_ = std::make_unique<UsbSwitchCoordinator>(std::move(usbInitial));
        v2ReplayCache_.Clear();
        { std::scoped_lock lock(v2OutgoingMutex_); v2OutgoingMessages_.clear(); }
        v2PeerLastSeenMs_.clear();
        v2HealthProbes_.clear();
        if (!config.displayConfigurationSafeMode) sideEffectGate_.Allow();
        auto listenerPort = config.V2ListenerPort();
        if (!listenerPort) SetPeerConnectionStatus(!config.ReadonlyEnabledProfiles().empty() ? L"协同配置不完整" : L"协同未启用", false);
        if (hasUnboundV2 && !hasV2) SetPeerConnectionStatus(L"等待首次检测", false);
        // A completed, enabled profile may listen automatically on later starts.
        // An unbound draft listens only after the user explicitly checks network access.
        if (listenerPort && (hasV2 || networkAccessPrepared_))
        {
            if (EnsurePeerListening(*listenerPort) && hasV2) StartPeerHealthCheck();
        }
        if (applyAutoStart)
        {
            try { ApplyAutoStart(config.startWithWindows); }
            catch (hresult_error const& error) { ShowError(L"登录启动设置失败", error.message().c_str()); }
        }
        if (config.usbSwitch.enabled && !usbConfigured) SetStatus(L"USB 自动切换未配置");
        else if (config.usbSwitch.enabled && !hasUsbMapping) SetStatus(L"USB 显示器输入映射未配置");
        else if (!config.usbSwitch.enabled) SetStatus(L"USB 自动切换未开启");
        else
        {
            auto device = config.usbSwitch.deviceName.empty() ? L"已选择设备" : config.usbSwitch.deviceName;
            SetStatus(L"USB 自动切换已开启 · " + device);
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
        {
            std::scoped_lock lock(peerLifecycleMutex_);
            peer_->Stop();
        }
        usbWatcher_->Reconfigure(-1, -1);
        SetPeerConnectionStatus(L"USB 学习中，协同已暂停", false);
        SetStatus(L"正在学习 USB 设备；自动协同和硬件操作已暂停");
    }

    void Controller::EndUsbLearning()
    {
        if (!usbLearningActive_.exchange(false)) return;
        if (usbSwitchCoordinator_) usbSwitchCoordinator_->ConfigurationChanged();
        ApplyConfiguration(false);
    }

    bool Controller::AllowsSideEffects(uint64_t generation) const noexcept
    {
        return sideEffectGate_.AllowsSideEffects() && sideEffectGeneration_.load() == generation;
    }

    void Controller::OnUsbPresenceChanged(bool present)
    {
        if (!sideEffectGate_.AllowsSideEffects() || profileDetectionActive_) return;
        if (usbSwitchCoordinator_) ApplyUsbActions(usbSwitchCoordinator_->ObserveUsb(NowMilliseconds(), present));
        WriteDiagnostic(present ? "controller.usb_presence present=1" : "controller.usb_presence present=0");
    }

    void Controller::WakeDisplayCoalesced(std::vector<UsbSwitchAction> const& actions)
    {
        if (std::none_of(actions.begin(), actions.end(), [](auto const& action) { return action.kind == UsbSwitchAction::Kind::WakeDisplay; })) return;
        auto generation = sideEffectGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, generation]
        {
            auto self = weak.lock();
            if (!self || self->disposed_ || !self->AllowsSideEffects(generation)) return;
            static_cast<void>(WakeDisplay());
        }).detach();
    }

    void Controller::ApplyUsbActions(std::vector<UsbSwitchAction> actions)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        WakeDisplayCoalesced(actions);
        auto config = Config();
        std::vector<DisplayConfig> selected;
        for (auto const& action : actions)
        {
            if (action.kind != UsbSwitchAction::Kind::SwitchDisplay || !action.targetInput) continue;
            auto index = FindDisplayById(config.displays, action.displayId);
            if (!index) continue;
            auto display = config.displays[*index]; display.macInput = *action.targetInput; selected.push_back(std::move(display));
        }
        if (!selected.empty())
        {
            auto generation = sideEffectGeneration_.load();
            auto actionConfig = config; actionConfig.displays = std::move(selected);
            std::weak_ptr<Controller> weak = shared_from_this();
            std::thread([weak, generation, actionConfig]
            {
                auto self = weak.lock();
                if (!self || self->disposed_ || !self->AllowsSideEffects(generation)) return;
                auto result = SwitchDisplaysToMac(actionConfig);
                if (auto current = weak.lock(); current && current->AllowsSideEffects(generation))
                    current->Enqueue([weak, generation, result]
                    {
                        if (auto value = weak.lock(); value && value->AllowsSideEffects(generation))
                            value->SetStatus(result.success ? L"USB 已离开，显示器已切换" : L"USB 显示器切换部分失败：" + result.error);
                    });
            }).detach();
        }
        if (std::any_of(actions.begin(), actions.end(), [](auto const& action) { return action.kind == UsbSwitchAction::Kind::SendWakeDisplay; }))
            SendUsbWakeDisplay();
    }

    void Controller::SendUsbWakeDisplay()
    {
        auto config = Config();
        if (!config.usbSwitch.collaborationWakeEnabled) return;
        auto profile = config.FindCollaborationProfile(config.usbSwitch.collaborationProfileId);
        if (!profile || !profile->coordinationEnabled || profile->peerProtocolVersion != 2 || !IsValidDisplayId(profile->peerEndpointId)) return;
        SendV2({ V2Action::Kind::SendMessage, L"wake_display", NewEventId(), profile->peerEndpointId });
    }

    void Controller::ApplyV2Actions(std::vector<V2Action> actions)
    {
        auto connectedText = [this](std::wstring const& endpointId)
        {
            auto config = Config();
            auto profile = std::find_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(),
                [&](auto const& candidate)
                {
                    return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 &&
                        !EqualId(candidate.peerEndpointId, config.localEndpointId) &&
                        EqualId(candidate.peerEndpointId, endpointId);
                });
            return profile != config.collaborationProfiles.end() && !profile->name.empty()
                ? L"已和对端（" + profile->name + L"）建立连接" : L"已和对端建立连接";
        };
        if (!sideEffectGate_.AllowsSideEffects() || !v2StateMachine_) return;
        for (auto const& action : actions)
        {
            switch (action.kind)
            {
            case V2Action::Kind::SendMessage: SendV2(action); break;
            case V2Action::Kind::RequestWake:
            {
                if (profileDetectionActive_) break;
                auto eventId = action.eventId; auto generation = sideEffectGeneration_.load(); std::weak_ptr<Controller> weak = shared_from_this();
                std::thread([weak, eventId, generation]
                {
                    auto self = weak.lock(); if (!self || self->disposed_ || !self->AllowsSideEffects(generation)) return;
                    auto success = WakeDisplay();
                    if (auto current = weak.lock(); current && !current->disposed_)
                        current->Enqueue([weak, eventId, success, generation]
                        {
                            if (auto value = weak.lock(); value && value->v2StateMachine_ && value->AllowsSideEffects(generation))
                                value->ApplyV2Actions(value->v2StateMachine_->OnWakeCompleted(NowMilliseconds(), eventId, success));
                        });
                }).detach();
                break;
            }
            case V2Action::Kind::RequestSwitch:
            {
                if (profileDetectionActive_) break;
                auto config = Config();
                auto profile = std::find_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(),
                    [&](auto const& candidate) { return EqualId(candidate.peerEndpointId, action.endpointId); });
                if (profile != config.collaborationProfiles.end()) SwitchToProfile(profile->id, action.eventId);
                break;
            }
            case V2Action::Kind::SetPeerReachable:
                v2StateMachine_->SetTargetReachable(action.endpointId, action.value);
                SetPeerConnectionStatus(action.value ? connectedText(action.endpointId) : L"连接已中断", action.value);
                break;
            case V2Action::Kind::PromptManualSelection:
                SetStatus(L"对端不可用，请检查协同配置");
                break;
            case V2Action::Kind::IgnoreMessage:
                WriteDiagnostic("protocol.v2 message_ignored=1");
                break;
            case V2Action::Kind::LockTarget:
            case V2Action::Kind::ClearEvent:
                break;
            }
        }
    }

    void Controller::AdvanceStateMachine()
    {
        if (sideEffectGate_.AllowsSideEffects() && v2StateMachine_)
        {
            auto now = NowMilliseconds();
            for (auto item = v2PeerLastSeenMs_.begin(); item != v2PeerLastSeenMs_.end();)
            {
                if (now - item->second > 6000)
                {
                    v2StateMachine_->SetTargetReachable(item->first, false);
                    item = v2PeerLastSeenMs_.erase(item);
                    SetPeerConnectionStatus(L"连接已中断", false);
                }
                else ++item;
            }
            for (auto item = v2HealthProbes_.begin(); item != v2HealthProbes_.end();)
                if (item->second.Expired(now)) item = v2HealthProbes_.erase(item); else ++item;
            ApplyV2Actions(v2StateMachine_->Advance(NowMilliseconds()));
        }
    }

    void Controller::StartPeerHealthCheck()
    {
        StopPeerHealthCheck();
        if (!sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        if (!config.EnabledCompleteProfiles().empty()) SetPeerConnectionStatus(L"正在连接对端…", false);
        std::weak_ptr<Controller> weak = shared_from_this();
        peerHealthThread_ = std::jthread([weak](std::stop_token token)
        {
            int elapsedSinceProbe = 2000;
            while (!token.stop_requested())
            {
                auto self = weak.lock();
                if (!self || self->disposed_) return;
                self->Enqueue([weak] { if (auto value = weak.lock()) value->AdvanceStateMachine(); });
                if (elapsedSinceProbe >= 2000 && !self->Config().EnabledCompleteProfiles().empty())
                {
                    self->Enqueue([weak]
                    {
                        if (auto value = weak.lock())
                        {
                            auto config = value->Config();
                            for (auto const& profile : config.EnabledCompleteProfiles())
                                if (profile.peerProtocolVersion == 2 && IsValidDisplayId(profile.peerEndpointId)) value->SendV2Probe(profile);
                        }
                    });
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

    bool Controller::EnsurePeerListening(int port)
    {
        if (disposed_ || !peer_ || port < 1 || port > 65535 || !sideEffectGate_.AllowsSideEffects()) return false;
        std::scoped_lock lock(peerLifecycleMutex_);
        if (peer_->IsRunning() && peer_->LocalPort() == port) return true;
        peer_->Start(port);
        return peer_->IsRunning() && peer_->LocalPort() == port;
    }

    bool Controller::IsPeerListening(int port) const
    {
        if (!peer_ || port < 1 || port > 65535) return false;
        std::scoped_lock lock(peerLifecycleMutex_);
        return peer_->IsRunning() && peer_->LocalPort() == port;
    }

    void Controller::HandleDatagram(UdpPeer::Datagram const& datagram)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        if (!IsV2Datagram(datagram.data)) return;
        V2Message message; auto parsed = ParseV2Message(datagram.data, message); if (!parsed.accepted) return;
        auto config = Config();
        auto configurationGeneration = configurationGeneration_.load();
        if (profileDetection_ && profileDetection_->session.WaitingForV2() && message.type == L"status_response" &&
            EqualId(message.eventId, profileDetection_->session.PendingEventId()))
        {
            auto detectionGeneration = profileDetection_->generation;
            auto localEndpointId = profileDetection_->workingConfig.localEndpointId;
            auto pairingCode = profileDetection_->profile.pairingCode;
            std::weak_ptr<Controller> weak = shared_from_this();
            std::thread([weak, message = std::move(message), detectionGeneration,
                localEndpointId = std::move(localEndpointId), pairingCode = std::move(pairingCode)]
            {
                auto self = weak.lock();
                if (!self || self->disposed_ || self->profileDetectionGeneration_ != detectionGeneration) return;
                V2ValidationResult validation;
                try
                {
                    auto key = self->v2KeyCache_.Get(pairingCode, message.sourceEndpointId);
                    validation = ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
                        static_cast<int64_t>(UdpPeer::TimestampNow()), &self->profileDetectionReplayCache_, NowMilliseconds());
                }
                catch (...) { return; }
                if (!validation.accepted && validation.reason != L"authentication_failed") return;
                self->Enqueue([weak, message = std::move(message), detectionGeneration,
                    authenticated = validation.accepted]
                {
                    if (auto value = weak.lock(); value && !value->disposed_ && value->profileDetection_ &&
                        value->profileDetection_->generation == detectionGeneration &&
                        value->profileDetection_->session.WaitingForV2() &&
                        EqualId(value->profileDetection_->session.PendingEventId(), message.eventId))
                        value->ApplyProfileDetectionAction(value->profileDetection_->session.OnV2StatusResponse(
                            NowMilliseconds(), message.eventId, message.sourceEndpointId, authenticated));
                });
            }).detach();
            return;
        }
        if (message.type == L"status_probe" && !message.targetEndpointId)
        {
            std::vector<CollaborationProfile> candidates = config.UnboundBootstrapProfiles();
            for (auto const& profile : config.collaborationProfiles)
                if (!profile.peerEndpointId.empty()) candidates.push_back(profile);
            if (profileDetection_)
            {
                auto const& draft = profileDetection_->profile;
                auto inspection = profileDetection_->workingConfig.InspectProfile(draft.id);
                if (inspection.complete && draft.peerEndpointId.empty() &&
                    (!draft.peerProtocolVersion || *draft.peerProtocolVersion == 2))
                {
                    auto existing = std::find_if(candidates.begin(), candidates.end(), [&](auto const& profile)
                    { return EqualId(profile.id, draft.id); });
                    if (existing == candidates.end()) candidates.push_back(draft); else *existing = draft;
                }
            }
            std::weak_ptr<Controller> weak = shared_from_this();
            std::thread([weak, message = std::move(message), source = datagram.source,
                config = std::move(config), candidates = std::move(candidates), configurationGeneration]
            {
                if (auto self = weak.lock(); self && !self->disposed_)
                    self->HandleUnboundStatusProbe(message, source, config, candidates, configurationGeneration);
            }).detach();
            return;
        }
        if (!v2StateMachine_) return;
        auto matches = std::count_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(), [&](auto const& candidate)
        {
            return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 && !EqualId(candidate.peerEndpointId, config.localEndpointId) && EqualId(candidate.peerEndpointId, message.sourceEndpointId);
        });
        if (matches != 1) return;
        auto profile = std::find_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(), [&](auto const& candidate)
        {
            return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 && !EqualId(candidate.peerEndpointId, config.localEndpointId) && EqualId(candidate.peerEndpointId, message.sourceEndpointId);
        });
        if (profile == config.collaborationProfiles.end()) return;
        auto profileId = profile->id;
        auto pairingCode = profile->pairingCode;
        auto localEndpointId = config.localEndpointId;
        auto peerEndpointId = profile->peerEndpointId;
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, message = std::move(message), profileId = std::move(profileId),
            pairingCode = std::move(pairingCode), localEndpointId = std::move(localEndpointId),
            peerEndpointId = std::move(peerEndpointId), configurationGeneration]
        {
            auto self = weak.lock();
            if (!self || self->disposed_ || self->configurationGeneration_.load() != configurationGeneration) return;
            V2ValidationResult validation;
            try
            {
                auto key = self->v2KeyCache_.Get(pairingCode, message.sourceEndpointId);
                validation = ValidateV2Message(message, localEndpointId, peerEndpointId, key,
                    static_cast<int64_t>(UdpPeer::TimestampNow()), &self->v2ReplayCache_, NowMilliseconds());
            }
            catch (...) { return; }
            if (!validation.accepted) return;
            self->Enqueue([weak, message = std::move(message), profileId = std::move(profileId),
                validation, configurationGeneration]
            {
                if (auto value = weak.lock())
                    value->HandleValidatedDatagram(message, profileId, validation, configurationGeneration);
            });
        }).detach();
    }

    void Controller::HandleValidatedDatagram(V2Message const& message, std::wstring const& profileId,
        V2ValidationResult const& validated, uint64_t configurationGeneration)
    {
        if (disposed_ || configurationGeneration_.load() != configurationGeneration || !v2StateMachine_) return;
        auto config = Config();
        auto profile = config.FindCollaborationProfile(profileId);
        if (!profile || !profile->coordinationEnabled || profile->peerProtocolVersion != 2 ||
            !EqualId(profile->peerEndpointId, message.sourceEndpointId)) return;
        auto now = NowMilliseconds(); std::vector<V2Action> actions;
        if (message.type == L"status_response")
        {
            auto pending = v2HealthProbes_.find(message.sourceEndpointId);
            if (pending == v2HealthProbes_.end() || !pending->second.MatchesAndConsume(message.eventId, now)) return;
            v2HealthProbes_.erase(pending);
            v2StateMachine_->SetTargetReachable(message.sourceEndpointId, true);
            v2PeerLastSeenMs_[message.sourceEndpointId] = now;
            SetPeerConnectionStatus(L"已和对端（" + profile->name + L"）建立连接", true);
            return;
        }
        if (message.type == L"wake_display")
        {
            if (!validated.duplicate && usbSwitchCoordinator_)
                ApplyUsbActions(usbSwitchCoordinator_->ReceiveWakeDisplay(now));
            return;
        }
        if (message.type != L"status_probe")
        {
            v2StateMachine_->SetTargetReachable(message.sourceEndpointId, true);
            v2PeerLastSeenMs_[message.sourceEndpointId] = now;
            SetPeerConnectionStatus(L"已和对端（" + profile->name + L"）建立连接", true);
        }
        if (message.type == L"status_probe") actions = v2StateMachine_->OnStatusProbe(now, message.sourceEndpointId, message.eventId, true);
        else if (message.type == L"handover_request") actions = v2StateMachine_->OnHandoverRequest(now, message.sourceEndpointId, message.eventId, true, message.intent.value_or(L"manual"));
        else if (message.type == L"target_ready") actions = v2StateMachine_->OnTargetReady(now, message.sourceEndpointId, message.eventId, true, message.wakeSucceeded.value_or(false));
        else if (message.type == L"committed") actions = v2StateMachine_->OnCommitted(now, message.sourceEndpointId, message.eventId, true, message.switchSucceeded.value_or(false));
        else if (message.type == L"cancelled") actions = v2StateMachine_->OnCancelled(now, message.sourceEndpointId, message.eventId, true, message.reason.value_or(L"cancelled"));
        ApplyV2Actions(std::move(actions));
    }

    bool Controller::HandleUnboundStatusProbe(V2Message const& message, DatagramSource const& source,
        AppConfig const& config, std::vector<CollaborationProfile> const& candidates,
        uint64_t configurationGeneration)
    {
        if (disposed_ || configurationGeneration_.load() != configurationGeneration) return false;
        auto match = MatchUnboundStatusProbe(candidates, config.localEndpointId, source, message,
            static_cast<int64_t>(UdpPeer::TimestampNow()), NowMilliseconds(),
            [](CollaborationProfile const& profile, DatagramSource const& sender)
            { return UdpPeer::SourceMatches(sender, profile.peerHost, profile.peerPort); }, &v2ReplayCache_,
            [this](std::wstring const& pairingCode, std::wstring const& endpointId)
            { return v2KeyCache_.Get(pairingCode, endpointId); });
        if (match.status != UnboundProbeMatchStatus::Matched || !match.profileIndex) return false;
        auto const& profile = candidates[*match.profileIndex];
        try
        {
            auto now = static_cast<int64_t>(UdpPeer::TimestampNow());
            std::scoped_lock lock(v2OutgoingMutex_);
            for (auto item = v2OutgoingMessages_.begin(); item != v2OutgoingMessages_.end();)
                if (now - item->second.timestamp > 30) item = v2OutgoingMessages_.erase(item); else ++item;
            auto cacheKey = L"unbound_status_response|" + message.eventId + L"|" + message.sourceEndpointId;
            auto cached = v2OutgoingMessages_.find(cacheKey);
            V2Message response;
            if (cached != v2OutgoingMessages_.end()) response = cached->second;
            else
            {
                response = CreateUnboundStatusResponse(message, config.localEndpointId, now,
                    GenerateV2Nonce(), profile.pairingCode,
                    [this](std::wstring const& pairingCode, std::wstring const& endpointId)
                    { return v2KeyCache_.Get(pairingCode, endpointId); });
                v2OutgoingMessages_.emplace(cacheKey, response);
            }
            if (configurationGeneration_.load() != configurationGeneration) return false;
            peer_->SendRaw(SerializeV2Message(response), source.address, source.port, false);
            return true;
        }
        catch (...) { return false; }
    }

    void Controller::SendV2(V2Action const& action)
    {
        if (disposed_ || !peer_ || !sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        auto profile = std::find_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(), [&](auto const& candidate)
        {
            return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 && EqualId(candidate.peerEndpointId, action.endpointId);
        });
        if (profile == config.collaborationProfiles.end() || EqualId(profile->peerEndpointId, config.localEndpointId) ||
            std::count_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(), [&](auto const& candidate)
            { return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 && EqualId(candidate.peerEndpointId, action.endpointId); }) != 1) return;
        if (!IsPeerListening(config.listenPort)) return;
        auto selectedProfile = *profile;
        auto configurationGeneration = configurationGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, action, config = std::move(config), profile = std::move(selectedProfile),
            configurationGeneration]
        {
            auto self = weak.lock();
            if (!self || self->disposed_ || self->configurationGeneration_.load() != configurationGeneration) return;
            auto now = static_cast<int64_t>(UdpPeer::TimestampNow());
            auto cacheKey = action.type + L"|" + action.eventId + L"|" + action.endpointId;
            V2Message message;
            try
            {
                std::scoped_lock lock(self->v2OutgoingMutex_);
                for (auto item = self->v2OutgoingMessages_.begin(); item != self->v2OutgoingMessages_.end();)
                    if (now - item->second.timestamp > 30) item = self->v2OutgoingMessages_.erase(item); else ++item;
                auto cached = self->v2OutgoingMessages_.find(cacheKey);
                if (cached != self->v2OutgoingMessages_.end()) message = cached->second;
                else
                {
                    message.type = action.type; message.eventId = action.eventId;
                    message.sourceEndpointId = config.localEndpointId;
                    message.targetEndpointId = profile.peerEndpointId;
                    message.sourcePlatform = L"windows"; message.timestamp = now; message.nonce = GenerateV2Nonce();
                    if (!action.intent.empty()) message.intent = action.intent;
                    if (action.wakeSucceeded) message.wakeSucceeded = action.wakeSucceeded;
                    if (action.switchSucceeded) message.switchSucceeded = action.switchSucceeded;
                    if (!action.reason.empty()) message.reason = action.reason;
                    auto key = self->v2KeyCache_.Get(profile.pairingCode, config.localEndpointId);
                    message = SignV2Message(std::move(message), key);
                    self->v2OutgoingMessages_.emplace(cacheKey, message);
                }
            }
            catch (...) { return; }
            if (self->disposed_ || self->configurationGeneration_.load() != configurationGeneration) return;
            self->peer_->SendRaw(SerializeV2Message(message), profile.peerHost, profile.peerPort,
                action.type != L"status_probe" && action.type != L"status_response");
        }).detach();
    }

    void Controller::SendV2Probe(CollaborationProfile const& profile)
    {
        auto eventId = NewEventId();
        v2HealthProbes_[profile.peerEndpointId].Begin(eventId, NowMilliseconds() + 10000);
        SendV2({ V2Action::Kind::SendMessage, L"status_probe", eventId, profile.peerEndpointId });
    }

    void Controller::SwitchToProfile(std::wstring const& profileId, std::optional<std::wstring> eventId)
    {
        if (!sideEffectGate_.AllowsSideEffects() || profileDetectionActive_) return;
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
        std::thread([weak, actionConfig, name, missing, generation, eventId]
        {
            auto controller = weak.lock();
            if (!controller || controller->disposed_ || !controller->AllowsSideEffects(generation)) return;
            auto result = SwitchDisplaysToMac(actionConfig);
            if (auto self = weak.lock(); self && !self->disposed_)
                self->Enqueue([weak, result, name, missing, generation, eventId]
                {
                    if (auto value = weak.lock(); value && value->AllowsSideEffects(generation))
                    {
                        if (eventId && value->v2StateMachine_)
                            value->ApplyV2Actions(value->v2StateMachine_->OnSwitchCompleted(NowMilliseconds(), *eventId, result.success));
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
        if (profileDetectionActive_) { SetStatus(L"正在检测协同配置，请稍候"); return; }
        auto config = Config(); auto profile = config.FindCollaborationProfile(profileId);
        if (profile && profile->coordinationEnabled && profile->peerProtocolVersion == 2 && IsValidDisplayId(profile->peerEndpointId) && v2StateMachine_)
        {
            if (EqualId(profile->peerEndpointId, config.localEndpointId) ||
                std::count_if(config.collaborationProfiles.begin(), config.collaborationProfiles.end(), [&](auto const& candidate)
                { return candidate.coordinationEnabled && candidate.peerProtocolVersion == 2 && EqualId(candidate.peerEndpointId, profile->peerEndpointId); }) != 1)
            {
                SetStatus(L"协同 endpoint 配置有冲突，未执行切换");
                return;
            }
            ApplyV2Actions(v2StateMachine_->OnManualSelect(NowMilliseconds(), profile->peerEndpointId, NewEventId()));
            return;
        }
        SwitchToProfile(profileId);
    }

    void Controller::WriteTrayDdc(std::wstring const& displayId, DdcVcpCode code, int value)
    {
        if (!sideEffectGate_.AllowsSideEffects() || profileDetectionActive_) return;
        auto generation = sideEffectGeneration_.load();
        if (!trayDdcWrites_.Submit({ displayId, code, value, generation })) return;
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak] { if (auto self = weak.lock()) self->ProcessTrayDdcWrites(); }).detach();
    }

    void Controller::ProcessTrayDdcWrites()
    {
        while (auto request = trayDdcWrites_.TakeNext())
        {
            if (!AllowsSideEffects(request->generation) || profileDetectionActive_) continue;
            auto config = Config();
            DdcBackendSet backends; DdcCancellationSource cancellation; auto token = cancellation.Begin();
            std::weak_ptr<Controller> weak = shared_from_this();
            DdcControlService service([&](std::wstring const& key) { return backends.Lookup(key); },
                [weak, generation = request->generation]
                { if (auto current = weak.lock()) return current->AllowsSideEffects(generation); return false; });
            auto result = service.Write(config, request->displayId, request->code, request->value,
                config.linkAllDisplays, token);
            if (!result.success || !AllowsSideEffects(request->generation)) continue;
            try { config.Save(); }
            catch (...)
            {
                trayDdcWrites_.CancelPending();
                static_cast<void>(trayDdcWrites_.TakeNext());
                Enqueue([weak] { if (auto current = weak.lock()) current->EnterSafeStateAfterSaveFailure(); });
                return;
            }
            if (!AllowsSideEffects(request->generation)) continue;
            { std::scoped_lock lock(configMutex_); config_ = std::move(config); }
            Enqueue([weak, generation = request->generation]
            {
                if (auto current = weak.lock(); current && current->AllowsSideEffects(generation))
                    current->RefreshTrayDdcControls();
            });
        }
    }

    void Controller::RefreshTrayDdcControls()
    {
        if (!trayIcon_) return;
        std::vector<TrayDdcItem> items;
        for (auto const& control : BuildDdcTrayControls(Config()))
            items.push_back({ control.displayId, control.displayName, control.code, control.label,
                control.value, control.maximum, control.hasValue });
        trayIcon_->SetDdcItems(std::move(items));
    }

    void Controller::CheckNetworkAccess(AppConfig const& workingConfig,
        std::function<void(bool, std::wstring const&)> completed)
    {
        if (disposed_ || workingConfig.displayConfigurationSafeMode ||
            !IsValidDisplayId(workingConfig.localEndpointId) ||
            workingConfig.listenPort < 1 || workingConfig.listenPort > 65535)
        {
            if (completed) completed(false, L"本机协同配置不完整，未启动网络监听。");
            return;
        }
        auto port = workingConfig.listenPort;
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, port, completed = std::move(completed)]() mutable
        {
            auto self = weak.lock();
            auto ready = self && !self->disposed_ && self->EnsurePeerListening(port);
            if (ready) self->networkAccessPrepared_ = true;
            auto message = ready
                ? L"本机 UDP 端口已就绪，可以继续检测连接。若 Windows 弹出提示，请允许专用网络访问。"
                : L"无法启动本机 UDP 监听。请检查端口占用和 Windows 网络权限。";
            if (self && !self->disposed_)
                self->Enqueue([completed = std::move(completed), ready, message = std::move(message)]() mutable
                {
                    if (completed) completed(ready, message);
                });
        }).detach();
    }

    void Controller::BeginProfileDetection(AppConfig const& workingConfig, std::wstring const& profileId,
        std::function<void(ProfileDetectionResult const&)> completed)
    {
        if (disposed_) return;
        if (profileDetection_)
        {
            profileDetection_->session.Cancel();
            CompleteProfileDetection({ ProfileDetectionOutcome::NoResponse });
        }
        if (!IsPeerListening(workingConfig.listenPort))
        {
            if (completed) completed({ ProfileDetectionOutcome::NetworkNotReady });
            return;
        }
        auto profile = workingConfig.FindCollaborationProfile(profileId);
        auto inspection = workingConfig.InspectProfile(profileId);
        auto complete = profile && inspection.complete && !workingConfig.displayConfigurationSafeMode &&
            IsValidDisplayId(workingConfig.localEndpointId) && workingConfig.listenPort >= 1 && workingConfig.listenPort <= 65535;
        PendingProfileDetection pending;
        pending.workingConfig = workingConfig;
        if (profile) pending.profile = *profile;
        pending.completed = std::move(completed);
        pending.generation = ++profileDetectionGeneration_;
        profileDetection_ = std::move(pending);
        v2KeyCache_.Clear();
        profileDetectionReplayCache_.Clear();
        auto action = profileDetection_->session.Start(NowMilliseconds(), complete,
            profile ? profile->peerEndpointId : std::wstring{}, NewEventId());
        if (action.kind == ProfileDetectionAction::Kind::Complete)
        {
            ApplyProfileDetectionAction(std::move(action));
            return;
        }

        profileDetectionActive_ = true;
        // Invalidate hardware work that was queued before detection began. The
        // runtime state machines are rebuilt from the saved configuration when
        // detection completes, so an old timeout cannot fire after the pause.
        ++sideEffectGeneration_;
        StopPeerHealthCheck();
        ApplyProfileDetectionAction(std::move(action));
        auto generation = profileDetection_->generation;
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, generation]
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(ProfileDetectionSession::ProbeTimeoutMilliseconds));
            if (auto self = weak.lock(); self && !self->disposed_)
                self->Enqueue([weak, generation] { if (auto value = weak.lock()) value->AdvanceProfileDetection(generation); });
        }).detach();
    }

    void Controller::AdvanceProfileDetection(uint64_t generation)
    {
        if (!profileDetection_ || profileDetection_->generation != generation) return;
        auto action = profileDetection_->session.Advance(NowMilliseconds());
        ApplyProfileDetectionAction(std::move(action));
    }

    void Controller::ApplyProfileDetectionAction(ProfileDetectionAction action)
    {
        if (!profileDetection_) return;
        if (action.kind == ProfileDetectionAction::Kind::Complete)
        {
            CompleteProfileDetection(action.result);
            return;
        }
        if (!peer_ || !peer_->IsRunning()) return;
        auto config = profileDetection_->workingConfig;
        auto profile = profileDetection_->profile;
        auto generation = profileDetection_->generation;
        if (action.kind != ProfileDetectionAction::Kind::SendV2Probe) return;
        V2Message message;
        message.type = L"status_probe";
        message.eventId = action.eventId;
        message.sourceEndpointId = config.localEndpointId;
        if (IsValidDisplayId(profile.peerEndpointId)) message.targetEndpointId = profile.peerEndpointId;
        message.sourcePlatform = L"windows";
        message.timestamp = static_cast<int64_t>(UdpPeer::TimestampNow());
        message.nonce = GenerateV2Nonce();
        std::weak_ptr<Controller> weak = shared_from_this();
        profileDetectionProbeOperation_.Start(
            [weak, message = std::move(message), profile = std::move(profile), generation]
            (ProfileDetectionAsyncOperation::IsCanceled const& canceled) mutable
            {
                auto self = weak.lock();
                if (!self || self->disposed_ || self->profileDetectionGeneration_ != generation || canceled()) return true;
                auto key = self->v2KeyCache_.Get(profile.pairingCode, message.sourceEndpointId);
                message = SignV2Message(std::move(message), key);
                if (self->disposed_ || self->profileDetectionGeneration_ != generation || canceled()) return true;
                self->peer_->SendRaw(SerializeV2Message(message), profile.peerHost, profile.peerPort, false,
                    [weak, generation, canceled]
                    {
                        auto current = weak.lock();
                        return current && !current->disposed_ && current->profileDetectionActive_ &&
                            current->profileDetectionGeneration_.load() == generation && !canceled();
                    });
                return true;
            },
            [weak](std::function<void()> completion)
            {
                if (auto self = weak.lock()) self->Enqueue(std::move(completion));
            },
            [weak, generation](bool succeeded)
            {
                if (!succeeded)
                    if (auto value = weak.lock(); value && value->profileDetection_ &&
                        value->profileDetection_->generation == generation)
                        value->CompleteProfileDetection({ ProfileDetectionOutcome::LocalConfigurationIncomplete });
            });
    }

    void Controller::CompleteProfileDetection(ProfileDetectionResult const& result)
    {
        if (!profileDetection_) return;
        auto completed = std::move(profileDetection_->completed);
        auto wasActive = profileDetectionActive_.load();
        ++profileDetectionGeneration_;
        profileDetectionProbeOperation_.Cancel();
        profileDetection_->session.Cancel();
        profileDetection_.reset();
        profileDetectionReplayCache_.Clear();
        v2KeyCache_.Clear();
        if (wasActive) ApplyConfiguration(false);
        profileDetectionActive_ = false;
        if (completed) completed(result);
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
                    if (!self->usbLearningActive_) self->ApplyConfiguration();
                    return true;
                }
                return false;
            },
            [weak](AppConfig& config, std::vector<std::wstring> const& displayIds,
                DdcCancellationToken const& cancellation)
            {
                if (auto self = weak.lock())
                {
                    if (self->profileDetectionActive_) { DdcControlBatchResult result; result.canceled = true; return result; }
                    DdcBackendSet backends;
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
                    if (self->profileDetectionActive_) { DdcControlBatchResult result; result.canceled = true; return result; }
                    DdcBackendSet backends;
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
            [weak](AppConfig const& config, std::function<void(bool, std::wstring const&)> completed)
            {
                if (auto self = weak.lock()) self->CheckNetworkAccess(config, std::move(completed));
            },
            [weak](AppConfig const& config, std::wstring const& profileId,
                std::function<void(ProfileDetectionResult const&)> completed)
            {
                if (auto self = weak.lock()) self->BeginProfileDetection(config, profileId, std::move(completed));
            },
            [weak]
            {
                if (auto self = weak.lock(); self && self->profileDetection_)
                {
                    self->profileDetection_->completed = {};
                    self->CompleteProfileDetection({ ProfileDetectionOutcome::NoResponse });
                }
            },
            [weak] { if (auto self = weak.lock()) self->BeginUsbLearning(); },
            [weak] { if (auto self = weak.lock()) self->EndUsbLearning(); },
            [weak]
            {
                if (auto self = weak.lock())
                {
                    if (self->profileDetection_)
                    {
                        self->profileDetection_->completed = {};
                        self->CompleteProfileDetection({ ProfileDetectionOutcome::NoResponse });
                    }
                    self->settingsWindow_ = nullptr;
                }
            });
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
        if (peer_)
        {
            std::scoped_lock lock(peerLifecycleMutex_);
            peer_->Stop();
        }
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
