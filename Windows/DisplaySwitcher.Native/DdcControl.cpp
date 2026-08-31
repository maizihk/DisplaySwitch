#include "pch.h"
#include "DdcControl.h"

namespace
{
    using namespace DisplaySwitcher::Native;

    bool Contains(std::vector<DdcVcpCode> const& values, DdcVcpCode code) noexcept
    {
        return std::find(values.begin(), values.end(), code) != values.end();
    }

    std::optional<int>& CachedValue(DisplayConfig& display, DdcVcpCode code)
    {
        if (code == DdcVcpCode::Brightness) return display.brightnessValue;
        if (code == DdcVcpCode::Contrast) return display.contrastValue;
        return display.volumeValue;
    }

    std::optional<int>& CachedMaximum(DisplayConfig& display, DdcVcpCode code)
    {
        if (code == DdcVcpCode::Brightness) return display.brightnessMax;
        if (code == DdcVcpCode::Contrast) return display.contrastMax;
        return display.volumeMax;
    }

    DdcControlItemResult Failure(DisplayConfig const& display, DdcVcpCode code,
        DdcBackendStatus const& status, DdcErrorKind error, std::wstring message)
    {
        DdcControlItemResult item{ display.id, code, false, false, false, false, std::nullopt, std::nullopt,
            status.availability, error, std::move(message) };
        auto cached = code == DdcVcpCode::Brightness ? display.brightnessValue :
            code == DdcVcpCode::Contrast ? display.contrastValue : display.volumeValue;
        auto cachedMaximum = code == DdcVcpCode::Brightness ? display.brightnessMax :
            code == DdcVcpCode::Contrast ? display.contrastMax : display.volumeMax;
        if (cached)
        {
            item.estimated = true;
            item.current = cached;
            item.maximum = DdcControlService::EffectiveMaximum(*cached, cachedMaximum.value_or(100));
        }
        return item;
    }

    std::vector<DdcVcpCode> ControlCodes()
    {
        return { DdcVcpCode::Brightness, DdcVcpCode::Contrast, DdcVcpCode::Volume };
    }

}

namespace DisplaySwitcher::Native
{
    bool IsDdcControlVcpCode(DdcVcpCode code) noexcept
    {
        return code == DdcVcpCode::Brightness || code == DdcVcpCode::Contrast
            || code == DdcVcpCode::Volume;
    }

    std::vector<DdcTrayControl> BuildDdcTrayControls(AppConfig const& config)
    {
        std::vector<DdcTrayControl> result;
        auto append = [&](DisplayConfig const& display, DdcVcpCode code, wchar_t const* label,
            bool enabled, bool show, std::optional<int> value, std::optional<int> maximum)
        {
            if (!enabled || !show) return;
            result.push_back({ display.id, display.name, code, label, value.value_or(0),
                DdcControlService::EffectiveMaximum(value.value_or(0), maximum.value_or(100)), value.has_value() });
        };
        for (auto const& display : config.displays)
        {
            if (!IsDisplayDdcResolved(display)) continue;
            append(display, DdcVcpCode::Brightness, L"亮度", display.brightnessEnabled,
                display.brightnessShowInTray, display.brightnessValue, display.brightnessMax);
            append(display, DdcVcpCode::Contrast, L"对比度", display.contrastEnabled,
                display.contrastShowInTray, display.contrastValue, display.contrastMax);
            append(display, DdcVcpCode::Volume, L"音量", display.volumeEnabled,
                display.volumeShowInTray, display.volumeValue, display.volumeMax);
        }
        return result;
    }

    bool DdcWriteQueue::Submit(DdcWriteRequest request)
    {
        std::scoped_lock lock(mutex_);
        pending_[{ request.displayId, request.code }] = std::move(request);
        if (workerActive_) return false;
        workerActive_ = true;
        return true;
    }

    std::optional<DdcWriteRequest> DdcWriteQueue::TakeNext()
    {
        std::scoped_lock lock(mutex_);
        if (pending_.empty())
        {
            workerActive_ = false;
            return std::nullopt;
        }
        auto item = pending_.begin();
        auto request = std::move(item->second);
        pending_.erase(item);
        return request;
    }

    void DdcWriteQueue::CancelPending()
    {
        std::scoped_lock lock(mutex_);
        pending_.clear();
    }

