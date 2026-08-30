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
    ProfileDetectionAsyncOperation::ProfileDetectionAsyncOperation() : state_(std::make_shared<State>()) {}
    ProfileDetectionAsyncOperation::~ProfileDetectionAsyncOperation() { Cancel(); }

    void ProfileDetectionAsyncOperation::Start(Work work, Dispatch dispatch, Completion completion)
    {
        auto state = state_;
        auto generation = ++state->generation;
        std::thread([state, generation, work = std::move(work), dispatch = std::move(dispatch),
            completion = std::move(completion)]
        {
            auto canceled = [state, generation] { return state->generation.load() != generation; };
            bool succeeded{};
            try { if (!canceled()) succeeded = work(canceled); }
            catch (...) { succeeded = false; }
            if (canceled()) return;
            dispatch([state, generation, completion = std::move(completion), succeeded]
            {
                if (state->generation.load() == generation && completion) completion(succeeded);
            });
        }).detach();
    }

    void ProfileDetectionAsyncOperation::Cancel() noexcept
    {
        ++state_->generation;
    }

    bool ApplyProfileDetectionResult(CollaborationProfile& profile,
        ProfileDetectionResult const& result, bool endpointConfirmed)
    {
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

    ProfileDetectionAction ProfileDetectionSession::Advance(int64_t nowMilliseconds)
    {
        if (!active_ || nowMilliseconds < deadlineMilliseconds_) return {};
        return Complete({ ProfileDetectionOutcome::NoResponse });
    }

    void ProfileDetectionSession::MarkProbeSent(int64_t nowMilliseconds) noexcept
    {
        if (WaitingForV2()) deadlineMilliseconds_ = nowMilliseconds + ProbeTimeoutMilliseconds;
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

    void ProfileDetectionSession::Cancel() noexcept
    {
        active_ = false;
        phase_ = Phase::None;
        deadlineMilliseconds_ = 0;
        pendingEventId_.clear();
        savedEndpointId_.clear();
    }

    ProfileDetectionAction ProfileDetectionSession::Complete(ProfileDetectionResult result)
    {
        active_ = false;
        phase_ = Phase::None;
        pendingEventId_.clear();
        return { ProfileDetectionAction::Kind::Complete, {}, std::move(result) };
    }
}
