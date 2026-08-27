#pragma once

namespace DisplaySwitcher::Native
{
    std::wstring GenerateIdentifier();

    struct DisplayConfig
    {
        std::wstring id;
        std::wstring name;
        std::optional<int> localInput;
        bool readEnabled{ false };
        bool brightnessEnabled{ true };
        bool contrastEnabled{ true };
        bool volumeEnabled{ true };
        int macInput{ -1 };
        std::wstring nativeMonitorId;
        std::wstring controlMonitorPath;
        std::optional<int> brightnessMax;
        std::optional<int> contrastMax;
        std::optional<int> volumeMax;
        std::optional<int> brightnessValue;
        std::optional<int> contrastValue;
        std::optional<int> volumeValue;
    };

    struct DisplayInputMapping
    {
        std::wstring displayId;
        int peerInput{ -1 };
    };

    struct TriggerDeviceReference
    {
        std::wstring kind;
        std::wstring localReference;
        std::wstring displayName;
    };

    struct CollaborationProfile
    {
        std::wstring id;
        std::wstring name;
        bool coordinationEnabled{ false };
        std::wstring peerHost;
        int peerPort{ 49731 };
        std::wstring pairingCode;
        std::wstring peerEndpointId;
        std::optional<int> peerProtocolVersion;
        std::vector<DisplayInputMapping> displayInputs;
        std::vector<TriggerDeviceReference> triggerDevices;
        std::wstring statusHint;
        bool detectRequired{ false };
    };

    struct ProfileInspectionResult
    {
        bool complete{};
        bool endpointConfirmationRequired{};
        std::vector<std::wstring> problems;
    };

    struct ProfileDisplaySelection
    {
        std::vector<DisplayConfig> mappedDisplays;
        std::vector<std::wstring> missingDisplayIds;
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
