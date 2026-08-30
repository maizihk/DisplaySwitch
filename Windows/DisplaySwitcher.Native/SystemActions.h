#pragma once
#include "AppConfig.h"
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    bool WakeDisplay();
    DdcEnumerationResult EnumerateDdcMonitors(IDdcBackend* backend = nullptr);
    ActionResult SwitchDisplaysToMac(AppConfig const& config, IDdcBackend* backend = nullptr);
}
