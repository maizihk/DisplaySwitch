#pragma once

namespace DisplaySwitcher::Native
{
    struct DisplayConfig
    {
        std::wstring id;
        std::wstring name;
        std::wstring nativeMonitorId;
        std::wstring controlMonitorPath;
        int macInput{ -1 };
    };

    struct ActionResult
    {
        bool success{};
        std::wstring error;
    };

    struct DdcMonitorInfo
    {
        std::wstring id;
        std::wstring displayName;
        std::wstring gdiName;
    };

    DisplayConfig CreateDisplayConfig(std::wstring const& name = {});
    bool IsValidDisplayId(std::wstring const& id) noexcept;
    std::optional<size_t> FindDisplayById(
        std::vector<DisplayConfig> const& displays,
        std::wstring const& id) noexcept;
    std::optional<size_t> FindDdcMonitorById(
        std::vector<DdcMonitorInfo> const& monitors,
        std::wstring const& id) noexcept;
    ActionResult ExecuteDisplayActions(
        std::vector<DisplayConfig> const& displays,
        std::function<ActionResult(DisplayConfig const&)> const& action);
}
