#pragma once

#include <cstdint>
#include <optional>
#include <string>

#include "DisplayModel.h"

namespace DisplaySwitcher::Native
{
    enum class ProfileDetectionOutcome
    {
        Pending,
        V2Available,
        AuthenticationFailed,
        NoResponse,
        LocalConfigurationIncomplete,
    };

    struct ProfileDetectionResult
    {
        ProfileDetectionOutcome outcome{ ProfileDetectionOutcome::Pending };
        std::wstring observedEndpointId;
        bool endpointConfirmationRequired{};
        bool endpointChanged{};
    };

    struct ProfileDetectionAction
    {
        enum class Kind { None, SendV2Probe, Complete };
        Kind kind{ Kind::None };
        std::wstring eventId;
        ProfileDetectionResult result;
    };

    bool ApplyProfileDetectionResult(CollaborationProfile& profile,
        ProfileDetectionResult const& result, bool endpointConfirmed);

    class PendingStatusProbe final
    {
    public:
        void Begin(std::wstring eventId, int64_t expiresAtMilliseconds);
        bool MatchesAndConsume(std::wstring const& eventId, int64_t nowMilliseconds);
        bool Expired(int64_t nowMilliseconds) const noexcept;
        bool Active() const noexcept { return !eventId_.empty(); }
        void Clear() noexcept { eventId_.clear(); expiresAtMilliseconds_ = 0; }

    private:
        std::wstring eventId_;
        int64_t expiresAtMilliseconds_{};
    };

    class ProfileDetectionSession final
    {
    public:
        static constexpr int64_t ProbeTimeoutMilliseconds = 2000;

        ProfileDetectionAction Start(int64_t nowMilliseconds, bool localConfigurationComplete,
            std::wstring const& savedEndpointId, std::wstring v2EventId);
        ProfileDetectionAction Advance(int64_t nowMilliseconds);
        ProfileDetectionAction OnV2StatusResponse(int64_t nowMilliseconds, std::wstring const& eventId,
            std::wstring const& sourceEndpointId, bool authenticated);
        void Cancel() noexcept;
        bool Active() const noexcept { return active_; }
        bool WaitingForV2() const noexcept { return active_ && phase_ == Phase::V2; }
        std::wstring const& PendingEventId() const noexcept { return pendingEventId_; }

    private:
        enum class Phase { None, V2 };
        ProfileDetectionAction Complete(ProfileDetectionResult result);

        bool active_{};
        Phase phase_{ Phase::None };
        int64_t deadlineMilliseconds_{};
        std::wstring pendingEventId_;
        std::wstring savedEndpointId_;
    };
}
