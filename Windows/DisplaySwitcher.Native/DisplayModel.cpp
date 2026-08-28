#include "pch.h"
#include "DisplayModel.h"

namespace
{
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

    std::vector<DdcMonitorInfo> NormalizeDdcMonitorCollection(std::vector<DdcMonitorInfo> monitors)
    {
        std::vector<DdcMonitorInfo> unique;
        for (auto& monitor : monitors)
        {
            monitor.id = CanonicalDdcMonitorId(monitor.id);
            if (monitor.id.empty()) continue;
            auto found = std::find_if(unique.begin(), unique.end(), [&](auto const& value)
                { return EqualInsensitive(value.id, monitor.id); });
            if (found == unique.end()) unique.push_back(std::move(monitor));
            else
            {
                if (found->displayName.empty()) found->displayName = std::move(monitor.displayName);
                if (found->gdiName.empty()) found->gdiName = std::move(monitor.gdiName);
            }
        }
        std::sort(unique.begin(), unique.end(), [](auto const& left, auto const& right)
            { return _wcsicmp(left.id.c_str(), right.id.c_str()) < 0; });

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
        std::vector<DisplayConfig> const& existing, std::vector<DdcMonitorInfo> const& connected)
    {
        DisplayReconciliationResult result;
        auto monitors = NormalizeDdcMonitorCollection(connected);
        result.displays.reserve(monitors.size());
        std::vector<bool> used(existing.size());
        for (auto const& monitor : monitors)
        {
            auto found = std::find_if(existing.begin(), existing.end(), [&](auto const& display)
                { return EqualInsensitive(CanonicalDdcMonitorId(display.nativeMonitorId), monitor.id); });
            if (found == existing.end())
            {
                auto display = CreateDisplayConfig(monitor.displayName);
                display.nativeMonitorId = monitor.id;
                result.displays.push_back(std::move(display));
                ++result.added;
                result.changed = true;
                continue;
            }
            auto index = static_cast<size_t>(std::distance(existing.begin(), found));
            if (used[index]) continue;
            used[index] = true;
            auto display = *found;
            if (!EqualInsensitive(display.nativeMonitorId, monitor.id))
            {
                display.nativeMonitorId = monitor.id;
                result.changed = true;
            }
            if (IsGenericDisplayName(display.name) && display.name != monitor.displayName)
            {
                display.name = monitor.displayName;
                result.changed = true;
            }
            result.displays.push_back(std::move(display));
        }
        result.removed = static_cast<size_t>(std::count(used.begin(), used.end(), false));
        result.changed = result.changed || result.removed != 0 || result.displays.size() != existing.size();
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
