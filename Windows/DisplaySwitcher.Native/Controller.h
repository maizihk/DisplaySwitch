#pragma once
#include "AppConfig.h"
#include "DdcControl.h"
#include "DdcBackends.h"
#include "DiagnosticReport.h"
#include "ProfileDetection.h"
#include "UdpPeer.h"
#include "V2Protocol.h"
#include "V2StateMachine.h"
#include "UsbSwitchCoordinator.h"

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
        void ApplyUsbActions(std::vector<UsbSwitchAction> actions);
        void WakeDisplayCoalesced(std::vector<UsbSwitchAction> const& actions);
        void SendUsbWakeDisplay();
        void ApplyV2Actions(std::vector<V2Action> actions);
        void AdvanceStateMachine();
        void SwitchToProfile(std::wstring const& profileId, std::optional<std::wstring> eventId = std::nullopt);
        void StartPeerHealthCheck();
        void StopPeerHealthCheck();
        void HandleDatagram(UdpPeer::Datagram const& datagram);
        void HandleValidatedDatagram(V2Message const& message, std::wstring const& profileId,
            V2ValidationResult const& validation, uint64_t configurationGeneration);
        bool HandleUnboundStatusProbe(V2Message const& message, DatagramSource const& source,
            AppConfig const& config, std::vector<CollaborationProfile> const& candidates,
            uint64_t configurationGeneration);
        void CheckNetworkAccess(AppConfig const& workingConfig,
            std::function<void(bool, std::wstring const&)> completed);
        void BeginProfileDetection(AppConfig const& workingConfig, std::wstring const& profileId,
            std::function<void(ProfileDetectionResult const&)> completed);
        void AdvanceProfileDetection(uint64_t generation);
        void ApplyProfileDetectionAction(ProfileDetectionAction action);
        void CompleteProfileDetection(ProfileDetectionResult const& result);
        void SendV2(V2Action const& action);
        void SendV2Probe(CollaborationProfile const& profile);
        void ManualSwitch(std::wstring const& profileId);
        bool EnsurePeerListening(int port);
        bool IsPeerListening(int port) const;
        void WriteTrayDdc(std::wstring const& displayId, DdcVcpCode code, int value);
        void ProcessTrayDdcWrites();
        void RefreshTrayDdcControls();
        DiagnosticSnapshot BuildDiagnosticSnapshot();
        void OnDisplayTopologyChanged();
        void ShowSettings();
        void SetStatus(std::wstring const& text);
        void SetPeerConnectionStatus(std::wstring const& text, bool connected);
        void Enqueue(std::function<void()> action);
        static std::wstring NewEventId();

        winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher_{ nullptr };
        std::function<void()> exitApplication_;
        mutable std::mutex configMutex_;
        bool firstRun_{};
        AppConfig config_;
        std::unique_ptr<TrayIcon> trayIcon_;
        std::unique_ptr<UdpPeer> peer_;
        std::unique_ptr<UsbWatcher> usbWatcher_;
        std::unique_ptr<UsbSwitchCoordinator> usbSwitchCoordinator_;
        std::unique_ptr<V2StateMachine> v2StateMachine_;
        V2ReplayCache v2ReplayCache_;
        V2AuthenticationKeyCache v2KeyCache_;
        std::mutex v2OutgoingMutex_;
        std::map<std::wstring, V2Message> v2OutgoingMessages_;
        std::map<std::wstring, int64_t> v2PeerLastSeenMs_;
        DiagnosticHeartbeatTracker diagnosticHeartbeats_;
        std::map<std::wstring, PendingStatusProbe> v2HealthProbes_;
        struct PendingProfileDetection
        {
            ProfileDetectionSession session;
            AppConfig workingConfig;
            CollaborationProfile profile;
            std::function<void(ProfileDetectionResult const&)> completed;
            uint64_t generation{};
        };
        std::optional<PendingProfileDetection> profileDetection_;
        V2ReplayCache profileDetectionReplayCache_;
        std::atomic<bool> profileDetectionActive_{};
        std::atomic<uint64_t> profileDetectionGeneration_{};
        ProfileDetectionAsyncOperation profileDetectionProbeOperation_;
        std::atomic<uint64_t> configurationGeneration_{ 1 };
        std::atomic<bool> networkAccessPrepared_{};
        winrt::Microsoft::UI::Xaml::Window settingsWindow_{ nullptr };
        std::mutex stateMutex_;
        std::wstring peerConnectionStatus_{ L"协同未启用" };
        bool peerConnected_{};
        std::atomic<bool> disposed_{};
        mutable std::mutex peerLifecycleMutex_;
        RuntimeSafetyGate sideEffectGate_;
        std::atomic<uint64_t> sideEffectGeneration_{ 1 };
        std::atomic<bool> usbLearningActive_{};
        std::jthread peerHealthThread_;
        DdcWriteQueue trayDdcWrites_;
        DdcBackendSet ddcBackends_;
        AboutInfo aboutInfo_{ PublicAboutInfo() };
        std::shared_ptr<DisplayOperationTracker> displayDiagnostics_{ std::make_shared<DisplayOperationTracker>() };
        DiagnosticAliasRegistry diagnosticAliases_;
    };
}
