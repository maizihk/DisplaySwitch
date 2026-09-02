#include "pch.h"
#include "DisplayModel.h"

namespace
{
    constexpr std::wstring_view StrongBindingPrefix = L"ds13:";
    constexpr std::wstring_view PendingTargetPrefix = L"target:";

    bool EqualInsensitive(std::wstring const& left, std::wstring const& right) noexcept
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }

    bool IsGenericDisplayName(std::wstring const& name)
    {
        constexpr std::wstring_view prefix = L"显示器 ";
        if (!name.starts_with(prefix) || name.size() == prefix.size()) return name.empty();
        return std::all_of(name.begin() + static_cast<std::ptrdiff_t>(prefix.size()), name.end(), iswdigit);
    }

    bool ContainsInsensitive(std::vector<std::wstring> const& values, std::wstring const& candidate)
    {
        return std::any_of(values.begin(), values.end(), [&](auto const& value)
            { return EqualInsensitive(value, candidate); });
    }

    std::wstring MonitorGroupingKey(DisplaySwitcher::Native::DdcMonitorInfo const& monitor)
    {
        if (!monitor.logicalTargetId.empty()) return monitor.logicalTargetId;
        return DisplaySwitcher::Native::CanonicalDdcMonitorId(monitor.id);
    }
}

namespace DisplaySwitcher::Native
{
    std::wstring GenerateIdentifier()
    {
        GUID guid{};
        winrt::check_hresult(CoCreateGuid(&guid));
        wchar_t buffer[39]{};
        auto length = StringFromGUID2(guid, buffer, static_cast<int>(std::size(buffer)));
        if (length <= 2) throw std::runtime_error("cannot create identifier");

        std::wstring identifier;
        identifier.assign(buffer + 1, static_cast<size_t>(length - 3));
        std::transform(identifier.begin(), identifier.end(), identifier.begin(), towlower);
        return identifier;
    }

    DisplayConfig CreateDisplayConfig(std::wstring const& name)
    {
        DisplayConfig display;
        display.id = GenerateIdentifier();
        display.name = name;
        return display;
    }

    std::wstring CanonicalDdcMonitorId(std::wstring const& id)
    {
        auto result = id;
        auto separator = result.find_last_of(L'|');
        if (separator != std::wstring::npos && separator + 1 < result.size()
            && std::all_of(result.begin() + static_cast<std::ptrdiff_t>(separator + 1), result.end(), iswdigit))
            result.resize(separator);
        return result;
    }

    bool IsPersistedStrongMonitorBinding(std::wstring const& id) noexcept
    {
        return id.starts_with(StrongBindingPrefix) && id.size() > StrongBindingPrefix.size();
    }

    bool IsDisplayDdcResolved(DisplayConfig const& display) noexcept
    {
        return display.bindingStatus == DisplayBindingStatus::Resolved
            && !display.nativeMonitorId.empty();
    }

    std::vector<DdcMonitorInfo> NormalizeDdcMonitorCollection(std::vector<DdcMonitorInfo> monitors)
    {
        std::vector<DdcMonitorInfo> unique;
        for (auto& monitor : monitors)
        {
            auto originalId = monitor.id;
            auto groupingKey = MonitorGroupingKey(monitor);
            if (groupingKey.empty()) continue;
            if (monitor.logicalTargetId.empty()) monitor.logicalTargetId = groupingKey;
            if (!originalId.empty() && !ContainsInsensitive(monitor.legacyIds, originalId))
                monitor.legacyIds.push_back(originalId);
            if (monitor.physicalHandleCount == 0) monitor.physicalHandleCount = 1;
            auto found = std::find_if(unique.begin(), unique.end(), [&](auto const& value)
                { return EqualInsensitive(MonitorGroupingKey(value), groupingKey); });
            if (found == unique.end()) unique.push_back(std::move(monitor));
            else
            {
                if (found->displayName.empty()) found->displayName = std::move(monitor.displayName);
                if (found->gdiName.empty()) found->gdiName = std::move(monitor.gdiName);
                if (found->id.empty()) found->id = std::move(monitor.id);
                else if (!monitor.id.empty() && !EqualInsensitive(found->id, monitor.id)) found->ambiguous = true;
                found->physicalHandleCount += monitor.physicalHandleCount;
                found->ambiguous = found->ambiguous || monitor.ambiguous;
                for (auto& legacy : monitor.legacyIds)
                    if (!ContainsInsensitive(found->legacyIds, legacy)) found->legacyIds.push_back(std::move(legacy));
            }
        }
        std::sort(unique.begin(), unique.end(), [](auto const& left, auto const& right)
            { return _wcsicmp(MonitorGroupingKey(left).c_str(), MonitorGroupingKey(right).c_str()) < 0; });

        for (auto& monitor : unique)
        {
            auto duplicateStrongIdentity = !monitor.id.empty() && std::count_if(unique.begin(), unique.end(), [&](auto const& other)
                { return EqualInsensitive(other.id, monitor.id); }) != 1;
            monitor.ambiguous = monitor.ambiguous || monitor.id.empty()
                || monitor.physicalHandleCount != 1 || duplicateStrongIdentity;
        }

        for (auto& monitor : unique) if (monitor.displayName.empty()) monitor.displayName = L"显示器";
        std::vector<std::wstring> baseNames;
        baseNames.reserve(unique.size());
        for (auto const& monitor : unique) baseNames.push_back(monitor.displayName);
        for (size_t index = 0; index < unique.size(); ++index)
        {
            auto count = std::count_if(baseNames.begin(), baseNames.end(), [&](auto const& other)
                { return EqualInsensitive(other, baseNames[index]); });
            if (count < 2) continue;
            auto ordinal = 1 + std::count_if(baseNames.begin(), baseNames.begin() + static_cast<std::ptrdiff_t>(index),
                [&](auto const& other) { return EqualInsensitive(other, baseNames[index]); });
            unique[index].displayName = baseNames[index] + L"（" + std::to_wstring(ordinal) + L"）";
        }
        return unique;
    }

