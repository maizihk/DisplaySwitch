#pragma once

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
        std::wstring redmiMonitorPath;
        std::wstring redmiNativeMonitorId;
        int redmiMacInput{ -1 };
        std::wstring dellMonitorPath;
        std::wstring dellNativeMonitorId;
        int dellMacInput{ -1 };
        bool startWithWindows{ false };

        bool HasUsbDeviceConfiguration() const noexcept;
        bool HasDisplayConfiguration() const noexcept;
        static AppConfig Load();
        void Save() const;
        static std::filesystem::path ConfigPath();
    };
}
