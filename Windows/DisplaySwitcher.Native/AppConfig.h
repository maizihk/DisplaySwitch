#pragma once
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    enum class AppConfigSaveFaultForTesting
    {
        None,
        TemporaryWrite,
        ReadbackMismatch,
        AtomicReplace,
    };

    class RuntimeSafetyGate final
    {
    public:
        explicit RuntimeSafetyGate(bool blocked = false) noexcept : blocked_(blocked) {}
        void Block() noexcept { blocked_.store(true, std::memory_order_release); }
        void Allow() noexcept { blocked_.store(false, std::memory_order_release); }
        bool AllowsSideEffects() const noexcept { return !blocked_.load(std::memory_order_acquire); }

    private:
        std::atomic<bool> blocked_{};
    };

    struct AppConfig
    {
        UsbSwitchConfig usbSwitch;

        std::wstring displayControlBackend;
        std::wstring controlMyMonitorPath;
        bool linkAllDisplays{ false };
        std::vector<DisplayConfig> displays;
        std::wstring localEndpointId;
        std::wstring localDeviceName{ L"本机" };
        int listenPort{ 49731 };
        std::vector<CollaborationProfile> collaborationProfiles;
        bool startWithWindows{ false };
        bool displayConfigurationSafeMode{ false };

        bool HasUsbDeviceConfiguration() const noexcept;
        bool HasDisplayConfiguration(std::wstring const& profileId = {}) const noexcept;
        bool HasCollaborationProfile(std::wstring const& profileId) const noexcept;
        CollaborationProfile const* FindCollaborationProfile(std::wstring const& profileId) const noexcept;
        CollaborationProfile* FindCollaborationProfile(std::wstring const& profileId) noexcept;
        std::vector<CollaborationProfile> ReadonlyEnabledProfiles() const;
        std::vector<CollaborationProfile> EnabledCompleteProfiles() const;
        std::vector<CollaborationProfile> UnboundBootstrapProfiles() const;
        std::optional<int> V2ListenerPort() const;
        std::vector<std::wstring> OrderedDisplayIds() const;
        bool IsProfileDisplayMappingComplete(std::wstring const& profileId) const noexcept;
        int PeerInputForDisplay(std::wstring const& profileId, std::wstring const& displayId, int fallback = -1) const noexcept;
        std::optional<int> UsbInputForDisplay(std::wstring const& displayId) const noexcept;
        ProfileInspectionResult InspectProfile(std::wstring const& profileId,
            std::wstring const& observedEndpointId = {}, std::optional<int> observedProtocolVersion = std::nullopt) const;
        ProfileDisplaySelection SelectProfileDisplays(std::wstring const& profileId) const;
        static bool IsValidPairingCode(std::wstring const& code, bool requireNormalized = false);
        static std::wstring NormalizeNfc(std::wstring const& text);
        static bool IsValidConfigurationPath(std::wstring const& path) noexcept;
        static AppConfig Load(bool* firstRun = nullptr);
        static AppConfig LoadFromPath(std::filesystem::path const& path, bool* firstRun = nullptr);
        void EnterSafeState() noexcept;
        void Save() const;
        void SaveToPath(std::filesystem::path const& path,
            AppConfigSaveFaultForTesting fault = AppConfigSaveFaultForTesting::None) const;
        static std::filesystem::path ConfigPath();
    };
}
