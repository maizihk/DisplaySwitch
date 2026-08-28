#include "pch.h"
#include "V2StateMachine.h"

namespace
{
    constexpr int64_t DebounceMilliseconds = 150;
    constexpr int64_t RetryMilliseconds = 150;
    constexpr int64_t DiscoveryMilliseconds = 3000;
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
        sourceInputPresent_(initial.sourceInputPresent), targetInputPresent_(initial.targetInputPresent),
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
        debounceDueMs_.reset(); discoveryDueMs_.reset(); retryDueMs_.reset(); fallbackDueMs_.reset(); requestCount_ = 0;
    }

    std::vector<V2Action> V2StateMachine::Clear(std::wstring const& reason, V2CoordinatorState finalState)
    {
        CancelTimers(); activeEventId_.clear(); lockedTargetEndpointId_.clear(); incomingIntent_.clear(); wakeResult_.reset(); state_ = finalState;
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
        if (!target->reachable && intent == L"input_handover")
            actions.push_back({ V2Action::Kind::RequestSwitch, {}, eventId, endpointId });
        else if (!target->reachable)
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

    std::vector<V2Action> V2StateMachine::OnSourceInputPresenceChanged(int64_t nowMs, bool present, std::wstring const& eventId)
    {
        sourceInputPresent_ = present;
        if (!coordinationEnabled_) return {};
        if (!present)
        {
            if (state_ == V2CoordinatorState::Idle || state_ == V2CoordinatorState::Completed || state_ == V2CoordinatorState::Cancelled)
            {
                state_ = V2CoordinatorState::Debouncing; activeEventId_ = eventId; debounceDueMs_ = nowMs + DebounceMilliseconds;
            }
            return {};
        }
        if (state_ == V2CoordinatorState::Debouncing) return Clear({}, V2CoordinatorState::Cancelled);
        if (state_ == V2CoordinatorState::Discovering) return Clear(L"source_input_returned", V2CoordinatorState::Cancelled);
        if ((state_ == V2CoordinatorState::AwaitingReady || state_ == V2CoordinatorState::Switching) && !activeEventId_.empty())
        {
            auto event = activeEventId_, endpoint = lockedTargetEndpointId_;
            auto actions = std::vector<V2Action>{ { V2Action::Kind::SendMessage, L"cancelled", event, endpoint, L"source_input_returned" } };
            Append(actions, Clear(L"source_input_returned", V2CoordinatorState::Cancelled)); return actions;
        }
        return {};
    }

    std::vector<V2Action> V2StateMachine::OnTargetInputPresenceChanged(int64_t, bool present, std::wstring const& eventId)
    {
        targetInputPresent_ = present;
        std::vector<V2Action> actions;
        if (present && state_ == V2CoordinatorState::Idle && !eventId.empty())
            for (auto const& target : enabledTargets_) if (target.protocolVersion == 2)
                actions.push_back({ V2Action::Kind::SendMessage, L"input_present", eventId, target.endpointId });
        if (present && state_ == V2CoordinatorState::AwaitingInput && wakeResult_ && !activeEventId_.empty())
        {
            actions.push_back({ V2Action::Kind::SendMessage, L"target_ready", activeEventId_, lockedTargetEndpointId_, {}, {}, *wakeResult_ });
            state_ = V2CoordinatorState::AwaitingCommit;
        }
        return actions;
    }

    std::vector<V2Action> V2StateMachine::OnPeerInputPresent(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (state_ != V2CoordinatorState::Discovering)
            return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"late_target" } };
        auto target = FindTarget(endpointId);
        if (!target) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"endpoint_changed" } };
        if (target->protocolVersion != 2) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"v1_not_eligible" } };
        discoveryDueMs_.reset();
        return StartDirected(nowMs, endpointId, eventId, L"input_handover");
    }

    std::vector<V2Action> V2StateMachine::OnHandoverRequest(int64_t, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, std::wstring const& intent)
    {
        if (!authenticated) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"authentication_failed" } };
        if (Seen(L"handover_request", endpointId, eventId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, {}, L"duplicate" } };
        if (!FindTarget(endpointId)) return { { V2Action::Kind::IgnoreMessage, {}, eventId, endpointId, L"endpoint_changed" } };
        activeEventId_ = eventId; lockedTargetEndpointId_ = endpointId; incomingIntent_ = intent; wakeResult_.reset();
        state_ = intent == L"manual" ? V2CoordinatorState::AwaitingReady : V2CoordinatorState::AwaitingInput;
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
        if (!Equal(activeEventId_, eventId) || (state_ != V2CoordinatorState::AwaitingReady && state_ != V2CoordinatorState::AwaitingInput)) return {};
        wakeResult_ = success;
        if (incomingIntent_ == L"manual" || (incomingIntent_ == L"input_handover" && targetInputPresent_))
        {
            state_ = V2CoordinatorState::AwaitingCommit;
            return { { V2Action::Kind::SendMessage, L"target_ready", activeEventId_, lockedTargetEndpointId_, {}, {}, success } };
        }
        return {};
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
        if (due(debounceDueMs_))
        {
            debounceDueMs_.reset();
            if (!sourceInputPresent_)
            {
                std::vector<V2Target const*> v2;
                for (auto const& target : enabledTargets_) if (target.protocolVersion == 2) v2.push_back(&target);
                if (enabledTargets_.size() == 1 && v2.size() == 1)
                {
                    auto event = activeEventId_; if (event.empty()) return actions;
                    Append(actions, StartDirected(nowMs, v2.front()->endpointId, event, L"input_handover"));
                }
                else if (enabledTargets_.size() > 1 && !v2.empty())
                {
                    activeEventId_.clear(); state_ = V2CoordinatorState::Discovering;
                    discoveryDueMs_ = nowMs + DiscoveryMilliseconds;
                    actions.push_back({ V2Action::Kind::StartDiscovery });
                }
                else { state_ = V2CoordinatorState::Cancelled; activeEventId_.clear(); }
            }
        }
        if (due(retryDueMs_))
        {
            retryDueMs_.reset();
            if (state_ == V2CoordinatorState::AwaitingReady && !activeEventId_.empty() && requestCount_ < MaximumRequests)
            {
                actions.push_back({ V2Action::Kind::SendMessage, L"handover_request", activeEventId_, lockedTargetEndpointId_, {}, incomingIntent_.empty() ? L"input_handover" : incomingIntent_ });
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
        if (due(discoveryDueMs_))
        {
            discoveryDueMs_.reset();
            if (state_ == V2CoordinatorState::Discovering)
            {
                state_ = V2CoordinatorState::Cancelled;
                actions.push_back({ V2Action::Kind::PromptManualSelection, {}, {}, {}, L"discovery_timeout" });
                Append(actions, Clear({}, V2CoordinatorState::Cancelled));
            }
        }
        return actions;
    }

    std::wstring V2StateName(V2CoordinatorState state)
    {
        switch (state)
        {
        case V2CoordinatorState::Idle: return L"idle"; case V2CoordinatorState::Debouncing: return L"debouncing";
        case V2CoordinatorState::Discovering: return L"discovering"; case V2CoordinatorState::AwaitingInput: return L"awaiting_input";
        case V2CoordinatorState::AwaitingReady: return L"awaiting_ready"; case V2CoordinatorState::AwaitingCommit: return L"awaiting_commit";
        case V2CoordinatorState::Switching: return L"switching"; case V2CoordinatorState::Completed: return L"completed";
        case V2CoordinatorState::Cancelled: return L"cancelled";
        }
        return L"idle";
    }
}
