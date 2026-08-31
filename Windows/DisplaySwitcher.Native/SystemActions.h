#pragma once
#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    bool WakeDisplay();
    DdcEnumerationResult EnumerateDdcMonitors(IDdcBackend* backend = nullptr);
}
