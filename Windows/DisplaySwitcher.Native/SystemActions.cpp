#include "pch.h"
#include "DdcBackends.h"
#include "SystemActions.h"

namespace
{
    using namespace DisplaySwitcher::Native;
}

namespace DisplaySwitcher::Native
{
    bool WakeDisplay()
    {
        constexpr auto required = ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
        return SetThreadExecutionState(required) != 0;
    }

    DdcEnumerationResult EnumerateDdcMonitors(IDdcBackend* backend)
    {
        DdcBackendSet ownedBackends;
        DdcCancellationSource cancellation;
        if (!backend) backend = ownedBackends.Lookup(NativeDdcBackendKey);
        return backend ? backend->Enumerate(cancellation.Begin()) :
            DdcEnumerationResult{ false, DdcErrorKind::BackendUnavailable, L"Windows 原生 DDC 后端不可用", {}, false };
    }

}
