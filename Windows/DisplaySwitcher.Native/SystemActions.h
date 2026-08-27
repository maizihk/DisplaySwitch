#pragma once
#include "AppConfig.h"
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    bool WakeDisplay();
    std::vector<DdcMonitorInfo> EnumerateDdcMonitors();
    ActionResult SwitchDisplaysToMac(AppConfig const& config);
}
