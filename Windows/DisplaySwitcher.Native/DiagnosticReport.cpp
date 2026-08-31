#include "pch.h"
#include "DiagnosticReport.h"

namespace
{
    using namespace DisplaySwitcher::Native;

    wchar_t const* YesNo(bool value) { return value ? L"是" : L"否"; }
    wchar_t const* Availability(DdcAvailability value)
    {
        switch (value)
        {
        case DdcAvailability::Available: return L"可用";
        case DdcAvailability::Unsupported: return L"不支持";
        default: return L"暂时不可用";
        }
    }
    wchar_t const* Binding(DisplayBindingStatus value)
    {
        switch (value)
        {
        case DisplayBindingStatus::Resolved: return L"已唯一绑定";
        case DisplayBindingStatus::Ambiguous: return L"匹配歧义";
        case DisplayBindingStatus::NeedsConfirmation: return L"需要确认";
        default: return L"离线";
        }
    }
    wchar_t const* Heartbeat(DiagnosticHeartbeatState value)
    {
        switch (value)
        {
        case DiagnosticHeartbeatState::Recent: return L"最近合法";
        case DiagnosticHeartbeatState::Expired: return L"已过期";
        default: return L"尚未收到";
        }
    }
    wchar_t const* OperationKind(DiagnosticOperationKind value)
    {
        switch (value)
        {
        case DiagnosticOperationKind::Enumerate: return L"枚举";
        case DiagnosticOperationKind::Read: return L"读取";
        case DiagnosticOperationKind::Write: return L"写入";
        case DiagnosticOperationKind::InputSource: return L"输入源";
        default: return L"无";
        }
    }
    wchar_t const* OperationState(DiagnosticOperationState value)
    {
        switch (value)
        {
        case DiagnosticOperationState::Success: return L"成功";
        case DiagnosticOperationState::Failed: return L"失败";
        case DiagnosticOperationState::Ambiguous: return L"安全拒绝（歧义）";
        case DiagnosticOperationState::Offline: return L"不可用（离线）";
        case DiagnosticOperationState::Stale: return L"已失效";
        default: return L"尚未操作";
        }
    }
    std::wstring WidenSafeAscii(std::string const& value)
    {
        return std::wstring(value.begin(), value.end());
    }
    bool EqualId(std::wstring const& left, std::wstring const& right)
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }
    DiagnosticOperationState StateFor(DisplayConfig const& display)
    {
        if (display.bindingStatus == DisplayBindingStatus::Ambiguous) return DiagnosticOperationState::Ambiguous;
        if (display.bindingStatus != DisplayBindingStatus::Resolved) return DiagnosticOperationState::Offline;
        return DiagnosticOperationState::Idle;
    }
}

namespace DisplaySwitcher::Native
{
    std::wstring DescribeDiagnosticOperation(DiagnosticDisplaySummary const& display)
    {
        return std::wstring(OperationKind(display.lastKind)) + L"：" + OperationState(display.lastState);
    }

    std::wstring DescribeBasicDdcResult(DdcControlItemResult const& item, bool write)
    {
        if (item.success && item.trusted) return write ? L"硬件 DDC 写入成功" : L"硬件 DDC 回读成功";
        if (item.error == DdcErrorKind::AmbiguousMonitor) return L"硬件 DDC 操作失败：显示器匹配不唯一";
        return write ? L"硬件 DDC 写入失败" : L"硬件 DDC 读取失败";
    }

