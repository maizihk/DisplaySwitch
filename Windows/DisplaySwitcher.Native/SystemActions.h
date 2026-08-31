#pragma once
#include "AppConfig.h"
#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    bool WakeDisplay();
    DdcEnumerationResult EnumerateDdcMonitors(IDdcBackend* backend = nullptr);
    using DisplayActionObserver = std::function<void(DisplayConfig const&, bool, DdcErrorKind)>;
    ActionResult SwitchDisplaysToMac(AppConfig const& config, IDdcBackend* backend = nullptr,
        DisplayActionObserver observer = {});
}
