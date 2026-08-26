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
        int usbVendorId{ 0x0BDA };
        int usbProductId{ 0x5409 };
        std::wstring usbName{ L"4-Port USB 2.0 Hub" };
        std::wstring displayControlBackend{ L"control_my_monitor" };
        std::wstring controlMyMonitorPath{ LR"(D:\Soft\ControlMyMonitor\ControlMyMonitor.exe)" };
        std::wstring redmiMonitorPath{ LR"(\\.\DISPLAY2\Monitor0)" };
        std::wstring redmiNativeMonitorId;
        int redmiMacInput{ 16 };
        std::wstring dellMonitorPath{ LR"(\\.\DISPLAY1\Monitor0)" };
        std::wstring dellNativeMonitorId;
        int dellMacInput{ 17 };
        bool startWithWindows{ false };

        static AppConfig Load();
        void Save() const;
        static std::filesystem::path ConfigPath();
    };
}
