#pragma once
#include "AppConfig.h"

namespace DisplaySwitcher::Native
{
    struct ActionResult
    {
        bool success{};
        std::wstring error;
    };

    bool WakeDisplay();
    ActionResult SwitchDisplaysToMac(AppConfig const& config);
}
