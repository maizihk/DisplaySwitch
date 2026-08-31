#pragma once

namespace DisplaySwitcher::Native
{
    std::wstring GenerateIdentifier();

    enum class DisplayBindingStatus
    {
        Offline,
        Resolved,
        Ambiguous,
        NeedsConfirmation,
    };

    enum class DisplayTopologyTrust
    {
        LocalPhysicalAuthoritative,
        RemoteSessionLimited,
        IncompleteOrUnavailable,
    };

    struct DisplayConfig
    {
        std::wstring id;
        std::wstring name;
        std::optional<int> localInput;
        bool readEnabled{ true };
        bool brightnessEnabled{ false };
        bool brightnessShowInTray{ false };
        bool contrastEnabled{ false };
        bool contrastShowInTray{ false };
        bool volumeEnabled{ false };
        bool volumeShowInTray{ false };
        int macInput{ -1 };
        std::wstring nativeMonitorId;
        std::optional<int> brightnessMax;
        std::optional<int> contrastMax;
        std::optional<int> volumeMax;
        std::optional<int> brightnessValue;
        std::optional<int> contrastValue;
        std::optional<int> volumeValue;

        // Runtime-only topology state. These fields are deliberately excluded
        // from schema v5 serialization; nativeMonitorId remains the local,
        // opaque persisted binding token.
        DisplayBindingStatus bindingStatus{ DisplayBindingStatus::Offline };
        uint64_t topologyGeneration{};
        std::wstring bindingMessage;

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

    struct UsbDisplayInputMapping
    {
        std::wstring displayId;
        std::optional<int> targetInput;
    };

    struct UsbSwitchConfig
    {
        bool enabled{ false };
        std::wstring deviceLocalReference;
        std::wstring deviceName;
        int vendorId{ -1 };
        int productId{ -1 };
        std::vector<UsbDisplayInputMapping> displayInputs;
        bool collaborationWakeEnabled{ false };
        std::wstring collaborationProfileId;
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
        // Opaque strong identity used for persisted binding. Empty means the
        // current target cannot be uniquely identified strongly enough.
        std::wstring id;
        std::wstring displayName;
        std::wstring gdiName;
        std::wstring logicalTargetId;
        std::vector<std::wstring> legacyIds;
        size_t physicalHandleCount{ 1 };
        bool ambiguous{};
        uint64_t topologyGeneration{};
    };

    struct DisplayReconciliationResult
    {
        std::vector<DisplayConfig> displays;
        bool changed{};
        size_t added{};
        size_t removed{};
    };

    DisplayConfig CreateDisplayConfig(std::wstring const& name = {});
    std::wstring CanonicalDdcMonitorId(std::wstring const& id);
    bool IsPersistedStrongMonitorBinding(std::wstring const& id) noexcept;
    bool IsDisplayDdcResolved(DisplayConfig const& display) noexcept;
    std::vector<DdcMonitorInfo> NormalizeDdcMonitorCollection(std::vector<DdcMonitorInfo> monitors);
    DisplayReconciliationResult ReconcileDisplayConfigurations(
        std::vector<DisplayConfig> const& existing,
        std::vector<DdcMonitorInfo> const& connected,
        DisplayTopologyTrust topologyTrust);
    bool RemoveOrphanedDisplayMappings(std::vector<DisplayConfig> const& displays,
        std::vector<CollaborationProfile>& profiles, UsbSwitchConfig& usbSwitch);
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
