#include "pch.h"
#include "Diagnostics.h"
#include "InputSourceControl.h"

namespace DisplaySwitcher::Native
{
    InputSourceWriteResult WriteInputSourceWithOneRefresh(IInputSourceTransport& transport,
        std::wstring const& monitorId, int value, DdcCancellationToken const& cancellation)
    {
        auto result = transport.WriteInputSource(monitorId, value, cancellation);
        if (!result.success && !cancellation.IsCanceled()
            && (result.error == DdcErrorKind::WriteFailed || result.error == DdcErrorKind::MonitorUnavailable))
            result = transport.WriteInputSource(monitorId, value, cancellation);
        return result;
    }

    InputSourceSwitchService::InputSourceSwitchService(IInputSourceTransport* transport,
        std::function<bool()> sideEffectsAllowed) :
        transport_(transport), sideEffectsAllowed_(std::move(sideEffectsAllowed))
    {
    }

    bool InputSourceSwitchService::Allowed(AppConfig const& config,
        DdcCancellationToken const& cancellation) const
    {
        return !config.displayConfigurationSafeMode && !cancellation.IsCanceled()
            && (!sideEffectsAllowed_ || sideEffectsAllowed_());
    }

    ActionResult InputSourceSwitchService::SwitchDisplaysToMac(AppConfig const& config,
        DdcCancellationToken const& cancellation, DisplayActionObserver observer) const
    {
        auto started = GetTickCount64();
        if (!config.HasDisplayConfiguration())
            return { false, L"显示器配置不完整，未执行切换" };
        if (!Allowed(config, cancellation))
            return { false, L"输入源切换已取消或被安全状态阻断" };

        std::wstring errors;
        bool topologyChanged{};
        size_t completed{};
        for (auto const& display : config.displays)
        {
            if (topologyChanged || !Allowed(config, cancellation)) break;
            ActionResult item;
            DdcErrorKind itemError{ DdcErrorKind::None };
            if (!IsDisplayDdcResolved(display))
            {
                itemError = display.bindingStatus == DisplayBindingStatus::Ambiguous
                    || display.bindingStatus == DisplayBindingStatus::NeedsConfirmation
                    ? DdcErrorKind::AmbiguousMonitor : DdcErrorKind::MonitorUnavailable;
                item = { false, display.bindingMessage.empty()
                    ? L"显示器未唯一绑定到当前物理目标" : display.bindingMessage };
            }
            else if (!transport_)
            {
                itemError = DdcErrorKind::BackendUnavailable;
                item = { false, L"Windows 原生输入源传输不可用" };
            }
            else
            {
                auto status = transport_->Status();
                if (status.availability != DdcAvailability::Available)
                {
                    itemError = status.availability == DdcAvailability::Unsupported
                        ? DdcErrorKind::Unsupported : DdcErrorKind::BackendUnavailable;
                    item = { false, status.message.empty()
                        ? L"Windows 原生输入源传输暂时不可用" : status.message };
                }
                else
                {
                    auto write = Allowed(config, cancellation)
                        ? WriteInputSourceWithOneRefresh(*transport_, display.nativeMonitorId,
                            display.macInput, cancellation)
                        : InputSourceWriteResult{ false, DdcErrorKind::Canceled, L"操作已取消" };
                    auto currentGeneration = transport_->TopologyGeneration();
                    topologyChanged = write.error == DdcErrorKind::TopologyChanged
                        || (write.success && write.topologyGeneration != 0
                            && write.topologyGeneration != currentGeneration);
                    itemError = topologyChanged ? DdcErrorKind::TopologyChanged : write.error;
                    item = topologyChanged
                        ? ActionResult{ false, L"显示拓扑已变化，旧句柄结果已丢弃" }
                        : ActionResult{ write.success, write.message };
                }
            }
            if (observer) observer(display, item.success, item.success ? DdcErrorKind::None : itemError);
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
        else if (!Allowed(config, cancellation) && completed < config.displays.size())
        {
            if (!errors.empty()) errors += L"；";
            errors += L"输入源切换已取消，剩余操作已停止";
        }
        auto result = ActionResult{ errors.empty() && completed == config.displays.size(), std::move(errors) };
        WriteDiagnostic("display.switch_complete success=" + std::to_string(result.success ? 1 : 0)
            + " count=" + std::to_string(completed)
            + " duration_ms=" + std::to_string(GetTickCount64() - started));
        return result;
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config, IInputSourceTransport* transport,
        DisplayActionObserver observer)
    {
        DdcCancellationSource cancellation;
        return InputSourceSwitchService(transport).SwitchDisplaysToMac(
            config, cancellation.Begin(), std::move(observer));
    }
}
