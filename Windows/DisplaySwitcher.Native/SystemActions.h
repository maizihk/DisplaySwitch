#pragma once
#include "AppConfig.h"
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    bool WakeDisplay();
    DdcEnumerationResult EnumerateDdcMonitors();
    ActionResult SwitchDisplaysToMac(AppConfig const& config);
}
