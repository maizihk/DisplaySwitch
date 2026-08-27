#pragma once
#include "AppConfig.h"
#include "HandoverStateMachine.h"
#include "UdpPeer.h"
#include "V2Protocol.h"
#include "V2StateMachine.h"

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
        void BeginUsbLearning();
        void EndUsbLearning();
        bool AllowsSideEffects(uint64_t generation) const noexcept;
        void OnUsbPresenceChanged(bool present);
        void ApplyStateMachineActions(std::vector<StateMachineAction> actions);
        void ApplyV2Actions(std::vector<V2Action> actions);
        void AdvanceStateMachine();
        void SwitchToMac(std::optional<std::wstring> eventId, bool manual);
        void SwitchToProfile(std::wstring const& profileId, std::optional<std::wstring> eventId = std::nullopt);
        void StartPeerHealthCheck();
        void StopPeerHealthCheck();
        void HandlePeerMessage(PeerMessage const& message);
        void HandleDatagram(std::string const& datagram);
        void Send(std::wstring const& type, std::wstring const& eventId, std::optional<bool> wakeSucceeded);
        void SendV2(V2Action const& action);
        void SendV2Probe(CollaborationProfile const& profile);
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
        std::unique_ptr<V2StateMachine> v2StateMachine_;
        V2ReplayCache v2ReplayCache_;
        std::map<std::wstring, V2Message> v2OutgoingMessages_;
        std::map<std::wstring, int64_t> v2PeerLastSeenMs_;
        winrt::Microsoft::UI::Xaml::Window settingsWindow_{ nullptr };
        std::mutex stateMutex_;
        std::wstring peerConnectionStatus_{ L"协同未启用" };
        bool peerConnected_{};
        std::atomic<bool> disposed_{};
        RuntimeSafetyGate sideEffectGate_;
        std::atomic<uint64_t> sideEffectGeneration_{ 1 };
        std::atomic<bool> usbLearningActive_{};
        std::jthread peerHealthThread_;
    };
}