    size_t DdcWriteQueue::PendingCount() const
    {
        std::scoped_lock lock(mutex_);
        return pending_.size();
    }

    bool DdcCapabilities::CanRead(DdcVcpCode code) const noexcept
    {
        return status.availability == DdcAvailability::Available && (!known || Contains(readable, code));
    }

    bool DdcCapabilities::CanWrite(DdcVcpCode code) const noexcept
    {
        return status.availability == DdcAvailability::Available && (!known || Contains(writable, code));
    }

    bool DdcCancellationToken::IsCanceled() const noexcept
    {
        return state_ && state_->generation.load(std::memory_order_acquire) != generation_;
    }

    DdcCancellationToken DdcCancellationSource::Begin() noexcept
    {
        auto generation = state_->generation.fetch_add(1, std::memory_order_acq_rel) + 1;
        return DdcCancellationToken(state_, generation);
    }

    void DdcCancellationSource::Cancel() noexcept
    {
        state_->generation.fetch_add(1, std::memory_order_acq_rel);
    }

    DdcControlService::DdcControlService(DdcBackendLookup lookup, std::function<bool()> sideEffectsAllowed) :
        lookup_(std::move(lookup)), sideEffectsAllowed_(std::move(sideEffectsAllowed))
    {
    }

    DdcWriteResult WriteNativeWithOneRefresh(IDdcBackend& backend, std::wstring const& monitorId,
        DdcVcpCode code, int value, DdcCancellationToken const& cancellation)
    {
        auto result = backend.Write(monitorId, code, value, cancellation);
        if (!result.success && !cancellation.IsCanceled()
            && (result.error == DdcErrorKind::WriteFailed || result.error == DdcErrorKind::MonitorUnavailable))
            result = backend.Write(monitorId, code, value, cancellation);
        return result;
    }

    int DdcControlService::EffectiveMaximum(int current, int reportedMaximum) noexcept
    {
        return reportedMaximum >= 10 && reportedMaximum >= current ? reportedMaximum : (std::max)(100, current);
    }

    bool DdcControlService::FeatureEnabled(DisplayConfig const& display, DdcVcpCode code) noexcept
    {
        if (code == DdcVcpCode::Brightness) return display.brightnessEnabled;
        if (code == DdcVcpCode::Contrast) return display.contrastEnabled;
        if (code == DdcVcpCode::Volume) return display.volumeEnabled;
        return false;
    }

    bool DdcControlService::Allowed(AppConfig const& config, DdcCancellationToken const& cancellation) const
    {
        return !config.displayConfigurationSafeMode && !cancellation.IsCanceled()
            && (!sideEffectsAllowed_ || sideEffectsAllowed_());
    }

    IDdcBackend* DdcControlService::Backend() const
    {
        return lookup_ ? lookup_(NativeDdcBackendKey) : nullptr;
    }

    bool DdcControlService::TopologyUnchanged(IDdcBackend const& backend, uint64_t generation) noexcept
    {
        return backend.TopologyGeneration() == generation;
    }

