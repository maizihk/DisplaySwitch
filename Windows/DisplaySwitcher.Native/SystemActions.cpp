#include "pch.h"
#include "DdcBackends.h"
#include "Diagnostics.h"
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

    DdcEnumerationResult EnumerateDdcMonitors()
    {
        DdcBackendSet backends; DdcCancellationSource cancellation;
        auto backend = backends.Lookup(NativeDdcBackendKey);
        return backend ? backend->Enumerate(cancellation.Begin()) :
            DdcEnumerationResult{ false, DdcErrorKind::BackendUnavailable, L"Windows 原生 DDC 后端不可用", {}, false };
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config)
    {
        auto started = GetTickCount64();
        if (!config.HasDisplayConfiguration())
            return { false, L"显示器配置不完整，未执行切换" };
        DdcBackendSet backends; DdcCancellationSource cancellation; auto token = cancellation.Begin();
        auto result = ExecuteDisplayActions(config.displays, [&](DisplayConfig const& display)
        {
            auto backend = backends.Lookup(NativeDdcBackendKey);
            if (!backend) return ActionResult{ false, L"Windows 原生 DDC 后端不可用" };
            auto status = backend->Status();
            if (status.availability != DdcAvailability::Available)
                return ActionResult{ false, status.message.empty() ? L"Windows 原生 DDC 后端暂时不可用" : status.message };
            auto const& monitorId = display.nativeMonitorId;
            // The backend acquires a fresh handle set on each call. Retry exactly
            // once after an explicit native failure, without a fixed delay.
            auto write = WriteNativeWithOneRefresh(*backend, monitorId,
                DdcVcpCode::InputSource, display.macInput, token);
            return ActionResult{ write.success, write.message };
        });
        WriteDiagnostic("display.switch_complete success=" + std::to_string(result.success ? 1 : 0)
            + " count=" + std::to_string(config.displays.size())
            + " duration_ms=" + std::to_string(GetTickCount64() - started));
        return result;
    }
}
