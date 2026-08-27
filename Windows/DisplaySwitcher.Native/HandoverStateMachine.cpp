#include "pch.h"
#include "HandoverStateMachine.h"

namespace
{
    constexpr int64_t MessageWindowMs = 10000;
    constexpr int64_t PeerReachableWindowMs = 6000;
    constexpr int64_t UsbDebounceMs = 150;
    constexpr int64_t RetryIntervalMs = 150;
    constexpr int MaxOutgoingAttempts = 4;

    std::wstring Lower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), ::towlower);
        return value;
    }

    template<typename T>
    void Append(std::vector<T>& destination, std::vector<T> source)
    {
        destination.insert(destination.end(), std::make_move_iterator(source.begin()), std::make_move_iterator(source.end()));
    }
}

namespace DisplaySwitcher::Native
{
    HandoverStateMachine::HandoverStateMachine(StateMachineConfig config,
        std::function<std::wstring()> eventIdGenerator) :
        HandoverStateMachine(config, StateMachineInitialState{
            .localPlatform = config.localPlatform,
            .coordinationEnabled = config.coordinationEnabled,
            .usbAutomationEnabled = config.usbAutomationEnabled,
            .nextEventIds = config.nextEventIds,
        }, std::move(eventIdGenerator))
    {
    }

    HandoverStateMachine::HandoverStateMachine(StateMachineConfig config,
        StateMachineInitialState const& initialState, std::function<std::wstring()> eventIdGenerator) :
        coordinationEnabled_(initialState.coordinationEnabled),
        usbAutomationEnabled_(initialState.usbAutomationEnabled),
        localPlatform_(Lower(initialState.localPlatform.empty() ? config.localPlatform : initialState.localPlatform)),
        pairingCode_(config.pairingCode),
        timeOriginUnixSeconds_(config.timeOriginUnixSeconds),
        eventIdGenerator_(std::move(eventIdGenerator)),
        nextEventIds_(initialState.nextEventIds.empty() ? config.nextEventIds : initialState.nextEventIds),
        usbPresent_(initialState.usbPresent),
        peerReachable_(initialState.peerReachable),
        peerLastSeenAtMs_(initialState.peerLastSeenAtMs),
        newestIncomingRequestTimestamp_(initialState.newestIncomingRequestTimestamp),
        incomingEventId_(Lower(initialState.incomingEventId)),
        outgoingEventId_(Lower(initialState.outgoingEventId))
    {
        for (auto const& [type, eventId, seenAtMs] : initialState.seenMessages)
            seenMessages_.push_back({ type, Lower(eventId), seenAtMs });
    }

    void HandoverStateMachine::Configure(StateMachineConfig const& config)
    {
        localPlatform_ = Lower(config.localPlatform);
        pairingCode_ = config.pairingCode;
        timeOriginUnixSeconds_ = config.timeOriginUnixSeconds;
        if (!config.nextEventIds.empty()) nextEventIds_ = config.nextEventIds;
        coordinationEnabled_ = config.coordinationEnabled;
        usbAutomationEnabled_ = config.usbAutomationEnabled;
    }

    bool HandoverStateMachine::IsKnownType(std::wstring const& type)
    {
        return type == L"handover_request" || type == L"usb_present" ||
            type == L"usb_attached_and_awake" || type == L"committed" ||
            type == L"status_probe" || type == L"status_response";
    }

    bool HandoverStateMachine::IsValidUuid(std::wstring const& value)
    {
        if (value.size() != 36) return false;
        for (size_t index = 0; index < value.size(); ++index)
        {
            if (index == 8 || index == 13 || index == 18 || index == 23)
            {
                if (value[index] != L'-') return false;
            }
            else if (!iswxdigit(value[index])) return false;
        }
        return true;
    }

    std::wstring HandoverStateMachine::RejectReasonText(StateMachineRejectReason reason)
    {
        switch (reason)
        {
        case StateMachineRejectReason::Duplicate: return L"duplicate";
        case StateMachineRejectReason::OutOfOrder: return L"out_of_order";
        case StateMachineRejectReason::StaleEvent: return L"stale_event";
        case StateMachineRejectReason::InvalidMessage: return L"invalid_message";
        case StateMachineRejectReason::NoPendingEvent: return L"no_pending_event";
        default: return {};
        }
    }

