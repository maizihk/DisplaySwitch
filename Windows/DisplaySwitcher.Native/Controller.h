#pragma once
#include "AppConfig.h"
#include "UdpPeer.h"

namespace DisplaySwitcher::Native
{
    class TrayIcon;
    class UsbWatcher;

    class Controller : public std::enable_shared_from_this<Controller>
    {
    public:
        static std::shared_ptr<Controller> Create(winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher,
            std::function<void()> exitApplication);
        ~Controller();
        void Dispose();
        void ShowError(std::wstring const& title, std::wstring const& message);

    private:
        Controller(winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher, std::function<void()> exitApplication);
        void Initialize();
        AppConfig Config() const;
        void ApplyConfiguration();
        void OnUsbPresenceChanged(bool present);
        void BeginOutgoingHandover();
        void CompleteOutgoing(std::wstring const& eventId);
        void CancelOutgoing();
        void HandlePeerMessage(PeerMessage const& message);
        void Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded);
        void ManualSwitch();
        void ShowSettings();
        void SetStatus(std::wstring const& text);
        void Enqueue(std::function<void()> action);
        static std::wstring NewEventId();

        winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher_{ nullptr };
        std::function<void()> exitApplication_;
        mutable std::mutex configMutex_;
        AppConfig config_;
        std::unique_ptr<TrayIcon> trayIcon_;
        std::unique_ptr<UdpPeer> peer_;
        std::unique_ptr<UsbWatcher> usbWatcher_;
        winrt::Microsoft::UI::Xaml::Window settingsWindow_{ nullptr };
        std::mutex stateMutex_;
        std::wstring outgoingEventId_;
        std::wstring incomingEventId_;
        double lastIncomingRequestTimestamp_{};
        std::atomic<uint64_t> outgoingGeneration_{};
        std::atomic<bool> disposed_{};
    };
}
