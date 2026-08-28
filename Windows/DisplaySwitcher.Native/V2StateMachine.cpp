#include "pch.h"
#include "V2StateMachine.h"

namespace
{
    constexpr int64_t RetryMilliseconds = 150;
    constexpr int MaximumRequests = 4;

    bool Equal(std::wstring const& left, std::wstring const& right) { return _wcsicmp(left.c_str(), right.c_str()) == 0; }
    template<typename T> void Append(std::vector<T>& target, std::vector<T> source)
    {
        target.insert(target.end(), std::make_move_iterator(source.begin()), std::make_move_iterator(source.end()));
    }
}

namespace DisplaySwitcher::Native
{
    V2StateMachine::V2StateMachine(V2StateInitial initial) :
        localEndpointId_(std::move(initial.localEndpointId)), coordinationEnabled_(initial.coordinationEnabled),
        state_(initial.state), activeEventId_(std::move(initial.activeEventId)),
        lockedTargetEndpointId_(std::move(initial.lockedTargetEndpointId)), enabledTargets_(std::move(initial.enabledTargets))
    {
    }

    V2Target const* V2StateMachine::FindTarget(std::wstring const& endpointId) const
    {
        auto found = std::find_if(enabledTargets_.begin(), enabledTargets_.end(), [&](auto const& target) { return Equal(target.endpointId, endpointId); });
        return found == enabledTargets_.end() ? nullptr : &*found;
    }

    bool V2StateMachine::Seen(std::wstring const& type, std::wstring const& endpointId, std::wstring const& eventId)
    {
        auto key = type + L"|" + endpointId + L"|" + eventId;
        return !seenMessages_.insert(std::move(key)).second;
    }

    void V2StateMachine::CancelTimers()
    {
        retryDueMs_.reset(); fallbackDueMs_.reset(); requestCount_ = 0;
    }

    std::vector<V2Action> V2StateMachine::Clear(std::wstring const& reason, V2CoordinatorState finalState)
    {
        CancelTimers(); activeEventId_.clear(); lockedTargetEndpointId_.clear(); incomingIntent_.clear(); state_ = finalState;
        return { { V2Action::Kind::ClearEvent, {}, {}, {}, reason } };
    }

    std::vector<V2Action> V2StateMachine::OnStatusProbe(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated)
    {
        if (!coordinationEnabled_ || !authenticated) return {};
        return { { V2Action::Kind::SetPeerReachable, {}, {}, endpointId, {}, {}, {}, {}, true },
            { V2Action::Kind::SendMessage, L"status_response", eventId, endpointId } };
    }

    std::vector<V2Action> V2StateMachine::StartDirected(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, std::wstring const& intent)
    {
        auto target = FindTarget(endpointId);
        if (!coordinationEnabled_ || !target || target->protocolVersion != 2) return {};
        CancelTimers(); activeEventId_ = eventId; lockedTargetEndpointId_ = endpointId; incomingIntent_ = intent;
        state_ = target->reachable ? V2CoordinatorState::AwaitingReady : V2CoordinatorState::Switching;
        requestCount_ = 1;
        if (target->reachable) retryDueMs_ = nowMs + RetryMilliseconds;
        auto actions = std::vector<V2Action>{ { V2Action::Kind::LockTarget, {}, {}, endpointId },
            { V2Action::Kind::SendMessage, L"handover_request", eventId, endpointId, {}, intent } };
        if (!target->reachable)
        {
            actions.push_back({ V2Action::Kind::PromptManualSelection, {}, eventId, endpointId, L"peer_unavailable" });
            Append(actions, Clear(L"peer_unavailable", V2CoordinatorState::Cancelled));
        }
        return actions;
    }

    std::vector<V2Action> V2StateMachine::OnManualSelect(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId)
    {
        return StartDirected(nowMs, endpointId, eventId, L"manual");
    }

    std::vector<V2Action> V2StateMachine::OnWakeDisplay(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (Seen(L"wake_display", endpointId, eventId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, {}, L"duplicate" } };
        if (!FindTarget(endpointId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"endpoint_changed" } };
        return { { V2Action::Kind::RequestWake, {}, eventId } };
    }

