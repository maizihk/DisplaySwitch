#include "pch.h"
#include "DisplayModel.h"

namespace
{
    bool EqualInsensitive(std::wstring const& left, std::wstring const& right) noexcept
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
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
