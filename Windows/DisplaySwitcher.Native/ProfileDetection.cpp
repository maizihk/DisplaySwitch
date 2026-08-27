#include "pch.h"
#include "ProfileDetection.h"

namespace
{
    bool EqualId(std::wstring const& left, std::wstring const& right)
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }
}

namespace DisplaySwitcher::Native
{
    bool ApplyProfileDetectionResult(CollaborationProfile& profile,
        ProfileDetectionResult const& result, bool endpointConfirmed)
    {
        if (result.outcome == ProfileDetectionOutcome::V1Only)
        {
            profile.peerProtocolVersion = 1;
            return true;
        }
        if (result.outcome != ProfileDetectionOutcome::V2Available) return false;
        if (result.endpointConfirmationRequired && !endpointConfirmed) return false;
        if (result.endpointConfirmationRequired) profile.peerEndpointId = result.observedEndpointId;
        profile.peerProtocolVersion = 2;
        return true;
    }

    void PendingStatusProbe::Begin(std::wstring eventId, int64_t expiresAtMilliseconds)
    {
        eventId_ = std::move(eventId);
        expiresAtMilliseconds_ = expiresAtMilliseconds;
    }

    bool PendingStatusProbe::MatchesAndConsume(std::wstring const& eventId, int64_t nowMilliseconds)
    {
        if (eventId_.empty() || nowMilliseconds > expiresAtMilliseconds_ || !EqualId(eventId_, eventId)) return false;
        Clear();
        return true;
    }

    bool PendingStatusProbe::Expired(int64_t nowMilliseconds) const noexcept
    {
        return !eventId_.empty() && nowMilliseconds > expiresAtMilliseconds_;
    }

    ProfileDetectionAction ProfileDetectionSession::Start(int64_t nowMilliseconds,
        bool localConfigurationComplete, std::wstring const& savedEndpointId, std::wstring v2EventId)
    {
        Cancel();
        if (!localConfigurationComplete || v2EventId.empty())
            return Complete({ ProfileDetectionOutcome::LocalConfigurationIncomplete });
        active_ = true;
        phase_ = Phase::V2;
        deadlineMilliseconds_ = nowMilliseconds + ProbeTimeoutMilliseconds;
        pendingEventId_ = std::move(v2EventId);
        savedEndpointId_ = savedEndpointId;
        return { ProfileDetectionAction::Kind::SendV2Probe, pendingEventId_ };
    }

    ProfileDetectionAction ProfileDetectionSession::Advance(int64_t nowMilliseconds, std::wstring v1EventId)
    {
        if (!active_ || nowMilliseconds < deadlineMilliseconds_) return {};
        if (phase_ == Phase::V2 && !v1ProbeSent_ && !v1EventId.empty())
        {
            phase_ = Phase::V1;
            v1ProbeSent_ = true;
            pendingEventId_ = std::move(v1EventId);
            deadlineMilliseconds_ = nowMilliseconds + ProbeTimeoutMilliseconds;
            return { ProfileDetectionAction::Kind::SendV1Probe, pendingEventId_ };
        }
        return Complete({ ProfileDetectionOutcome::NoResponse });
    }

    ProfileDetectionAction ProfileDetectionSession::OnV2StatusResponse(int64_t nowMilliseconds,
        std::wstring const& eventId, std::wstring const& sourceEndpointId, bool authenticated)
    {
        if (!WaitingForV2() || nowMilliseconds > deadlineMilliseconds_ || !EqualId(eventId, pendingEventId_)) return {};
        if (!authenticated) return Complete({ ProfileDetectionOutcome::AuthenticationFailed });
        ProfileDetectionResult result;
        result.outcome = ProfileDetectionOutcome::V2Available;
        result.observedEndpointId = sourceEndpointId;
        result.endpointConfirmationRequired = savedEndpointId_.empty() || !EqualId(savedEndpointId_, sourceEndpointId);
        result.endpointChanged = !savedEndpointId_.empty() && !EqualId(savedEndpointId_, sourceEndpointId);
        return Complete(std::move(result));
    }

    ProfileDetectionAction ProfileDetectionSession::OnV1StatusResponse(int64_t nowMilliseconds,
        std::wstring const& eventId, bool accepted)
    {
        if (!WaitingForV1() || nowMilliseconds > deadlineMilliseconds_ || !EqualId(eventId, pendingEventId_) || !accepted) return {};
        return Complete({ ProfileDetectionOutcome::V1Only });
    }

    void ProfileDetectionSession::Cancel() noexcept
    {
        active_ = false;
        phase_ = Phase::None;
        deadlineMilliseconds_ = 0;
        pendingEventId_.clear();
        savedEndpointId_.clear();
        v1ProbeSent_ = false;
    }

    ProfileDetectionAction ProfileDetectionSession::Complete(ProfileDetectionResult result)
    {
        active_ = false;
        phase_ = Phase::None;
        pendingEventId_.clear();
        return { ProfileDetectionAction::Kind::Complete, {}, std::move(result) };
    }
}