    DdcControlBatchResult DdcControlService::Read(AppConfig& config,
        std::vector<std::wstring> const& displayIds, DdcCancellationToken const& cancellation) const
    {
        DdcControlBatchResult batch;
        if (!Allowed(config, cancellation)) { batch.canceled = true; return batch; }
        auto requested = [&](DisplayConfig const& display)
        {
            return displayIds.empty() || std::any_of(displayIds.begin(), displayIds.end(), [&](auto const& id)
            { return _wcsicmp(id.c_str(), display.id.c_str()) == 0; });
        };

        for (auto& display : config.displays)
        {
            if (!requested(display) || !display.readEnabled) continue;
            if (!Allowed(config, cancellation)) { batch.canceled = true; break; }
            if (!IsDisplayDdcResolved(display))
            {
                auto ambiguous = display.bindingStatus == DisplayBindingStatus::Ambiguous
                    || display.bindingStatus == DisplayBindingStatus::NeedsConfirmation;
                auto error = ambiguous ? DdcErrorKind::AmbiguousMonitor : DdcErrorKind::MonitorUnavailable;
                auto message = display.bindingMessage.empty()
                    ? (ambiguous ? L"显示器绑定不明确，需要重新确认" : L"显示器当前离线")
                    : display.bindingMessage;
                for (auto code : ControlCodes()) if (FeatureEnabled(display, code))
                    batch.items.push_back(Failure(display, code,
                        { DdcAvailability::TemporarilyUnavailable, message }, error, message));
                continue;
            }
            auto backend = Backend();
            DdcBackendStatus status;
            if (!backend)
            {
                status = { DdcAvailability::Unsupported, L"未选择可用的硬件 DDC 后端" };
                for (auto code : ControlCodes()) if (FeatureEnabled(display, code))
                    batch.items.push_back(Failure(display, code, status, DdcErrorKind::BackendUnavailable, status.message));
                continue;
            }
            status = backend->Status();
            if (status.availability != DdcAvailability::Available)
            {
                for (auto code : ControlCodes()) if (FeatureEnabled(display, code))
                    batch.items.push_back(Failure(display, code, status,
                        status.availability == DdcAvailability::Unsupported ? DdcErrorKind::Unsupported : DdcErrorKind::BackendUnavailable,
                        status.message));
                continue;
            }
            auto const& monitorId = display.nativeMonitorId;
            auto capabilities = backend->Capabilities(monitorId, cancellation);
            auto topologyGeneration = backend->TopologyGeneration();
            std::vector<DdcControlItemResult> displayResults;
            for (auto code : ControlCodes())
            {
                if (!FeatureEnabled(display, code)) continue;
                if (!Allowed(config, cancellation)) { batch.canceled = true; break; }
                if (!capabilities.CanRead(code))
                {
                    displayResults.push_back(Failure(display, code, capabilities.status, DdcErrorKind::Unsupported,
                        capabilities.status.message.empty() ? L"显示器未报告该硬件 DDC 功能" : capabilities.status.message));
                    continue;
                }
                auto value = backend->Read(monitorId, code, cancellation);
                if (!TopologyUnchanged(*backend, topologyGeneration)
                    || (value.success && value.topologyGeneration != 0
                        && value.topologyGeneration != backend->TopologyGeneration()))
                { batch.canceled = true; break; }
                DdcControlItemResult item{ display.id, code, value.success, false, value.success, false,
                    value.success ? std::optional<int>{ value.current } : std::nullopt,
                    value.success ? std::optional<int>{ EffectiveMaximum(value.current, value.maximum) } : std::nullopt,
                    capabilities.status.availability, value.error, value.message };
                if (!value.success)
                {
                    auto cached = CachedValue(display, code);
                    auto cachedMax = CachedMaximum(display, code);
                    if (cached)
                    {
                        item.estimated = true; item.current = cached;
                        item.maximum = EffectiveMaximum(*cached, cachedMax.value_or(100));
                    }
                }
                displayResults.push_back(std::move(item));
            }
            if (batch.canceled) break;

            auto allThreeEnabled = display.brightnessEnabled && display.contrastEnabled && display.volumeEnabled;
            auto allThreeZero = allThreeEnabled && displayResults.size() == 3
                && std::all_of(displayResults.begin(), displayResults.end(), [](auto const& item)
                { return item.success && item.current && *item.current == 0; });
            for (auto& item : displayResults)
            {
                if (allThreeZero)
                {
                    item.trusted = false;
                    item.message = L"三项硬件 DDC 遥测均为零，结果不可信";
                    auto cached = CachedValue(display, item.code);
                    auto cachedMax = CachedMaximum(display, item.code);
                    item.estimated = cached.has_value(); item.current = cached;
                    item.maximum = cached ? std::optional<int>{ EffectiveMaximum(*cached, cachedMax.value_or(100)) } : std::nullopt;
                }
                else if (item.success && item.trusted && Allowed(config, cancellation))
                {
                    CachedValue(display, item.code) = item.current;
                    CachedMaximum(display, item.code) = item.maximum;
                }
                batch.items.push_back(std::move(item));
            }
        }
        if (!Allowed(config, cancellation)) batch.canceled = true;
        batch.success = !batch.canceled && !batch.items.empty()
            && std::all_of(batch.items.begin(), batch.items.end(), [](auto const& item) { return item.success && item.trusted; });
        return batch;
    }

