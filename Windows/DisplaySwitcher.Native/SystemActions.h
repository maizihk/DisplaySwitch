#pragma once
#include "AppConfig.h"

namespace DisplaySwitcher::Native
{
    struct ActionResult
    {
        bool success{};
        std::wstring error;
    };

    struct DdcMonitorInfo
    {
        std::wstring id;
        std::wstring displayName;
        std::wstring gdiName;
    };

    bool WakeDisplay();
    std::vector<DdcMonitorInfo> EnumerateDdcMonitors();
    ActionResult SwitchDisplaysToMac(AppConfig const& config);
}
