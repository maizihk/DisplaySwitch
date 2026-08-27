#pragma once
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    struct AppConfig
    {
        bool usbAutomationEnabled{ false };
        bool coordinationEnabled{ false };
        int usbVendorId{ -1 };
        int usbProductId{ -1 };
        std::wstring usbName;
        std::wstring peerHost;
        int peerPort{ 49731 };
        // Deprecated compatibility alias kept for current C++ call-sites and settings
        // pages that still write `port`. Kept synchronized with `peerPort` on load/save.
        int port{ 49731 };
        std::wstring pairingCode;

        std::wstring displayControlBackend;
        std::wstring controlMyMonitorPath;
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
        std::vector<std::wstring> OrderedDisplayIds() const;
        bool IsProfileDisplayMappingComplete(std::wstring const& profileId) const noexcept;
        int PeerInputForDisplay(std::wstring const& profileId, std::wstring const& displayId, int fallback = -1) const noexcept;
        ProfileInspectionResult InspectProfile(std::wstring const& profileId,
            std::wstring const& observedEndpointId = {}, std::optional<int> observedProtocolVersion = std::nullopt) const;
        ProfileDisplaySelection SelectProfileDisplays(std::wstring const& profileId) const;
        static bool IsValidPairingCode(std::wstring const& code, bool requireNormalized = false);
        static std::wstring NormalizeNfc(std::wstring const& text);
        static bool IsValidConfigurationPath(std::wstring const& path) noexcept;
        static AppConfig Load();
        static AppConfig LoadFromPath(std::filesystem::path const& path);
        void Save() const;
        void SaveToPath(std::filesystem::path const& path) const;
        static std::filesystem::path ConfigPath();
    };
}
