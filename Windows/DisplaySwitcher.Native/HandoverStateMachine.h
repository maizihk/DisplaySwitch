#pragma once

#include "ProtocolTypes.h"

#include <deque>
#include <functional>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

namespace DisplaySwitcher::Native
{
    enum class StateMachineRejectReason { None, Duplicate, OutOfOrder, StaleEvent, InvalidMessage, NoPendingEvent };

    struct StateMachineAction
    {
        enum class Kind { AcceptMessage, RejectMessage, SendMessage, SendBurst, RequestWake, RequestSwitch, SetPeerReachable, CancelOutgoing };
        Kind kind{};
        std::wstring type;
        std::wstring eventId;
        bool value{};
        bool wakeSucceeded{};
        int count{ 1 };
        StateMachineRejectReason reason{ StateMachineRejectReason::None };
    };

    struct StateMachineInitialState
    {
        std::wstring localPlatform;
        bool coordinationEnabled{};
        bool usbAutomationEnabled{};
        bool usbPresent{};
        bool peerReachable{};
        std::optional<int64_t> peerLastSeenAtMs;
        std::wstring incomingEventId;
        std::wstring outgoingEventId;
        std::optional<double> newestIncomingRequestTimestamp;
        std::vector<std::tuple<std::wstring, std::wstring, int64_t>> seenMessages;
        std::vector<std::wstring> nextEventIds;
    };

    struct StateMachineSnapshot
    {
        bool coordinationEnabled{};
        bool usbAutomationEnabled{};
        bool usbPresent{};
        bool peerReachable{};
        std::optional<int64_t> peerLastSeenAtMs;
        std::wstring incomingEventId;
        std::wstring outgoingEventId;
        std::optional<double> newestIncomingRequestTimestamp;
        int seenMessageCount{};
    };

    struct StateMachineConfig
    {
        std::wstring localPlatform;
        std::wstring pairingCode;
        bool coordinationEnabled{};
        bool usbAutomationEnabled{};
        double timeOriginUnixSeconds{};
        std::vector<std::wstring> nextEventIds;
    };

    class HandoverStateMachine
    {
    public:
        HandoverStateMachine(StateMachineConfig config, std::function<std::wstring()> eventIdGenerator);
        HandoverStateMachine(StateMachineConfig config, StateMachineInitialState const& initialState,
            std::function<std::wstring()> eventIdGenerator);
        void Configure(StateMachineConfig const& config);
        std::vector<StateMachineAction> OnUsbPresenceChanged(int64_t nowMs, bool present);
        std::vector<StateMachineAction> OnWakeCompleted(int64_t nowMs, std::wstring const& eventId, bool success);
        std::vector<StateMachineAction> OnSwitchCompleted(int64_t nowMs, std::wstring const& eventId, bool success);
        std::vector<StateMachineAction> OnCoordinationEnabledChanged(int64_t nowMs, bool enabled);
        std::vector<StateMachineAction> OnUsbAutomationEnabledChanged(int64_t nowMs, bool enabled);
        std::vector<StateMachineAction> Advance(int64_t nowMs, bool includeExactDue = true);
        std::vector<StateMachineAction> OnPeerMessage(int64_t nowMs, PeerMessage const& message);
        StateMachineSnapshot Snapshot() const;
        static std::wstring RejectReasonText(StateMachineRejectReason reason);
        static bool IsKnownType(std::wstring const& type);
        static bool IsValidUuid(std::wstring const& value);

    private:
        struct SeenMessage { std::wstring type; std::wstring eventId; int64_t seenAtMs{}; };
        std::vector<StateMachineAction> DisableAndClear(bool coordinationEnabled);
        std::vector<StateMachineAction> StartOutgoing(int64_t nowMs);
        std::vector<StateMachineAction> CompleteOutgoingWithSwitch();
        void CancelOutgoingState();
        void RegisterSeenMessage(std::wstring const& type, std::wstring const& eventId, int64_t nowMs);
        bool IsMessageDuplicate(std::wstring const& type, std::wstring const& eventId, int64_t nowMs) const;
        bool ValidateMessage(PeerMessage const& message, int64_t nowMs) const;
        std::wstring GetNextEventId();
        std::wstring RemotePlatform() const;

        bool coordinationEnabled_{};
        bool usbAutomationEnabled_{};
        std::wstring localPlatform_;
        std::wstring pairingCode_;
        double timeOriginUnixSeconds_{};
        std::function<std::wstring()> eventIdGenerator_;
        std::vector<std::wstring> nextEventIds_;
        size_t nextEventIdCursor_{};
        bool usbPresent_{};
        bool peerReachable_{};
        std::optional<int64_t> peerLastSeenAtMs_;
        std::optional<double> newestIncomingRequestTimestamp_;
        std::wstring incomingEventId_;
        std::wstring outgoingEventId_;
        std::optional<std::wstring> waitingForSwitchEventId_;
        std::optional<std::wstring> incomingWakeRequestEventId_;
        std::optional<std::wstring> usbArrivalWakeEventId_;
        std::optional<bool> incomingWakeSucceeded_;
        std::optional<int64_t> usbDebounceDueMs_;
        std::optional<int64_t> outgoingRetryDueMs_;
        std::optional<int64_t> outgoingFallbackDueMs_;
        int outgoingRequestCount_{};
        std::deque<SeenMessage> seenMessages_;
    };
}