    DisplayReconciliationResult ReconcileDisplayConfigurations(
        std::vector<DisplayConfig> const& existing, std::vector<DdcMonitorInfo> const& connected,
        DisplayTopologyTrust topologyTrust)
    {
        DisplayReconciliationResult result;
        if (topologyTrust != DisplayTopologyTrust::LocalPhysicalAuthoritative || connected.empty())
        {
            result.displays = existing;
            return result;
        }
        auto monitors = NormalizeDdcMonitorCollection(connected);
        if (monitors.empty())
        {
            result.displays = existing;
            return result;
        }
        result.displays.reserve((std::max)(existing.size(), monitors.size()));
        std::vector<bool> used(existing.size());
        std::vector<bool> monitorUsed(monitors.size());
        auto applyMonitor = [&](DisplayConfig display, DdcMonitorInfo const& monitor, bool migrateBinding)
        {
            display.topologyGeneration = monitor.topologyGeneration;
            if (monitor.ambiguous)
            {
                display.bindingStatus = DisplayBindingStatus::Ambiguous;
                display.bindingMessage = monitor.physicalHandleCount != 1
                    ? L"当前逻辑显示目标对应多个物理 DDC 句柄，需要重新确认"
                    : L"显示器身份不唯一，需要重新确认";
            }
            else if (migrateBinding || EqualInsensitive(display.nativeMonitorId, monitor.id))
            {
                if (migrateBinding && !EqualInsensitive(display.nativeMonitorId, monitor.id))
                {
                    display.nativeMonitorId = monitor.id;
                    result.changed = true;
                }
                display.bindingStatus = DisplayBindingStatus::Resolved;
                display.bindingMessage = L"原生 DDC/CI 已绑定";
            }
            else
            {
                display.bindingStatus = DisplayBindingStatus::NeedsConfirmation;
                display.bindingMessage = L"当前显示目标需要用户重新确认绑定";
            }
            if (IsGenericDisplayName(display.name) && display.name != monitor.displayName)
            {
                display.name = monitor.displayName;
                result.changed = true;
            }
            result.displays.push_back(std::move(display));
        };

        // First preserve exact strong bindings. Global one-to-one use tracking
        // prevents the same physical target from satisfying two logical entries.
        for (size_t existingIndex = 0; existingIndex < existing.size(); ++existingIndex)
        {
            auto const& display = existing[existingIndex];
            if (!IsPersistedStrongMonitorBinding(display.nativeMonitorId)) continue;
            std::vector<size_t> candidates;
            for (size_t monitorIndex = 0; monitorIndex < monitors.size(); ++monitorIndex)
                if (!monitorUsed[monitorIndex] && EqualInsensitive(display.nativeMonitorId, monitors[monitorIndex].id))
                    candidates.push_back(monitorIndex);
            if (candidates.size() != 1) continue;
            auto index = candidates.front();
            used[existingIndex] = true; monitorUsed[index] = true;
            applyMonitor(display, monitors[index], false);
        }

        // Legacy GDI/interface identifiers migrate only when they select one
        // non-ambiguous strong target. Never choose the first equivalent item.
        for (size_t existingIndex = 0; existingIndex < existing.size(); ++existingIndex)
        {
            if (used[existingIndex]) continue;
            auto const& display = existing[existingIndex];
            std::vector<size_t> candidates;
            for (size_t monitorIndex = 0; monitorIndex < monitors.size(); ++monitorIndex)
            {
                if (monitorUsed[monitorIndex]) continue;
                auto const& monitor = monitors[monitorIndex];
                auto legacyMatch = EqualInsensitive(display.nativeMonitorId, monitor.gdiName)
                    || ContainsInsensitive(monitor.legacyIds, display.nativeMonitorId)
                    || (!display.nativeMonitorId.empty() && display.nativeMonitorId.starts_with(PendingTargetPrefix)
                        && EqualInsensitive(display.nativeMonitorId.substr(PendingTargetPrefix.size()), monitor.logicalTargetId));
                if (legacyMatch) candidates.push_back(monitorIndex);
            }
            if (candidates.size() != 1) continue;
            auto index = candidates.front();
            used[existingIndex] = true; monitorUsed[index] = true;
            auto canMigrate = !monitors[index].ambiguous && !monitors[index].id.empty()
                && !display.nativeMonitorId.starts_with(PendingTargetPrefix);
            applyMonitor(display, monitors[index], canMigrate);
        }

        // A current logical target absent from the saved catalogue is shown once.
        // Weak/ambiguous targets receive a non-operational target token so they
        // remain visible without being mistaken for a confirmed binding.
        for (size_t monitorIndex = 0; monitorIndex < monitors.size(); ++monitorIndex)
        {
            if (monitorUsed[monitorIndex]) continue;
            auto const& monitor = monitors[monitorIndex];
            auto display = CreateDisplayConfig(monitor.displayName);
            display.nativeMonitorId = !monitor.ambiguous && !monitor.id.empty()
                ? monitor.id : std::wstring(PendingTargetPrefix) + monitor.logicalTargetId;
            applyMonitor(std::move(display), monitor, !monitor.ambiguous && !monitor.id.empty());
            ++result.added;
            result.changed = true;
        }

        // Disconnected or unresolved saved displays remain in the catalogue and
        // retain all user settings and cross-feature mappings.
        for (size_t existingIndex = 0; existingIndex < existing.size(); ++existingIndex)
        {
            if (used[existingIndex]) continue;
            auto display = existing[existingIndex];
            display.bindingStatus = IsPersistedStrongMonitorBinding(display.nativeMonitorId)
                ? DisplayBindingStatus::Offline : DisplayBindingStatus::NeedsConfirmation;
            display.topologyGeneration = 0;
            display.bindingMessage = display.bindingStatus == DisplayBindingStatus::Offline
                ? L"显示器当前离线，配置已保留" : L"显示器绑定证据不足，需要重新确认";
            result.displays.push_back(std::move(display));
        }
        result.removed = 0;
        result.changed = result.changed || result.displays.size() != existing.size();
        return result;
    }