    DdcControlBatchResult DdcControlService::Write(AppConfig& config, std::wstring const& displayId,
        DdcVcpCode code, int value, bool linkAllDisplays, DdcCancellationToken const& cancellation) const
    {
        DdcControlBatchResult batch;
        if (!Allowed(config, cancellation)) { batch.canceled = true; return batch; }
        if (!IsDdcControlVcpCode(code))
        {
            batch.items.push_back({ displayId, code, false, false, false, false, {}, {}, DdcAvailability::Unsupported,
                DdcErrorKind::Unsupported, L"普通 DDC 控制不支持该 VCP 项" });
            return batch;
        }
        if (value < 0 || value > 65535)
        {
            batch.items.push_back({ displayId, code, false, false, false, false, {}, {}, DdcAvailability::Available,
                DdcErrorKind::InvalidValue, L"调节值超出有效范围" });
            return batch;
        }
        auto source = FindDisplayById(config.displays, displayId);
        if (!source) return batch;
        std::vector<size_t> targets;
        if (linkAllDisplays)
        {
            for (size_t index = 0; index < config.displays.size(); ++index)
                if (FeatureEnabled(config.displays[index], code)) targets.push_back(index);
        }
        else if (FeatureEnabled(config.displays[*source], code)) targets.push_back(*source);

        for (auto index : targets)
        {
            auto& display = config.displays[index];
            if (!Allowed(config, cancellation)) { batch.canceled = true; break; }
            if (!IsDisplayDdcResolved(display))
            {
                auto ambiguous = display.bindingStatus == DisplayBindingStatus::Ambiguous
                    || display.bindingStatus == DisplayBindingStatus::NeedsConfirmation;
                auto error = ambiguous ? DdcErrorKind::AmbiguousMonitor : DdcErrorKind::MonitorUnavailable;
                auto message = display.bindingMessage.empty()
                    ? (ambiguous ? L"显示器绑定不明确，需要重新确认" : L"显示器当前离线")
                    : display.bindingMessage;
                batch.items.push_back(Failure(display, code,
                    { DdcAvailability::TemporarilyUnavailable, message }, error, message));
                continue;
            }
            auto backend = Backend();
            if (!backend)
            {
                batch.items.push_back(Failure(display, code, { DdcAvailability::Unsupported, L"未选择可用的硬件 DDC 后端" },
                    DdcErrorKind::BackendUnavailable, L"未选择可用的硬件 DDC 后端"));
                continue;
            }
            auto status = backend->Status();
            if (status.availability != DdcAvailability::Available)
            {
                batch.items.push_back(Failure(display, code, status, DdcErrorKind::BackendUnavailable, status.message));
                continue;
            }
            auto const& monitorId = display.nativeMonitorId;
            auto capabilities = backend->Capabilities(monitorId, cancellation);
            auto topologyGeneration = backend->TopologyGeneration();
            if (!capabilities.CanWrite(code))
            {
                batch.items.push_back(Failure(display, code, capabilities.status, DdcErrorKind::Unsupported,
                    capabilities.status.message.empty() ? L"显示器未报告该硬件 DDC 功能" : capabilities.status.message));
                continue;
            }
            auto result = Allowed(config, cancellation)
                ? WriteNativeWithOneRefresh(*backend, monitorId, code, value, cancellation)
                : DdcWriteResult{ false, DdcErrorKind::Canceled, L"操作已取消" };
            auto topologyChangedDuringWrite = !TopologyUnchanged(*backend, topologyGeneration);
            if (topologyChangedDuringWrite || (result.success && result.topologyGeneration != 0
                && result.topologyGeneration != backend->TopologyGeneration()))
            {
                result = { false, DdcErrorKind::TopologyChanged, L"显示拓扑已变化，旧句柄结果已丢弃" };
                topologyChangedDuringWrite = true;
            }
            if (topologyChangedDuringWrite)
            {
                batch.canceled = true;
                break;
            }
            DdcControlItemResult item{ display.id, code, result.success, false, result.success, false,
                result.success ? std::optional<int>{ value } : std::nullopt,
                result.success ? std::optional<int>{ EffectiveMaximum(value, CachedMaximum(display, code).value_or(100)) } : std::nullopt,
                status.availability, result.error, result.message };
            if (result.success && Allowed(config, cancellation))
            {
                CachedValue(display, code) = value;
                CachedMaximum(display, code) = item.maximum;
            }
            batch.items.push_back(std::move(item));
        }
        if (!Allowed(config, cancellation)) batch.canceled = true;
        batch.success = !batch.canceled && !batch.items.empty()
            && std::all_of(batch.items.begin(), batch.items.end(), [](auto const& item) { return item.success; });
        return batch;
    }
}