    std::vector<V2Action> V2StateMachine::OnHandoverRequest(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, std::wstring const& intent)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (Seen(L"handover_request", endpointId, eventId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, {}, L"duplicate" } };
        if (!FindTarget(endpointId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"endpoint_changed" } };
        if (intent != L"manual") return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"invalid_intent" } };
        activeEventId_ = eventId; lockedTargetEndpointId_ = endpointId; incomingIntent_ = intent;
        state_ = V2CoordinatorState::AwaitingReady;
        return { { V2Action::Kind::RequestWake, {}, eventId } };
    }

    std::vector<V2Action> V2StateMachine::OnTargetReady(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, bool)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (state_ != V2CoordinatorState::AwaitingReady || !Equal(activeEventId_, eventId) || !Equal(lockedTargetEndpointId_, endpointId))
            return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"no_pending_event" } };
        CancelTimers(); state_ = V2CoordinatorState::Switching;
        return { { V2Action::Kind::RequestSwitch, {}, eventId, endpointId } };
    }

    std::vector<V2Action> V2StateMachine::OnCommitted(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, bool)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (Seen(L"committed", endpointId, eventId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, {}, L"duplicate" } };
        if (!Equal(activeEventId_, eventId) || !Equal(lockedTargetEndpointId_, endpointId))
            return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"no_pending_event" } };
        return Clear({}, V2CoordinatorState::Completed);
    }

    std::vector<V2Action> V2StateMachine::OnCancelled(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, std::wstring const& reason)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (!Equal(activeEventId_, eventId) || !Equal(lockedTargetEndpointId_, endpointId))
            return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"no_pending_event" } };
        return Clear(reason, V2CoordinatorState::Cancelled);
    }

    void V2StateMachine::SetTargetReachable(std::wstring const& endpointId, bool reachable)
    {
        auto found = std::find_if(enabledTargets_.begin(), enabledTargets_.end(), [&](auto const& target) { return Equal(target.endpointId, endpointId); });
        if (found != enabledTargets_.end()) found->reachable = reachable;
    }

    std::vector<V2Action> V2StateMachine::OnWakeCompleted(int64_t, std::wstring const& eventId, bool success)
    {
        if (!Equal(activeEventId_, eventId) || state_ != V2CoordinatorState::AwaitingReady) return {};
        state_ = V2CoordinatorState::AwaitingCommit;
        return { { V2Action::Kind::SendMessage, L"target_ready", activeEventId_, lockedTargetEndpointId_, {}, {}, success } };
    }

    std::vector<V2Action> V2StateMachine::OnSwitchCompleted(int64_t, std::wstring const& eventId, bool success)
    {
        if (state_ != V2CoordinatorState::Switching || !Equal(activeEventId_, eventId)) return {};
        auto endpoint = lockedTargetEndpointId_;
        auto actions = std::vector<V2Action>{ { V2Action::Kind::SendMessage, L"committed", eventId, endpoint, {}, {}, {}, success } };
        Append(actions, Clear({}, V2CoordinatorState::Completed)); return actions;
    }

    std::vector<V2Action> V2StateMachine::OnConfigurationChanged(int64_t)
    {
        if (activeEventId_.empty() && state_ == V2CoordinatorState::Idle) return {};
        return Clear(L"configuration_changed", V2CoordinatorState::Cancelled);
    }

    std::vector<V2Action> V2StateMachine::Advance(int64_t nowMs, bool includeExactDue)
    {
        auto due = [&](std::optional<int64_t> value) { return value && (nowMs > *value || (includeExactDue && nowMs == *value)); };
        std::vector<V2Action> actions;
        if (due(retryDueMs_))
        {
            retryDueMs_.reset();
            if (state_ == V2CoordinatorState::AwaitingReady && !activeEventId_.empty() && requestCount_ < MaximumRequests)
            {
                actions.push_back({ V2Action::Kind::SendMessage, L"handover_request", activeEventId_, lockedTargetEndpointId_, {}, L"manual" });
                ++requestCount_;
                if (requestCount_ < MaximumRequests) retryDueMs_ = nowMs + RetryMilliseconds;
                else fallbackDueMs_ = nowMs + RetryMilliseconds;
            }
        }
        if (due(fallbackDueMs_))
        {
            fallbackDueMs_.reset();
            if (state_ == V2CoordinatorState::AwaitingReady && !activeEventId_.empty())
            {
                state_ = V2CoordinatorState::Switching;
                actions.push_back({ V2Action::Kind::RequestSwitch, {}, activeEventId_, lockedTargetEndpointId_ });
            }
        }
        return actions;
    }

    std::wstring V2StateName(V2CoordinatorState state)
    {
        switch (state)
        {
        case V2CoordinatorState::Idle: return L"idle";
        case V2CoordinatorState::AwaitingReady: return L"awaiting_ready"; case V2CoordinatorState::AwaitingCommit: return L"awaiting_commit";
        case V2CoordinatorState::Switching: return L"switching"; case V2CoordinatorState::Completed: return L"completed";
        case V2CoordinatorState::Cancelled: return L"cancelled";
        }
        return L"idle";
    }
}
