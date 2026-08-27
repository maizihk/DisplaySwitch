#include "pch.h"
#include "Controller.h"
#include "AutoStart.h"
#include "Diagnostics.h"
#include "DdcBackends.h"
#include "ProtocolMessage.h"
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
        ++sideEffectGeneration_;
        sideEffectGate_.Block();
        auto config = Config();
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
        auto completeProfiles = config.EnabledCompleteProfiles();
        auto hasV1 = config.usbAutomationEnabled && config.coordinationEnabled && coordinationConfigured &&
            config.collaborationProfiles.size() == 1 && config.collaborationProfiles.front().peerProtocolVersion.value_or(1) == 1;
        auto legacyUsbAutomation = config.usbAutomationEnabled && automationConfigured && (completeProfiles.empty() || hasV1);
        StateMachineInitialState initial{
            .localPlatform = L"windows",
            .coordinationEnabled = hasV1,
            .usbAutomationEnabled = legacyUsbAutomation,
            .usbPresent = usbWatcher_->IsPresent(),
        };
        stateMachine_ = std::make_unique<HandoverStateMachine>(StateMachineConfig{
            L"windows", config.pairingCode, initial.coordinationEnabled, initial.usbAutomationEnabled, 0.0, {}
        }, initial, [] { return Controller::NewEventId(); });
        std::vector<V2Target> v2Targets;
        for (auto const& profile : completeProfiles)
            if (profile.peerProtocolVersion == 1)
                v2Targets.push_back({ IsValidDisplayId(profile.peerEndpointId) ? profile.peerEndpointId : profile.id, 1, false });
            else if (profile.peerProtocolVersion == 2 && IsValidDisplayId(profile.peerEndpointId) && !EqualId(profile.peerEndpointId, config.localEndpointId) &&
                std::count_if(completeProfiles.begin(), completeProfiles.end(), [&](auto const& candidate)
                { return candidate.peerProtocolVersion == 2 && EqualId(candidate.peerEndpointId, profile.peerEndpointId); }) == 1)
                v2Targets.push_back({ profile.peerEndpointId, 2, false });
        auto hasV2 = std::any_of(v2Targets.begin(), v2Targets.end(), [](auto const& target) { return target.protocolVersion == 2; });
        auto hasUnboundV2 = std::any_of(completeProfiles.begin(), completeProfiles.end(), [](auto const& profile)
        { return profile.peerEndpointId.empty() && profile.peerProtocolVersion != 1; });
        v2StateMachine_ = std::make_unique<V2StateMachine>(V2StateInitial{
            config.localEndpointId, hasV2, usbWatcher_->IsPresent(), usbWatcher_->IsPresent(),
            V2CoordinatorState::Idle, {}, {}, std::move(v2Targets) });
        v2ReplayCache_.Clear(); v2OutgoingMessages_.clear(); v2PeerLastSeenMs_.clear();
        v1HealthProbe_.Clear(); v2HealthProbes_.clear();
        if (!config.displayConfigurationSafeMode) sideEffectGate_.Allow();
        if (hasV1 || hasV2 || hasUnboundV2) peer_->Start(config.listenPort);
        else SetPeerConnectionStatus(!config.ReadonlyEnabledProfiles().empty() ? L"协同配置不完整" : L"协同未启用", false);
        if (hasUnboundV2 && !hasV1 && !hasV2) SetPeerConnectionStatus(L"等待首次 endpoint 检测", false);
        if (hasV1 || hasV2) StartPeerHealthCheck();
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
        if (!sideEffectGate_.AllowsSideEffects() || profileDetectionActive_) return;
        WriteDiagnostic(present ? "controller.usb_presence present=1" : "controller.usb_presence present=0");
        if (!stateMachine_) return;
        SetStatus(present ? L"USB 已接入 Windows" : L"USB 已离开 Windows，等待确认…");
        auto now = NowMilliseconds();
        ApplyStateMachineActions(stateMachine_->OnUsbPresenceChanged(now, present));
        if (v2StateMachine_)
        {
            auto event = present ? NewEventId() : NewEventId();
            ApplyV2Actions(v2StateMachine_->OnTargetInputPresenceChanged(now, present, present ? event : L""));
            ApplyV2Actions(v2StateMachine_->OnSourceInputPresenceChanged(now, present, present ? L"" : event));
        }
    }

    void Controller::ApplyV2Actions(std::vector<V2Action> actions)
    {
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
                SetPeerConnectionStatus(action.value ? L"已连接到对端" : L"连接已中断", action.value);
                break;
            case V2Action::Kind::PromptManualSelection:
                SetStatus(L"未发现明确目标，请手动选择协同配置");
                break;
            case V2Action::Kind::StartDiscovery:
                SetStatus(L"正在发现接入 USB 的对端…");
                break;
            case V2Action::Kind::IgnoreMessage:
                WriteDiagnostic("protocol.v2 message_ignored=1");
                break;
            case V2Action::Kind::LockTarget:
            case V2Action::Kind::ClearEvent:
            case V2Action::Kind::RouteToV1:
                break;
            }
        }
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
                if (profileDetectionActive_) break;
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
                if (!profileDetectionActive_)
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
            if (v1HealthProbe_.Expired(now)) v1HealthProbe_.Clear();
            ApplyV2Actions(v2StateMachine_->Advance(NowMilliseconds()));
        }
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
                            if (config.collaborationProfiles.size() == 1 &&
                                config.collaborationProfiles.front().peerProtocolVersion.value_or(1) == 1)
                                value->Send(L"status_probe", value->NewEventId(), std::nullopt);
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

    void Controller::HandlePeerMessage(PeerMessage const& message)
    {
        if (!sideEffectGate_.AllowsSideEffects() || !stateMachine_) return;
        ApplyStateMachineActions(stateMachine_->OnPeerMessage(NowMilliseconds(), message));
    }

    void Controller::HandleDatagram(UdpPeer::Datagram const& datagram)
    {
        if (!sideEffectGate_.AllowsSideEffects()) return;
        auto version = ParseProtocolVersion(datagram.data);
        if (version == 1)
        {
            PeerMessage message; auto parsed = ParsePeerMessage(datagram.data, message);
            if (!parsed.accepted) return;
            if (profileDetection_ && profileDetection_->session.WaitingForV1() && message.type == L"status_response" &&
                EqualId(message.eventId, profileDetection_->session.PendingEventId()))
            {
                auto accepted = ValidatePeerMessage(message, L"windows", profileDetection_->profile.pairingCode,
                    UdpPeer::TimestampNow()).accepted;
                ApplyProfileDetectionAction(profileDetection_->session.OnV1StatusResponse(
                    NowMilliseconds(), message.eventId, accepted));
                return;
            }
            if (message.type == L"status_response")
            {
                auto config = Config();
                if (!ValidatePeerMessage(message, L"windows", config.pairingCode, UdpPeer::TimestampNow()).accepted ||
                    !v1HealthProbe_.MatchesAndConsume(message.eventId, NowMilliseconds())) return;
            }
            HandlePeerMessage(message);
            return;
        }
        if (version != 2) return;
        V2Message message; auto parsed = ParseV2Message(datagram.data, message); if (!parsed.accepted) return;
        if (profileDetection_ && profileDetection_->session.WaitingForV2() && message.type == L"status_response" &&
            EqualId(message.eventId, profileDetection_->session.PendingEventId()))
        {
            bool authenticated{};
            try
            {
                auto secret = NormalizeV2PairingSecret(profileDetection_->profile.pairingCode);
                auto key = DeriveV2AuthenticationKey(secret, message.sourceEndpointId);
                auto validation = ValidateV2Message(message, profileDetection_->workingConfig.localEndpointId,
                    message.sourceEndpointId, key, static_cast<int64_t>(UdpPeer::TimestampNow()),
                    &profileDetectionReplayCache_, NowMilliseconds());
                authenticated = validation.accepted;
                if (!authenticated && validation.reason != L"authentication_failed") return;
            }
            catch (...) { return; }
            ApplyProfileDetectionAction(profileDetection_->session.OnV2StatusResponse(
                NowMilliseconds(), message.eventId, message.sourceEndpointId, authenticated));
            return;
        }
        if (message.type == L"status_probe" && !message.targetEndpointId)
        {
            HandleUnboundStatusProbe(message, datagram.source);
            return;
        }
        if (!v2StateMachine_) return;
        auto config = Config();
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
        std::vector<uint8_t> secret;
        try { secret = NormalizeV2PairingSecret(profile->pairingCode); }
        catch (...) { return; }
        auto key = DeriveV2AuthenticationKey(secret, message.sourceEndpointId);
        auto validated = ValidateV2Message(message, config.localEndpointId, profile->peerEndpointId, key,
            static_cast<int64_t>(UdpPeer::TimestampNow()), &v2ReplayCache_, NowMilliseconds());
        if (!validated.accepted) return;
        auto now = NowMilliseconds(); std::vector<V2Action> actions;
        if (message.type == L"status_response")
        {
            auto pending = v2HealthProbes_.find(message.sourceEndpointId);
            if (pending == v2HealthProbes_.end() || !pending->second.MatchesAndConsume(message.eventId, now)) return;
            v2HealthProbes_.erase(pending);
            v2StateMachine_->SetTargetReachable(message.sourceEndpointId, true);
            v2PeerLastSeenMs_[message.sourceEndpointId] = now;
            SetPeerConnectionStatus(L"已连接到 " + profile->name, true);
            return;
        }
        if (message.type != L"status_probe")
        {
            v2StateMachine_->SetTargetReachable(message.sourceEndpointId, true);
            v2PeerLastSeenMs_[message.sourceEndpointId] = now;
            SetPeerConnectionStatus(L"已连接到 " + profile->name, true);
        }
        if (message.type == L"status_probe") actions = v2StateMachine_->OnStatusProbe(now, message.sourceEndpointId, message.eventId, true);
        else if (message.type == L"input_present") actions = v2StateMachine_->OnPeerInputPresent(now, message.sourceEndpointId, message.eventId, true);
        else if (message.type == L"handover_request") actions = v2StateMachine_->OnHandoverRequest(now, message.sourceEndpointId, message.eventId, true, message.intent.value_or(L"input_handover"));
        else if (message.type == L"target_ready") actions = v2StateMachine_->OnTargetReady(now, message.sourceEndpointId, message.eventId, true, message.wakeSucceeded.value_or(false));
        else if (message.type == L"committed") actions = v2StateMachine_->OnCommitted(now, message.sourceEndpointId, message.eventId, true, message.switchSucceeded.value_or(false));
        else if (message.type == L"cancelled") actions = v2StateMachine_->OnCancelled(now, message.sourceEndpointId, message.eventId, true, message.reason.value_or(L"cancelled"));
        ApplyV2Actions(std::move(actions));
    }

    bool Controller::HandleUnboundStatusProbe(V2Message const& message, DatagramSource const& source)
    {
        auto config = Config();
        std::vector<CollaborationProfile> candidates = config.EnabledCompleteProfiles();
        if (profileDetection_)
        {
            auto const& draft = profileDetection_->profile;
            auto inspection = profileDetection_->workingConfig.InspectProfile(draft.id);
            if (inspection.complete && draft.peerEndpointId.empty() && draft.peerProtocolVersion != 1)
            {
                auto existing = std::find_if(candidates.begin(), candidates.end(), [&](auto const& profile)
                { return EqualId(profile.id, draft.id); });
                if (existing == candidates.end()) candidates.push_back(draft); else *existing = draft;
            }
        }
        auto match = MatchUnboundStatusProbe(candidates, config.localEndpointId, source, message,
            static_cast<int64_t>(UdpPeer::TimestampNow()), NowMilliseconds(),
            [](CollaborationProfile const& profile, DatagramSource const& sender)
            { return UdpPeer::SourceMatches(sender, profile.peerHost, profile.peerPort); }, &v2ReplayCache_);
        if (match.status != UnboundProbeMatchStatus::Matched || !match.profileIndex) return false;
        auto const& profile = candidates[*match.profileIndex];
        try
        {
            auto now = static_cast<int64_t>(UdpPeer::TimestampNow());
            for (auto item = v2OutgoingMessages_.begin(); item != v2OutgoingMessages_.end();)
                if (now - item->second.timestamp > 30) item = v2OutgoingMessages_.erase(item); else ++item;
            auto cacheKey = L"unbound_status_response|" + message.eventId + L"|" + message.sourceEndpointId;
            auto cached = v2OutgoingMessages_.find(cacheKey);
            V2Message response;
            if (cached != v2OutgoingMessages_.end()) response = cached->second;
            else
            {
                response = CreateUnboundStatusResponse(message, config.localEndpointId, now,
                    GenerateV2Nonce(), profile.pairingCode);
                v2OutgoingMessages_.emplace(cacheKey, response);
            }
            peer_->SendRaw(SerializeV2Message(response), source.address, source.port, false);
            return true;
        }
        catch (...) { return false; }
    }

    void Controller::Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded)
    {
        if (disposed_ || !peer_ || !sideEffectGate_.AllowsSideEffects()) return;
        auto config = Config();
        if (!config.coordinationEnabled || config.pairingCode.size() < 8) return;
        if (type == L"status_probe") v1HealthProbe_.Begin(eventId, NowMilliseconds() + 10000);
        peer_->Send(PeerMessage{ 1, type, eventId, L"windows", L"mac", UdpPeer::TimestampNow(), config.pairingCode, wakeSucceeded },
            config.peerHost, config.port);
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
        auto now = static_cast<int64_t>(UdpPeer::TimestampNow());
        for (auto item = v2OutgoingMessages_.begin(); item != v2OutgoingMessages_.end();)
            if (now - item->second.timestamp > 30) item = v2OutgoingMessages_.erase(item); else ++item;
        auto cacheKey = action.type + L"|" + action.eventId + L"|" + action.endpointId;
        auto cached = v2OutgoingMessages_.find(cacheKey);
        V2Message message;
        if (cached != v2OutgoingMessages_.end()) message = cached->second;
        else
        {
            message.type = action.type; message.eventId = action.eventId; message.sourceEndpointId = config.localEndpointId;
            message.targetEndpointId = profile->peerEndpointId;
            message.sourcePlatform = L"windows"; message.timestamp = now; message.nonce = GenerateV2Nonce();
            if (!action.intent.empty()) message.intent = action.intent;
            if (action.wakeSucceeded) message.wakeSucceeded = action.wakeSucceeded;
            if (action.switchSucceeded) message.switchSucceeded = action.switchSucceeded;
            if (!action.reason.empty()) message.reason = action.reason;
            try
            {
                auto secret = NormalizeV2PairingSecret(profile->pairingCode);
                auto key = DeriveV2AuthenticationKey(secret, config.localEndpointId);
                message = SignV2Message(std::move(message), key);
            }
            catch (...) { return; }
            v2OutgoingMessages_.emplace(cacheKey, message);
        }
        peer_->SendRaw(SerializeV2Message(message), profile->peerHost, profile->peerPort,
            action.type != L"status_probe" && action.type != L"status_response");
    }

    void Controller::SendV2Probe(CollaborationProfile const& profile)
    {
        auto eventId = NewEventId();
        v2HealthProbes_[profile.peerEndpointId].Begin(eventId, NowMilliseconds() + 10000);
        SendV2({ V2Action::Kind::SendMessage, L"status_probe", eventId, profile.peerEndpointId });
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

    void Controller::BeginProfileDetection(AppConfig const& workingConfig, std::wstring const& profileId,
        std::function<void(ProfileDetectionResult const&)> completed)
    {
        if (disposed_) return;
        if (profileDetection_)
        {
            profileDetection_->session.Cancel();
            CompleteProfileDetection({ ProfileDetectionOutcome::NoResponse });
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
        profileDetection_->startedPeer = !peer_->IsRunning();
        if (profileDetection_->startedPeer) peer_->Start(workingConfig.listenPort);
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
        auto action = profileDetection_->session.Advance(NowMilliseconds(), NewEventId());
        auto startedV1 = action.kind == ProfileDetectionAction::Kind::SendV1Probe;
        ApplyProfileDetectionAction(std::move(action));
        if (!startedV1 || !profileDetection_ || profileDetection_->generation != generation) return;
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, generation]
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(ProfileDetectionSession::ProbeTimeoutMilliseconds));
            if (auto self = weak.lock(); self && !self->disposed_)
                self->Enqueue([weak, generation] { if (auto value = weak.lock()) value->AdvanceProfileDetection(generation); });
        }).detach();
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
        auto const& config = profileDetection_->workingConfig;
        auto const& profile = profileDetection_->profile;
        if (action.kind == ProfileDetectionAction::Kind::SendV1Probe)
        {
            peer_->Send(PeerMessage{ 1, L"status_probe", action.eventId, L"windows", L"mac",
                UdpPeer::TimestampNow(), profile.pairingCode, std::nullopt }, profile.peerHost, profile.peerPort);
            return;
        }
        if (action.kind != ProfileDetectionAction::Kind::SendV2Probe) return;
        V2Message message;
        message.type = L"status_probe";
        message.eventId = action.eventId;
        message.sourceEndpointId = config.localEndpointId;
        if (IsValidDisplayId(profile.peerEndpointId)) message.targetEndpointId = profile.peerEndpointId;
        message.sourcePlatform = L"windows";
        message.timestamp = static_cast<int64_t>(UdpPeer::TimestampNow());
        message.nonce = GenerateV2Nonce();
        try
        {
            auto secret = NormalizeV2PairingSecret(profile.pairingCode);
            auto key = DeriveV2AuthenticationKey(secret, config.localEndpointId);
            message = SignV2Message(std::move(message), key);
            peer_->SendRaw(SerializeV2Message(message), profile.peerHost, profile.peerPort, false);
        }
        catch (...)
        {
            CompleteProfileDetection({ ProfileDetectionOutcome::LocalConfigurationIncomplete });
        }
    }

    void Controller::CompleteProfileDetection(ProfileDetectionResult const& result)
    {
        if (!profileDetection_) return;
        auto completed = std::move(profileDetection_->completed);
        auto wasActive = profileDetectionActive_.load();
        profileDetection_->session.Cancel();
        profileDetection_.reset();
        profileDetectionReplayCache_.Clear();
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
                    if (self->profileDetectionActive_) { DdcControlBatchResult result; result.canceled = true; return result; }
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
                    if (self->profileDetectionActive_) { DdcControlBatchResult result; result.canceled = true; return result; }
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
            [weak](AppConfig const& config, std::wstring const& profileId,
                std::function<void(ProfileDetectionResult const&)> completed)
            {
                if (auto self = weak.lock()) self->BeginProfileDetection(config, profileId, std::move(completed));
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