    bool DisplayMappingProjection::Refresh(std::vector<DisplayConfig> const& catalogue,
        DisplayTopologyTrust topologyTrust)
    {
        if (topologyTrust != DisplayTopologyTrust::LocalPhysicalAuthoritative) return false;

        uint64_t currentGeneration{};
        for (auto const& display : catalogue)
            currentGeneration = (std::max)(currentGeneration, display.topologyGeneration);

        struct Candidate
        {
            DisplayConfig const* display{};
            std::wstring normalizedDisplayId;
            std::wstring normalizedBinding;
        };
        std::vector<Candidate> candidates;
        std::map<std::wstring, size_t> displayIdFrequencies;
        std::map<std::wstring, size_t> bindingFrequencies;
        for (auto const& display : catalogue)
        {
            if (display.bindingStatus != DisplayBindingStatus::Resolved || !currentGeneration
                || display.topologyGeneration != currentGeneration || !IsValidDisplayId(display.id)) continue;
            auto displayId = display.id;
            auto binding = display.nativeMonitorId;
            std::transform(displayId.begin(), displayId.end(), displayId.begin(), towlower);
            std::transform(binding.begin(), binding.end(), binding.begin(), towlower);
            constexpr std::wstring_view strongBindingPrefix = L"ds13:";
            if (!binding.starts_with(strongBindingPrefix) || binding.size() <= strongBindingPrefix.size()) continue;
            candidates.push_back({ &display, displayId, binding });
            ++displayIdFrequencies[displayId];
            ++bindingFrequencies[binding];
        }

        std::vector<DisplayMappingRow> next;
        for (auto const& candidate : candidates)
        {
            if (displayIdFrequencies[candidate.normalizedDisplayId] != 1
                || bindingFrequencies[candidate.normalizedBinding] != 1) continue;
            auto const& display = *candidate.display;
            next.push_back({ display.id, display.name, display.topologyGeneration });
        }

        auto same = next.size() == rows_.size() && std::equal(next.begin(), next.end(), rows_.begin(),
            [](auto const& left, auto const& right)
            {
                return EqualInsensitive(left.displayId, right.displayId)
                    && left.displayName == right.displayName
                    && left.topologyGeneration == right.topologyGeneration;
            });
        rows_ = std::move(next);
        topologyGeneration_ = currentGeneration;
        return !same;
    }

