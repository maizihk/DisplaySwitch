#pragma once

#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    enum class MediaKeyAction
    {
        BrightnessDown,
        BrightnessUp,
        VolumeMute,
        VolumeDown,
        VolumeUp,
    };

    enum class MediaKeyPlanState
    {
        Ready,
        UntrustedTopology,
        NoEligibleTargets,
        MixedLinkedValue,
        UnknownValue,
        NoValueChange,
    };

    enum class MediaKeyInputSource
    {
        Keyboard,
        ConsumerControl,
    };

    class MediaKeyEventDeduplicator final
    {
    public:
        bool ShouldDispatch(MediaKeyAction action, MediaKeyInputSource source,
            uint64_t timestampMilliseconds) noexcept;

    private:
        struct LastEvent
        {
            MediaKeyAction action;
            MediaKeyInputSource source;
            uint64_t timestampMilliseconds{};
        };
        std::optional<LastEvent> lastDispatched_;
    };

    struct MediaKeyWrite
    {
        std::wstring displayId;
        DdcVcpCode code{ DdcVcpCode::Brightness };
        int value{};
        bool linked{};
        std::vector<std::wstring> targetDisplayIds;
    };

    struct MediaKeyPlan
    {
        MediaKeyPlanState state{ MediaKeyPlanState::NoEligibleTargets };
        std::vector<MediaKeyWrite> writes;
    };

    std::optional<MediaKeyAction> NormalizeKeyboardMediaKey(uint16_t virtualKey, bool keyDown) noexcept;
    std::optional<MediaKeyAction> NormalizeConsumerControlUsage(uint16_t usage, bool pressed) noexcept;
    inline DWORD MediaKeyRawInputRegistrationFlags() noexcept { return RIDEV_INPUTSINK; }

    class MediaKeyRouter final
    {
    public:
        MediaKeyPlan Plan(AppConfig const& config, DisplayTopologyTrust topologyTrust,
            MediaKeyAction action, uint64_t configurationGeneration, int step = 5);
        void OnWriteFailed(DdcVcpCode code, std::vector<std::wstring> const& targetDisplayIds);
        void ResetPending() noexcept;

    private:
        using ValueKey = std::pair<std::wstring, DdcVcpCode>;
        static std::wstring CanonicalId(std::wstring value);
        std::optional<int> PendingValue(std::wstring const& displayId, DdcVcpCode code) const;
        void SetPending(std::vector<std::wstring> const& displayIds, DdcVcpCode code, int value);

        uint64_t configurationGeneration_{};
        std::map<ValueKey, int> pendingValues_;
        std::map<std::wstring, int> muteRestoreValues_;
    };
}