    std::wstring BuildDiagnosticPreview(DiagnosticSnapshot const& snapshot)
    {
        std::wostringstream out;
        out << L"DisplaySwitch 诊断预览\r\n"
            << L"应用：" << snapshot.about.applicationName << L"\r\n"
            << L"版本/构建：" << snapshot.about.publicVersion << L"\r\n"
            << L"架构：" << snapshot.about.architecture << L"\r\n"
            << L"协议：v2\r\n"
            << L"配置 schemaVersion：" << snapshot.schemaVersion << L"\r\n"
            << L"detailed-recording=" << (snapshot.detailedRecordingEnabled ? L"true（开启）" : L"false（关闭）") << L"\r\n"
            << L"安全状态：" << (snapshot.safeMode ? L"已阻断副作用" : L"正常") << L"\r\n\r\n";

        out << L"协同配置：" << snapshot.profiles.size() << L"\r\n";
        for (size_t index = 0; index < snapshot.profiles.size(); ++index)
        {
            auto const& profile = snapshot.profiles[index];
            out << L"P" << (profile.anonymousIndex ? profile.anonymousIndex : index + 1) << L"：启用=" << YesNo(profile.enabled)
                << L"，endpoint 已绑定=" << YesNo(profile.endpointBound)
                << L"，连接=" << (profile.connected ? L"在线" : L"离线")
                << L"，最后合法心跳=" << Heartbeat(profile.heartbeat) << L"\r\n";
        }
        out << L"\r\nUSB：启用=" << YesNo(snapshot.usb.enabled)
            << L"，触发设备已选择=" << YesNo(snapshot.usb.triggerSelected)
            << L"，显示器映射=" << snapshot.usb.mappingCount
            << L"，协同唤醒=" << YesNo(snapshot.usb.collaborationWakeEnabled) << L"\r\n\r\n";

        out << L"原生 Dxva2：" << Availability(snapshot.backend.availability)
            << L"，枚举=" << YesNo(snapshot.backend.enumerateSupported)
            << L"，读取=" << YesNo(snapshot.backend.readSupported)
            << L"，写入=" << YesNo(snapshot.backend.writeSupported) << L"\r\n";
        for (size_t index = 0; index < snapshot.displays.size(); ++index)
        {
            auto const& display = snapshot.displays[index];
            out << L"D" << (display.anonymousIndex ? display.anonymousIndex : index + 1) << L"：绑定=" << Binding(display.binding)
                << L"，亮度=" << (display.brightnessEnabled ? L"开启" : L"关闭")
                << L"，对比度=" << (display.contrastEnabled ? L"开启" : L"关闭")
                << L"，音量=" << (display.volumeEnabled ? L"开启" : L"关闭")
                << L"，最后操作=" << DescribeDiagnosticOperation(display) << L"\r\n";
        }

        out << L"\r\n会话内详细事件："
            << (snapshot.detailedRecordingEnabled ? snapshot.sessions.size() : 0) << L"\r\n";
        if (!snapshot.detailedRecordingEnabled)
            out << L"详细记录已关闭；仅显示配置、能力和基本运行状态。\r\n";
        else
            for (size_t index = 0; index < snapshot.sessions.size(); ++index)
                out << L"S" << index + 1 << L" / O" << index + 1 << L"：" << WidenSafeAscii(snapshot.sessions[index]) << L"\r\n";
        return out.str();
    }

    std::wstring DiagnosticPreviewModel::Refresh(IDiagnosticSnapshotProvider& provider)
    {
        preview_ = BuildDiagnosticPreview(provider.ReadSnapshot());
        return preview_;
    }

    void DiagnosticHeartbeatTracker::Reconcile(std::wstring const& localEndpointId,
        std::vector<CollaborationProfile> const& profiles)
    {
        std::scoped_lock lock(mutex_);
        std::map<std::wstring, Entry> next;
        for (auto const& profile : profiles)
        {
            auto found = entries_.find(profile.id);
            auto pairingCodeFingerprint = std::hash<std::wstring>{}(profile.pairingCode);
            Entry entry{ localEndpointId, profile.peerEndpointId, profile.peerHost, profile.peerPort,
                pairingCodeFingerprint, profile.peerProtocolVersion, 0 };
            if (found != entries_.end())
            {
                auto const& existing = found->second;
                if (EqualId(existing.localEndpointId, localEndpointId) &&
                    EqualId(existing.peerEndpointId, profile.peerEndpointId) &&
                    _wcsicmp(existing.peerHost.c_str(), profile.peerHost.c_str()) == 0 &&
                    existing.peerPort == profile.peerPort && existing.pairingCodeFingerprint == pairingCodeFingerprint &&
                    existing.peerProtocolVersion == profile.peerProtocolVersion)
                    entry.lastSeenMilliseconds = existing.lastSeenMilliseconds;
            }
            next.emplace(profile.id, std::move(entry));
        }
        entries_ = std::move(next);
    }

    void DiagnosticHeartbeatTracker::Observe(std::wstring const& profileId,
        std::wstring const& peerEndpointId, int64_t nowMilliseconds)
    {
        std::scoped_lock lock(mutex_);
        auto found = entries_.find(profileId);
        if (found == entries_.end() || !EqualId(found->second.peerEndpointId, peerEndpointId)) return;
        found->second.lastSeenMilliseconds = nowMilliseconds;
    }

    DiagnosticHeartbeatState DiagnosticHeartbeatTracker::State(std::wstring const& profileId,
        std::wstring const& peerEndpointId, int64_t nowMilliseconds, int64_t recentWindowMilliseconds) const
    {
        std::scoped_lock lock(mutex_);
        auto found = entries_.find(profileId);
        if (found == entries_.end() || !EqualId(found->second.peerEndpointId, peerEndpointId) ||
            found->second.lastSeenMilliseconds <= 0)
            return DiagnosticHeartbeatState::Never;
        return nowMilliseconds - found->second.lastSeenMilliseconds <= recentWindowMilliseconds
            ? DiagnosticHeartbeatState::Recent : DiagnosticHeartbeatState::Expired;
    }

