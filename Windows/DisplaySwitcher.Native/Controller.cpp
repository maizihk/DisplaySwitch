#include "pch.h"
#include "Controller.h"
#include "AutoStart.h"
#include "SettingsWindow.xaml.h"
#include "SystemActions.h"
#include "TrayIcon.h"
#include "UsbWatcher.h"

using namespace winrt;

namespace
{
    bool WaitUnlessCancelled(std::atomic<uint64_t> const& generation, uint64_t expected, int milliseconds)
    {
        for (int elapsed = 0; elapsed < milliseconds; elapsed += 25)
        {
            if (generation.load() != expected) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds((std::min)(25, milliseconds - elapsed)));
        }
        return generation.load() == expected;
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
        std::weak_ptr<Controller> weak = shared_from_this();
        auto config = Config();
        usbWatcher_ = std::make_unique<UsbWatcher>(config.usbVendorId, config.usbProductId, [weak](bool present)
        {
            if (auto self = weak.lock()) self->Enqueue([weak, present] { if (auto value = weak.lock()) value->OnUsbPresenceChanged(present); });
        });
        peer_ = std::make_unique<UdpPeer>([weak](PeerMessage const& message)
        {
            if (auto self = weak.lock()) self->Enqueue([weak, message] { if (auto value = weak.lock()) value->HandlePeerMessage(message); });
        }, [weak](std::wstring const& error)
        {
            if (auto self = weak.lock()) self->SetStatus(error);
        });
        trayIcon_ = std::make_unique<TrayIcon>(
            [weak] { if (auto self = weak.lock()) self->ShowSettings(); },
            [weak] { if (auto self = weak.lock()) self->ManualSwitch(); },
            [weak] { if (auto self = weak.lock()) { auto exit = self->exitApplication_; if (exit) exit(); } });
        ApplyConfiguration();
    }

    Controller::~Controller() { Dispose(); }

    AppConfig Controller::Config() const
    {
        std::scoped_lock lock(configMutex_);
        return config_;
    }

    void Controller::ApplyConfiguration()
    {
        auto config = Config();
        peer_->Stop();
        usbWatcher_->Reconfigure(config.usbVendorId, config.usbProductId);
        if (config.coordinationEnabled) peer_->Start(config.port);
        try { ApplyAutoStart(config.startWithWindows); }
        catch (hresult_error const& error) { ShowError(L"登录启动设置失败", error.message().c_str()); }
        wchar_t ids[16]{}; swprintf_s(ids, L"%04X:%04X", config.usbVendorId, config.usbProductId);
        SetStatus(config.coordinationEnabled ? L"协同已开启 · USB " + std::wstring(ids) : L"协同未开启");
    }

    void Controller::OnUsbPresenceChanged(bool present)
    {
        auto config = Config();
        if (!config.coordinationEnabled) return;
        if (present)
        {
            CancelOutgoing();
            auto woke = WakeDisplay();
            Send(L"usb_present", NewEventId(), woke);
            std::wstring incoming;
            { std::scoped_lock lock(stateMutex_); incoming = incomingEventId_; }
            if (!incoming.empty()) Send(L"usb_attached_and_awake", incoming, woke);
            SetStatus(L"USB 已接入 Windows，等待切屏");
            return;
        }
        SetStatus(L"USB 已离开 Windows，等待确认…");
        auto generation = outgoingGeneration_.load();
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, generation]
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(800));
            if (auto self = weak.lock(); self && !self->disposed_ && self->outgoingGeneration_.load() == generation && !self->usbWatcher_->IsPresent())
                self->Enqueue([weak] { if (auto value = weak.lock()) value->BeginOutgoingHandover(); });
        }).detach();
    }

    void Controller::BeginOutgoingHandover()
    {
        CancelOutgoing();
        auto eventId = NewEventId();
        auto generation = outgoingGeneration_.load();
        { std::scoped_lock lock(stateMutex_); outgoingEventId_ = eventId; }
        std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, eventId, generation]
        {
            for (int attempt = 0; attempt < 5; ++attempt)
            {
                auto self = weak.lock(); if (!self || self->disposed_ || self->outgoingGeneration_.load() != generation) return;
                self->Send(L"handover_request", eventId, std::nullopt);
                if (!WaitUnlessCancelled(self->outgoingGeneration_, generation, 450)) return;
            }
            auto self = weak.lock(); if (!self || !WaitUnlessCancelled(self->outgoingGeneration_, generation, 250)) return;
            self->Enqueue([weak, eventId] { if (auto value = weak.lock()) value->CompleteOutgoing(eventId); });
        }).detach();
    }

    void Controller::CompleteOutgoing(std::wstring const& eventId)
    {
        {
            std::scoped_lock lock(stateMutex_);
            if (outgoingEventId_ != eventId) return;
            outgoingEventId_.clear();
        }
        ++outgoingGeneration_;
        SetStatus(L"正在切换显示器到 Mac…");
        auto config = Config(); std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, config, eventId]
        {
            auto result = SwitchDisplaysToMac(config);
            if (auto self = weak.lock(); self && !self->disposed_)
            {
                self->Send(L"committed", eventId, result.success);
                self->Enqueue([weak, result]
                {
                    if (auto value = weak.lock())
                    {
                        value->SetStatus(result.success ? L"已切换到 Mac" : L"部分切换失败：" + result.error);
                        if (!result.success) value->ShowError(L"显示器切换失败", result.error.empty() ? L"未知错误" : result.error);
                    }
                });
            }
        }).detach();
    }

    void Controller::CancelOutgoing()
    {
        ++outgoingGeneration_;
        std::scoped_lock lock(stateMutex_); outgoingEventId_.clear();
    }

    void Controller::HandlePeerMessage(PeerMessage const& message)
    {
        auto config = Config();
        if (!config.coordinationEnabled || message.version != 1 || message.pairingCode != config.pairingCode ||
            message.source != L"mac" || message.target != L"windows" || std::abs(UdpPeer::TimestampNow() - message.timestamp) > 10) return;
        if (message.type == L"handover_request")
        {
            if (message.timestamp < lastIncomingRequestTimestamp_) return;
            lastIncomingRequestTimestamp_ = message.timestamp;
            { std::scoped_lock lock(stateMutex_); incomingEventId_ = message.eventId; }
            auto woke = WakeDisplay();
            if (usbWatcher_->IsPresent()) Send(L"usb_attached_and_awake", message.eventId, woke);
        }
        else if (message.type == L"usb_present")
        {
            std::wstring outgoing; { std::scoped_lock lock(stateMutex_); outgoing = outgoingEventId_; }
            if (!outgoing.empty()) CompleteOutgoing(outgoing);
        }
        else if (message.type == L"usb_attached_and_awake")
        {
            std::wstring outgoing; { std::scoped_lock lock(stateMutex_); outgoing = outgoingEventId_; }
            if (outgoing == message.eventId) CompleteOutgoing(message.eventId);
        }
        else if (message.type == L"committed")
        {
            { std::scoped_lock lock(stateMutex_); if (incomingEventId_ == message.eventId) incomingEventId_.clear(); }
            SetStatus(L"Mac 已完成显示器切换");
        }
    }

    void Controller::Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded)
    {
        if (disposed_ || !peer_) return;
        auto config = Config();
        peer_->Send(PeerMessage{ 1, type, eventId, L"windows", L"mac", UdpPeer::TimestampNow(), config.pairingCode, wakeSucceeded },
            config.peerHost, config.port);
    }

    void Controller::ManualSwitch()
    {
        SetStatus(L"正在手动切换显示器到 Mac…");
        auto config = Config(); std::weak_ptr<Controller> weak = shared_from_this();
        std::thread([weak, config]
        {
            auto result = SwitchDisplaysToMac(config);
            if (auto self = weak.lock()) self->Enqueue([weak, result]
            {
                if (auto value = weak.lock())
                {
                    value->SetStatus(result.success ? L"已手动切换到 Mac" : L"切换失败：" + result.error);
                    if (!result.success) value->ShowError(L"显示器切换失败", result.error.empty() ? L"未知错误" : result.error);
                }
            });
        }).detach();
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
            [weak](AppConfig const& config)
            {
                if (auto self = weak.lock())
                {
                    try { config.Save(); }
                    catch (...) { self->ShowError(L"保存设置失败", L"无法写入设置文件。"); return; }
                    { std::scoped_lock lock(self->configMutex_); self->config_ = config; }
                    self->ApplyConfiguration();
                }
            },
            [weak] { if (auto self = weak.lock()) self->settingsWindow_ = nullptr; });
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
        CancelOutgoing();
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
