#pragma once
#include "AppConfig.h"
#include "HandoverStateMachine.h"
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
        void ApplyConfiguration(bool applyAutoStart = true);
        void EnterSafeStateAfterSaveFailure();
        void OnUsbPresenceChanged(bool present);
        void ApplyStateMachineActions(std::vector<StateMachineAction> actions);
        void AdvanceStateMachine();
        void SwitchToMac(std::optional<std::wstring> eventId, bool manual);
        void SwitchToProfile(std::wstring const& profileId);
        void StartPeerHealthCheck();
        void StopPeerHealthCheck();
        void HandlePeerMessage(PeerMessage const& message);
        void Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded);
        void SendRepeated(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded);
        void ManualSwitch(std::wstring const& profileId);
        void ShowSettings();
        void SetStatus(std::wstring const& text);
        void SetPeerConnectionStatus(std::wstring const& text, bool connected);
        void Enqueue(std::function<void()> action);
        static std::wstring NewEventId();

        winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher_{ nullptr };
        std::function<void()> exitApplication_;
        mutable std::mutex configMutex_;
        AppConfig config_;
        std::unique_ptr<TrayIcon> trayIcon_;
        std::unique_ptr<UdpPeer> peer_;
        std::unique_ptr<UsbWatcher> usbWatcher_;
        std::unique_ptr<HandoverStateMachine> stateMachine_;
        winrt::Microsoft::UI::Xaml::Window settingsWindow_{ nullptr };
        std::mutex stateMutex_;
        std::wstring peerConnectionStatus_{ L"协同未启用" };
        bool peerConnected_{};
        std::atomic<bool> disposed_{};
        RuntimeSafetyGate sideEffectGate_;
        std::jthread peerHealthThread_;
    };
}