    void DiagnosticHeartbeatTracker::Reset()
    {
        std::scoped_lock lock(mutex_);
        entries_.clear();
    }

    size_t DiagnosticAliasRegistry::Resolve(std::map<std::wstring, size_t>& values, std::wstring const& stableId)
    {
        auto found = values.find(stableId);
        if (found != values.end()) return found->second;
        auto next = values.size() + 1;
        values.emplace(stableId, next);
        return next;
    }

    size_t DiagnosticAliasRegistry::Profile(std::wstring const& stableId)
    {
        std::scoped_lock lock(mutex_);
        return Resolve(profiles_, stableId);
    }

    size_t DiagnosticAliasRegistry::Display(std::wstring const& stableId)
    {
        std::scoped_lock lock(mutex_);
        return Resolve(displays_, stableId);
    }

    void DisplayOperationTracker::Reconcile(std::vector<DisplayConfig> const& displays)
    {
        std::scoped_lock lock(mutex_);
        std::map<std::wstring, Entry> next;
        for (auto const& display : displays)
        {
            Entry entry{ display.nativeMonitorId, display.topologyGeneration, DiagnosticOperationKind::None, StateFor(display) };
            auto existing = entries_.find(display.id);
            if (existing != entries_.end() && display.bindingStatus == DisplayBindingStatus::Resolved &&
                EqualId(existing->second.bindingId, display.nativeMonitorId) &&
                existing->second.topologyGeneration == display.topologyGeneration)
                entry = existing->second;
            next.emplace(display.id, std::move(entry));
        }
        entries_ = std::move(next);
    }

    void DisplayOperationTracker::Record(std::wstring const& displayId, std::wstring const& bindingId,
        uint64_t topologyGeneration, DiagnosticOperationKind kind, DiagnosticOperationState state)
    {
        std::scoped_lock lock(mutex_);
        auto found = entries_.find(displayId);
        if (found == entries_.end() || !EqualId(found->second.bindingId, bindingId) ||
            found->second.topologyGeneration != topologyGeneration) return;
        found->second.kind = kind;
        found->second.state = state;
    }

    void DisplayOperationTracker::RecordBatch(std::vector<DisplayConfig> const& displays,
        DdcControlBatchResult const& result, DiagnosticOperationKind kind)
    {
        struct Aggregate
        {
            bool sawItem{};
            bool allTrustedSuccess{ true };
            bool ambiguous{};
        };
        std::map<size_t, Aggregate> aggregates;
        for (auto const& item : result.items)
        {
            auto index = FindDisplayById(displays, item.displayId);
            if (!index) continue;
            auto& aggregate = aggregates[*index];
            aggregate.sawItem = true;
            aggregate.ambiguous = aggregate.ambiguous || item.error == DdcErrorKind::AmbiguousMonitor;
            aggregate.allTrustedSuccess = aggregate.allTrustedSuccess && item.success && item.trusted && !item.skipped;
        }
        for (auto const& [index, aggregate] : aggregates)
        {
            if (!aggregate.sawItem) continue;
            auto const& display = displays[index];
            auto state = aggregate.ambiguous ? DiagnosticOperationState::Ambiguous :
                (aggregate.allTrustedSuccess ? DiagnosticOperationState::Success : DiagnosticOperationState::Failed);
            Record(display.id, display.nativeMonitorId, display.topologyGeneration, kind, state);
        }
    }

    std::vector<DiagnosticDisplaySummary> DisplayOperationTracker::Snapshot(std::vector<DisplayConfig> const& displays,
        DiagnosticAliasRegistry* aliases) const
    {
        std::scoped_lock lock(mutex_);
        std::vector<DiagnosticDisplaySummary> result;
        for (auto const& display : displays)
        {
            DiagnosticDisplaySummary summary{ aliases ? aliases->Display(display.id) : 0, display.bindingStatus, display.brightnessEnabled,
                display.contrastEnabled, display.volumeEnabled, DiagnosticOperationKind::None, StateFor(display) };
            auto found = entries_.find(display.id);
            if (found != entries_.end() && EqualId(found->second.bindingId, display.nativeMonitorId) &&
                found->second.topologyGeneration == display.topologyGeneration)
            {
                summary.lastKind = found->second.kind;
                summary.lastState = found->second.state;
            }
            result.push_back(summary);
        }
        return result;
    }
}
