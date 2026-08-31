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

    DdcEnumerationResult EnumerateDdcMonitors(IDdcBackend* backend)
    {
        DdcBackendSet ownedBackends;
        DdcCancellationSource cancellation;
        if (!backend) backend = ownedBackends.Lookup(NativeDdcBackendKey);
        return backend ? backend->Enumerate(cancellation.Begin()) :
            DdcEnumerationResult{ false, DdcErrorKind::BackendUnavailable, L"Windows 原生 DDC 后端不可用", {}, false };
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config, IDdcBackend* backend, DisplayActionObserver observer)
    {
        auto started = GetTickCount64();
        if (!config.HasDisplayConfiguration())
            return { false, L"显示器配置不完整，未执行切换" };
        DdcBackendSet ownedBackends;
        DdcCancellationSource cancellation;
        auto token = cancellation.Begin();
        if (!backend) backend = ownedBackends.Lookup(NativeDdcBackendKey);
        std::wstring errors;
        bool topologyChanged{};
        size_t completed{};
        for (auto const& display : config.displays)
        {
            if (topologyChanged) break;
            ActionResult item;
            if (!IsDisplayDdcResolved(display))
                item = { false, display.bindingMessage.empty() ? L"显示器未唯一绑定到当前物理目标" : display.bindingMessage };
            else if (!backend)
            {
                item = { false, L"Windows 原生 DDC 后端不可用" };
            }
            else
            {
                auto status = backend->Status();
                if (status.availability != DdcAvailability::Available)
                    item = { false, status.message.empty() ? L"Windows 原生 DDC 后端暂时不可用" : status.message };
                else
                {
                    auto capabilities = backend->Capabilities(display.nativeMonitorId, token);
                    if (!capabilities.CanWrite(DdcVcpCode::InputSource))
                    {
                        item = { false, capabilities.status.message.empty()
                            ? L"显示器输入源控制当前不可用" : capabilities.status.message };
                    }
                    else
                    {
                        auto generation = backend->TopologyGeneration();
                        auto write = WriteNativeWithOneRefresh(*backend, display.nativeMonitorId,
                            DdcVcpCode::InputSource, display.macInput, token);
                        topologyChanged = backend->TopologyGeneration() != generation
                            || (write.success && write.topologyGeneration != 0
                                && write.topologyGeneration != backend->TopologyGeneration());
                        item = topologyChanged
                            ? ActionResult{ false, L"显示拓扑已变化，旧句柄结果已丢弃" }
                            : ActionResult{ write.success, write.message };
                    }
                }
            }
            if (observer)
            {
                auto error = item.success ? DdcErrorKind::None :
                    (display.bindingStatus == DisplayBindingStatus::Ambiguous ? DdcErrorKind::AmbiguousMonitor :
                    (display.bindingStatus == DisplayBindingStatus::Offline ? DdcErrorKind::MonitorUnavailable : DdcErrorKind::WriteFailed));
                observer(display, item.success, error);
            }
            ++completed;
            if (!item.success)
            {
                if (!errors.empty()) errors += L"；";
                errors += (display.name.empty() ? L"显示器" : display.name) + L"：" + item.error;
            }
        }
        if (topologyChanged && completed < config.displays.size())
        {
            if (!errors.empty()) errors += L"；";
            errors += L"显示拓扑已变化，剩余操作已停止";
        }
        auto result = ActionResult{ errors.empty() && completed == config.displays.size(), std::move(errors) };
        WriteDiagnostic("display.switch_complete success=" + std::to_string(result.success ? 1 : 0)
            + " count=" + std::to_string(completed)
            + " duration_ms=" + std::to_string(GetTickCount64() - started));
        return result;
    }
}
