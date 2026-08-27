#pragma once

#include <optional>
#include <set>
#include <string>
#include <vector>

namespace DisplaySwitcher::Native
{
    enum class V2CoordinatorState { Idle, Debouncing, Discovering, AwaitingInput, AwaitingReady, AwaitingCommit, Switching, Completed, Cancelled };

    struct V2Target
    {
        std::wstring endpointId;
        int protocolVersion{ 2 };
        bool reachable{};
    };

    struct V2StateInitial
    {
        std::wstring localEndpointId;
        bool coordinationEnabled{};
        bool sourceInputPresent{};
        bool targetInputPresent{};
        V2CoordinatorState state{ V2CoordinatorState::Idle };
        std::wstring activeEventId;
        std::wstring lockedTargetEndpointId;
        std::vector<V2Target> enabledTargets;
    };

    struct V2Action
    {
        enum class Kind { SendMessage, RequestWake, RequestSwitch, LockTarget, StartDiscovery, PromptManualSelection, IgnoreMessage, ClearEvent, RouteToV1, SetPeerReachable };
        Kind kind{};
        std::wstring type;
        std::wstring eventId;
        std::wstring endpointId;
        std::wstring reason;
        std::wstring intent;
        std::optional<bool> wakeSucceeded;
        std::optional<bool> switchSucceeded;
        bool value{};
    };

    struct V2StateSnapshot
    {
        V2CoordinatorState state{};
        std::wstring activeEventId;
        std::wstring lockedTargetEndpointId;
    };

    class V2StateMachine final
    {
    public:
        explicit V2StateMachine(V2StateInitial initial);
        std::vector<V2Action> OnStatusProbe(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated);
        std::vector<V2Action> OnManualSelect(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId);
        std::vector<V2Action> OnSourceInputPresenceChanged(int64_t nowMs, bool present, std::wstring const& eventId = {});
        std::vector<V2Action> OnTargetInputPresenceChanged(int64_t nowMs, bool present, std::wstring const& eventId = {});
        std::vector<V2Action> OnPeerInputPresent(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated);
        std::vector<V2Action> OnHandoverRequest(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, std::wstring const& intent);
        std::vector<V2Action> OnTargetReady(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, bool wakeSucceeded);
        std::vector<V2Action> OnCommitted(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, bool switchSucceeded);
        std::vector<V2Action> OnCancelled(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, bool authenticated, std::wstring const& reason);
        void SetTargetReachable(std::wstring const& endpointId, bool reachable);
        std::vector<V2Action> OnWakeCompleted(int64_t nowMs, std::wstring const& eventId, bool success);
        std::vector<V2Action> OnSwitchCompleted(int64_t nowMs, std::wstring const& eventId, bool success);
        std::vector<V2Action> OnConfigurationChanged(int64_t nowMs);
        std::vector<V2Action> OnV1Message(int64_t nowMs, int version);
        std::vector<V2Action> Advance(int64_t nowMs, bool includeExactDue = true);
        V2StateSnapshot Snapshot() const { return { state_, activeEventId_, lockedTargetEndpointId_ }; }

    private:
        V2Target const* FindTarget(std::wstring const& endpointId) const;
        std::vector<V2Action> StartDirected(int64_t nowMs, std::wstring const& endpointId, std::wstring const& eventId, std::wstring const& intent);
        std::vector<V2Action> Clear(std::wstring const& reason, V2CoordinatorState finalState);
        bool Seen(std::wstring const& type, std::wstring const& endpointId, std::wstring const& eventId);
        void CancelTimers();

        std::wstring localEndpointId_;
        bool coordinationEnabled_{};
        bool sourceInputPresent_{};
        bool targetInputPresent_{};
        V2CoordinatorState state_{ V2CoordinatorState::Idle };
        std::wstring activeEventId_;
        std::wstring lockedTargetEndpointId_;
        std::vector<V2Target> enabledTargets_;
        std::optional<int64_t> debounceDueMs_;
        std::optional<int64_t> discoveryDueMs_;
        std::optional<int64_t> retryDueMs_;
        std::optional<int64_t> fallbackDueMs_;
        int requestCount_{};
        std::wstring incomingIntent_;
        std::optional<bool> wakeResult_;
        std::set<std::wstring> seenMessages_;
    };

    std::wstring V2StateName(V2CoordinatorState state);
}
