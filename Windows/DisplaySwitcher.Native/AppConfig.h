#pragma once
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    struct AppConfig
    {
        bool usbAutomationEnabled{ false };
        bool coordinationEnabled{ false };
        std::wstring peerHost;
        int port{ 49731 };
        std::wstring pairingCode;
        int usbVendorId{ -1 };
        int usbProductId{ -1 };
        std::wstring usbName;
        std::wstring displayControlBackend;
        std::wstring controlMyMonitorPath;
        std::vector<DisplayConfig> displays;
        bool startWithWindows{ false };
        bool displayConfigurationSafeMode{ false };

        bool HasUsbDeviceConfiguration() const noexcept;
        bool HasDisplayConfiguration() const noexcept;
        static AppConfig Load();
        static AppConfig LoadFromPath(std::filesystem::path const& path);
        void Save() const;
        void SaveToPath(std::filesystem::path const& path) const;
        static std::filesystem::path ConfigPath();
    };
}