    std::wstring HandoverStateMachine::RemotePlatform() const
    {
        return localPlatform_ == L"windows" ? L"mac" : L"windows";
    }

    bool HandoverStateMachine::ValidateMessage(PeerMessage const& message, int64_t nowMs) const
    {
        if (message.version != 1 || !IsKnownType(message.type) || !IsValidUuid(message.eventId)) return false;
        if (Lower(message.source) != RemotePlatform() || Lower(message.target) != localPlatform_) return false;
        if (message.pairingCode != pairingCode_ || pairingCode_.size() < 8 || !std::isfinite(message.timestamp)) return false;
        double const now = timeOriginUnixSeconds_ + static_cast<double>(nowMs) / 1000.0;
        return std::abs(message.timestamp - now) <= 10.0 + 1e-9;
    }

    bool HandoverStateMachine::IsMessageDuplicate(std::wstring const& type,
        std::wstring const& eventId, int64_t nowMs) const
    {
        return std::any_of(seenMessages_.begin(), seenMessages_.end(), [&](SeenMessage const& seen)
        {
            return seen.type == type && seen.eventId == eventId && nowMs - seen.seenAtMs <= MessageWindowMs;
        });
    }

    void HandoverStateMachine::RegisterSeenMessage(std::wstring const& type,
        std::wstring const& eventId, int64_t nowMs)
    {
        while (!seenMessages_.empty() && nowMs - seenMessages_.front().seenAtMs > MessageWindowMs)
            seenMessages_.pop_front();
        seenMessages_.push_back({ type, eventId, nowMs });
    }

    std::wstring HandoverStateMachine::GetNextEventId()
    {
        if (nextEventIdCursor_ < nextEventIds_.size()) return Lower(nextEventIds_[nextEventIdCursor_++]);
        return eventIdGenerator_ ? Lower(eventIdGenerator_()) : std::wstring{};
    }

    void HandoverStateMachine::CancelOutgoingState()
    {
        outgoingEventId_.clear();
        outgoingRetryDueMs_.reset();
        outgoingFallbackDueMs_.reset();
        outgoingRequestCount_ = 0;
    }

