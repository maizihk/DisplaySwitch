#include "pch.h"
#include "DdcBackends.h"
#include "Diagnostics.h"
#include "SystemActions.h"

namespace
{
    using namespace DisplaySwitcher::Native;

    ActionResult RunWithRetry(std::function<ActionResult()> const& action)
    {
        ActionResult result;
        for (int attempt = 0; attempt < 2; ++attempt)
        {
            result = action();
            if (result.success) break;
            if (attempt == 0) std::this_thread::sleep_for(std::chrono::milliseconds(150));
        }
        return result;
    }
}

namespace DisplaySwitcher::Native
{
    bool WakeDisplay()
    {
        constexpr auto required = ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
        return SetThreadExecutionState(required) != 0;
    }

    std::vector<DdcMonitorInfo> EnumerateDdcMonitors()
    {
        AppConfig config; config.displayControlBackend = L"native_ddc";
        DdcBackendSet backends(config); DdcCancellationSource cancellation;
        auto backend = backends.Lookup(L"native_ddc");
        return backend ? backend->Enumerate(cancellation.Begin()) : std::vector<DdcMonitorInfo>{};
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config)
    {
        if (!config.HasDisplayConfiguration())
            return { false, L"显示器配置不完整，未执行切换" };
        DdcBackendSet backends(config); DdcCancellationSource cancellation; auto token = cancellation.Begin();
        auto result = ExecuteDisplayActions(config.displays, [&](DisplayConfig const& display)
        {
            return RunWithRetry([&]
            {
                auto backendKey = DdcControlService::BackendKey(config, display);
                auto backend = backends.Lookup(backendKey);
                if (!backend) return ActionResult{ false, L"显示器后端不受支持" };
                auto status = backend->Status();
                if (status.availability != DdcAvailability::Available)
                    return ActionResult{ false, status.message.empty() ? L"显示器后端暂时不可用" : status.message };
                auto write = backend->Write(display.BackendMonitorId(backendKey), DdcVcpCode::InputSource,
                    display.macInput, token);
                return ActionResult{ write.success, write.message };
            });
        });
        WriteDiagnostic("display.switch_complete success=" + std::to_string(result.success ? 1 : 0)
            + " count=" + std::to_string(config.displays.size()));
        return result;
    }
}