    std::vector<DisplayInputMapping> MergeVisibleProfileDisplayInputs(
        std::vector<DisplayInputMapping> const& existing,
        std::vector<VisibleDisplayInputEdit> const& visibleEdits)
    {
        auto result = existing;
        for (auto const& edit : visibleEdits)
        {
            auto found = std::find_if(result.begin(), result.end(), [&](auto const& mapping)
                { return EqualInsensitive(mapping.displayId, edit.displayId); });
            if (!edit.value)
            {
                if (found != result.end()) result.erase(found);
            }
            else if (found != result.end()) found->peerInput = *edit.value;
            else result.push_back({ edit.displayId, *edit.value });
        }
        return result;
    }

    std::vector<UsbDisplayInputMapping> MergeVisibleUsbDisplayInputs(
        std::vector<UsbDisplayInputMapping> const& existing,
        std::vector<VisibleDisplayInputEdit> const& visibleEdits)
    {
        auto result = existing;
        for (auto const& edit : visibleEdits)
        {
            auto found = std::find_if(result.begin(), result.end(), [&](auto const& mapping)
                { return EqualInsensitive(mapping.displayId, edit.displayId); });
            if (found != result.end()) found->targetInput = edit.value;
            else result.push_back({ edit.displayId, edit.value });
        }
        return result;
    }

    bool RemoveOrphanedDisplayMappings(std::vector<DisplayConfig> const& displays,
        std::vector<CollaborationProfile>& profiles, UsbSwitchConfig& usbSwitch)
    {
        auto exists = [&](std::wstring const& id) { return FindDisplayById(displays, id).has_value(); };
        bool changed{};
        for (auto& profile : profiles)
        {
            auto oldSize = profile.displayInputs.size();
            std::erase_if(profile.displayInputs, [&](auto const& mapping) { return !exists(mapping.displayId); });
            changed = changed || oldSize != profile.displayInputs.size();
        }
        auto oldUsbSize = usbSwitch.displayInputs.size();
        std::erase_if(usbSwitch.displayInputs, [&](auto const& mapping) { return !exists(mapping.displayId); });
        return changed || oldUsbSize != usbSwitch.displayInputs.size();
    }

    bool IsValidDisplayId(std::wstring const& id) noexcept
    {
        if (id.size() != 36) return false;
        for (size_t index = 0; index < id.size(); ++index)
        {
            if (index == 8 || index == 13 || index == 18 || index == 23)
            {
                if (id[index] != L'-') return false;
            }
            else if (!iswxdigit(id[index])) return false;
        }
        return true;
    }

    std::optional<size_t> FindDisplayById(
        std::vector<DisplayConfig> const& displays,
        std::wstring const& id) noexcept
    {
        for (size_t index = 0; index < displays.size(); ++index)
        {
            if (EqualInsensitive(displays[index].id, id)) return index;
        }
        return std::nullopt;
    }

    std::optional<size_t> FindDdcMonitorById(
        std::vector<DdcMonitorInfo> const& monitors,
        std::wstring const& id) noexcept
    {
        for (size_t index = 0; index < monitors.size(); ++index)
        {
            if (EqualInsensitive(monitors[index].id, id)) return index;
        }
        return std::nullopt;
    }

    ActionResult ExecuteDisplayActions(
        std::vector<DisplayConfig> const& displays,
        std::function<ActionResult(DisplayConfig const&)> const& action)
    {
        std::vector<std::future<ActionResult>> tasks;
        tasks.reserve(displays.size());
        for (auto const& display : displays)
        {
            tasks.emplace_back(std::async(std::launch::async, [&action, display]
            {
                try { return action(display); }
                catch (std::exception const& error)
                {
                    return ActionResult{ false, winrt::to_hstring(error.what()).c_str() };
                }
                catch (...) { return ActionResult{ false, L"未知错误" }; }
            }));
        }

        std::wstring errors;
        for (size_t index = 0; index < tasks.size(); ++index)
        {
            auto result = tasks[index].get();
            if (result.success) continue;
            if (!errors.empty()) errors += L"；";
            auto name = displays[index].name.empty() ? displays[index].id : displays[index].name;
            errors += name + L"：" + result.error;
        }
        return { errors.empty(), errors };
    }
}