    std::vector<StateMachineAction> HandoverStateMachine::DisableAndClear(bool coordinationEnabled)
    {
        std::vector<StateMachineAction> actions;
        if (!outgoingEventId_.empty())
            actions.push_back({ StateMachineAction::Kind::CancelOutgoing, {}, outgoingEventId_ });
        coordinationEnabled_ = coordinationEnabled;
        CancelOutgoingState();
        usbDebounceDueMs_.reset();
        waitingForSwitchEventId_.reset();
        incomingWakeRequestEventId_.reset();
        usbArrivalWakeEventId_.reset();
        incomingWakeSucceeded_.reset();
        incomingEventId_.clear();
        newestIncomingRequestTimestamp_.reset();
        seenMessages_.clear();
        peerReachable_ = false;
        peerLastSeenAtMs_.reset();
        actions.push_back({ StateMachineAction::Kind::SetPeerReachable, {}, {}, false });
        return actions;
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnCoordinationEnabledChanged(int64_t, bool enabled)
    {
        if (coordinationEnabled_ == enabled) return {};
        if (!enabled) return DisableAndClear(false);
        coordinationEnabled_ = true;
        return {};
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnUsbAutomationEnabledChanged(int64_t, bool enabled)
    {
        if (usbAutomationEnabled_ == enabled) return {};
        usbAutomationEnabled_ = enabled;
        if (!enabled) return DisableAndClear(coordinationEnabled_);
        return {};
    }

    std::vector<StateMachineAction> HandoverStateMachine::StartOutgoing(int64_t nowMs)
    {
        std::vector<StateMachineAction> actions;
        if (!coordinationEnabled_)
        {
            actions.push_back({ StateMachineAction::Kind::RequestSwitch });
            return actions;
        }
        outgoingEventId_ = GetNextEventId();
        if (outgoingEventId_.empty()) return actions;
        actions.push_back({ StateMachineAction::Kind::SendMessage, L"handover_request", outgoingEventId_ });
        outgoingRequestCount_ = 1;
        if (!peerReachable_)
        {
            actions.push_back({ StateMachineAction::Kind::RequestSwitch, {}, outgoingEventId_ });
            waitingForSwitchEventId_ = outgoingEventId_;
            CancelOutgoingState();
        }
        else outgoingRetryDueMs_ = nowMs + RetryIntervalMs;
        return actions;
    }

    std::vector<StateMachineAction> HandoverStateMachine::CompleteOutgoingWithSwitch()
    {
        if (outgoingEventId_.empty()) return {};
        auto eventId = outgoingEventId_;
        waitingForSwitchEventId_ = eventId;
        CancelOutgoingState();
        return { { StateMachineAction::Kind::RequestSwitch, {}, eventId } };
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnUsbPresenceChanged(int64_t nowMs, bool present)
    {
        usbPresent_ = present;
        if (!usbAutomationEnabled_) return {};
        std::vector<StateMachineAction> actions;
        if (!present)
        {
            usbDebounceDueMs_ = nowMs + UsbDebounceMs;
            return actions;
        }
        if (!coordinationEnabled_) return actions;
        usbDebounceDueMs_.reset();
        if (!outgoingEventId_.empty())
        {
            actions.push_back({ StateMachineAction::Kind::CancelOutgoing, {}, outgoingEventId_ });
            CancelOutgoingState();
        }
        auto eventId = GetNextEventId();
        if (!eventId.empty())
        {
            usbArrivalWakeEventId_ = eventId;
            actions.push_back({ StateMachineAction::Kind::RequestWake, {}, eventId });
        }
        return actions;
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnWakeCompleted(
        int64_t, std::wstring const& eventIdValue, bool success)
    {
        std::vector<StateMachineAction> actions;
        auto const eventId = Lower(eventIdValue);
        if (incomingWakeRequestEventId_ && *incomingWakeRequestEventId_ == eventId)
        {
            incomingWakeRequestEventId_.reset();
            incomingWakeSucceeded_ = success;
            if (usbPresent_ && !incomingEventId_.empty())
                actions.push_back({ StateMachineAction::Kind::SendBurst, L"usb_attached_and_awake", incomingEventId_, false, success, 3 });
        }
        if (usbArrivalWakeEventId_ && *usbArrivalWakeEventId_ == eventId)
        {
            usbArrivalWakeEventId_.reset();
            actions.push_back({ StateMachineAction::Kind::SendBurst, L"usb_present", eventId, false, success, 3 });
            if (!incomingEventId_.empty() && incomingWakeSucceeded_)
                actions.push_back({ StateMachineAction::Kind::SendBurst, L"usb_attached_and_awake", incomingEventId_, false, *incomingWakeSucceeded_, 3 });
        }
        return actions;
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnSwitchCompleted(
        int64_t, std::wstring const& eventIdValue, bool success)
    {
        auto const eventId = Lower(eventIdValue);
        if (!waitingForSwitchEventId_ || *waitingForSwitchEventId_ != eventId) return {};
        waitingForSwitchEventId_.reset();
        return { { StateMachineAction::Kind::SendMessage, L"committed", eventId, false, success } };
    }

    std::vector<StateMachineAction> HandoverStateMachine::OnPeerMessage(int64_t nowMs, PeerMessage const& message)
    {
        if (!coordinationEnabled_ || !usbAutomationEnabled_ || !ValidateMessage(message, nowMs)) return {};
        auto const eventId = Lower(message.eventId);
        if (IsMessageDuplicate(message.type, eventId, nowMs))
        {
            peerReachable_ = true;
            peerLastSeenAtMs_ = nowMs;
            std::vector<StateMachineAction> actions{
                { StateMachineAction::Kind::RejectMessage, {}, {}, false, false, 1, StateMachineRejectReason::Duplicate }
            };
            if (message.type == L"handover_request" && incomingEventId_ == eventId && usbPresent_ && incomingWakeSucceeded_)
                actions.push_back({ StateMachineAction::Kind::SendBurst, L"usb_attached_and_awake", eventId, false, *incomingWakeSucceeded_, 3 });
            return actions;
        }

        RegisterSeenMessage(message.type, eventId, nowMs);
        peerReachable_ = true;
        peerLastSeenAtMs_ = nowMs;
        std::vector<StateMachineAction> actions{
            { StateMachineAction::Kind::AcceptMessage, message.type, eventId },
            { StateMachineAction::Kind::SetPeerReachable, {}, {}, true }
        };
        if (message.type == L"status_probe")
            actions.push_back({ StateMachineAction::Kind::SendMessage, L"status_response", eventId });
        else if (message.type == L"handover_request")
        {
            if (newestIncomingRequestTimestamp_ && message.timestamp < *newestIncomingRequestTimestamp_)
                actions.push_back({ StateMachineAction::Kind::RejectMessage, {}, {}, false, false, 1, StateMachineRejectReason::OutOfOrder });
            else
            {
                newestIncomingRequestTimestamp_ = message.timestamp;
                incomingEventId_ = eventId;
                incomingWakeSucceeded_.reset();
                incomingWakeRequestEventId_ = eventId;
                actions.push_back({ StateMachineAction::Kind::RequestWake, {}, eventId });
            }
        }
        else if (message.type == L"usb_present")
        {
            auto completed = CompleteOutgoingWithSwitch();
            if (completed.empty()) actions.push_back({ StateMachineAction::Kind::RejectMessage, {}, {}, false, false, 1, StateMachineRejectReason::NoPendingEvent });
            else Append(actions, std::move(completed));
        }
        else if (message.type == L"usb_attached_and_awake")
        {
            if (outgoingEventId_ == eventId) Append(actions, CompleteOutgoingWithSwitch());
            else actions.push_back({ StateMachineAction::Kind::RejectMessage, {}, {}, false, false, 1, StateMachineRejectReason::StaleEvent });
        }
        else if (message.type == L"committed")
        {
            if (incomingEventId_ == eventId) incomingEventId_.clear();
            else actions.push_back({ StateMachineAction::Kind::RejectMessage, {}, {}, false, false, 1, StateMachineRejectReason::StaleEvent });
        }
        return actions;
    }

    std::vector<StateMachineAction> HandoverStateMachine::Advance(int64_t nowMs, bool includeExactDue)
    {
        std::vector<StateMachineAction> actions;
        auto due = [&](std::optional<int64_t> value) { return value && (nowMs > *value || (includeExactDue && nowMs == *value)); };
        if (coordinationEnabled_ && peerReachable_ && peerLastSeenAtMs_ && nowMs - *peerLastSeenAtMs_ > PeerReachableWindowMs)
        {
            peerReachable_ = false;
            actions.push_back({ StateMachineAction::Kind::SetPeerReachable, {}, {}, false });
        }
        if (!usbAutomationEnabled_) return actions;
        if (due(usbDebounceDueMs_))
        {
            usbDebounceDueMs_.reset();
            if (!usbPresent_) Append(actions, StartOutgoing(nowMs));
        }
        if (due(outgoingRetryDueMs_))
        {
            outgoingRetryDueMs_.reset();
            if (!outgoingEventId_.empty() && outgoingRequestCount_ < MaxOutgoingAttempts)
            {
                actions.push_back({ StateMachineAction::Kind::SendMessage, L"handover_request", outgoingEventId_ });
                ++outgoingRequestCount_;
                if (outgoingRequestCount_ < MaxOutgoingAttempts) outgoingRetryDueMs_ = nowMs + RetryIntervalMs;
                else outgoingFallbackDueMs_ = nowMs + RetryIntervalMs;
            }
        }
        if (due(outgoingFallbackDueMs_))
        {
            outgoingFallbackDueMs_.reset();
            Append(actions, CompleteOutgoingWithSwitch());
        }
        return actions;
    }

    StateMachineSnapshot HandoverStateMachine::Snapshot() const
    {
        return { coordinationEnabled_, usbAutomationEnabled_, usbPresent_, peerReachable_, peerLastSeenAtMs_,
            incomingEventId_, outgoingEventId_, newestIncomingRequestTimestamp_, static_cast<int>(seenMessages_.size()) };
    }
}
