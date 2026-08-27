#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/HandoverStateMachine.h"
#include "../DisplaySwitcher.Native/ProtocolMessage.h"

#include <iostream>

using namespace DisplaySwitcher::Native;
using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    std::filesystem::path FindRepositoryRoot()
    {
        auto path = std::filesystem::current_path();
        for (int index = 0; index < 10; ++index)
        {
            if (std::filesystem::exists(path / L"contracts/protocol-v1/state-machine-vectors.json")) return path;
            if (!path.has_parent_path()) break;
            path = path.parent_path();
        }
        throw std::runtime_error("repository root not found");
    }

    JsonObject ReadJson(std::filesystem::path const& path)
    {
        std::ifstream stream(path, std::ios::binary);
        std::string bytes((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
        return JsonObject::Parse(to_hstring(bytes));
    }

    std::wstring OptionalString(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || object.GetNamedValue(name).ValueType() == JsonValueType::Null) return {};
        return object.GetNamedString(name).c_str();
    }

    std::optional<int64_t> OptionalInteger(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || object.GetNamedValue(name).ValueType() == JsonValueType::Null) return std::nullopt;
        return static_cast<int64_t>(object.GetNamedNumber(name));
    }

    std::optional<double> OptionalNumber(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || object.GetNamedValue(name).ValueType() == JsonValueType::Null) return std::nullopt;
        return object.GetNamedNumber(name);
    }

    StateMachineAction::Kind ActionKind(std::wstring const& value)
    {
        if (value == L"acceptMessage") return StateMachineAction::Kind::AcceptMessage;
        if (value == L"rejectMessage") return StateMachineAction::Kind::RejectMessage;
        if (value == L"sendMessage") return StateMachineAction::Kind::SendMessage;
        if (value == L"sendBurst") return StateMachineAction::Kind::SendBurst;
        if (value == L"requestWake") return StateMachineAction::Kind::RequestWake;
        if (value == L"requestSwitch") return StateMachineAction::Kind::RequestSwitch;
        if (value == L"setPeerReachable") return StateMachineAction::Kind::SetPeerReachable;
        if (value == L"cancelOutgoing") return StateMachineAction::Kind::CancelOutgoing;
        throw std::runtime_error("unknown action kind");
    }

    StateMachineRejectReason RejectReason(std::wstring const& value)
    {
        if (value == L"duplicate") return StateMachineRejectReason::Duplicate;
        if (value == L"out_of_order") return StateMachineRejectReason::OutOfOrder;
        if (value == L"stale_event") return StateMachineRejectReason::StaleEvent;
        if (value == L"no_pending_event") return StateMachineRejectReason::NoPendingEvent;
        return StateMachineRejectReason::None;
    }

    PeerMessage ParseMessage(JsonObject const& object)
    {
        PeerMessage message;
        message.version = static_cast<int>(object.GetNamedNumber(L"version"));
        message.type = object.GetNamedString(L"type").c_str();
        message.eventId = object.GetNamedString(L"eventID").c_str();
        message.source = object.GetNamedString(L"source").c_str();
        message.target = object.GetNamedString(L"target").c_str();
        message.timestamp = object.GetNamedNumber(L"timestamp");
        message.pairingCode = object.GetNamedString(L"pairingCode").c_str();
        if (object.HasKey(L"wakeSucceeded")) message.wakeSucceeded = object.GetNamedBoolean(L"wakeSucceeded");
        return message;
    }

    struct TimedAction { int64_t atMs{}; StateMachineAction action; };

    void Append(std::vector<TimedAction>& result, int64_t atMs, std::vector<StateMachineAction> const& actions)
    {
        for (auto const& action : actions) result.push_back({ atMs, action });
    }

    bool Matches(TimedAction const& actual, JsonObject const& expected)
    {
        if (actual.atMs != static_cast<int64_t>(expected.GetNamedNumber(L"atMs"))) return false;
        if (actual.action.kind != ActionKind(expected.GetNamedString(L"kind").c_str())) return false;
        if (expected.HasKey(L"type") && actual.action.type != expected.GetNamedString(L"type").c_str()) return false;
        if (expected.HasKey(L"eventID") && actual.action.eventId != expected.GetNamedString(L"eventID").c_str()) return false;
        if (expected.HasKey(L"value") && actual.action.value != expected.GetNamedBoolean(L"value")) return false;
        if (expected.HasKey(L"wakeSucceeded") && actual.action.wakeSucceeded != expected.GetNamedBoolean(L"wakeSucceeded")) return false;
        if (expected.HasKey(L"count") && actual.action.count != static_cast<int>(expected.GetNamedNumber(L"count"))) return false;
        if (expected.HasKey(L"reason") && actual.action.reason != RejectReason(expected.GetNamedString(L"reason").c_str())) return false;
        return true;
    }

    int RunVector(JsonObject const& vector, double referenceTime, std::wstring const& pairingCode)
    {
        auto const id = std::wstring(vector.GetNamedString(L"id"));
        auto initialJson = vector.GetNamedObject(L"initialState");
        StateMachineInitialState initial;
        initial.localPlatform = initialJson.GetNamedString(L"localPlatform").c_str();
        initial.coordinationEnabled = initialJson.GetNamedBoolean(L"coordinationEnabled");
        initial.usbAutomationEnabled = initialJson.GetNamedBoolean(L"usbAutomationEnabled");
        initial.usbPresent = initialJson.GetNamedBoolean(L"usbPresent");
        initial.peerReachable = initialJson.GetNamedBoolean(L"peerReachable");
        initial.peerLastSeenAtMs = OptionalInteger(initialJson, L"peerLastSeenAtMs");
        initial.incomingEventId = OptionalString(initialJson, L"incomingEventID");
        initial.outgoingEventId = OptionalString(initialJson, L"outgoingEventID");
        initial.newestIncomingRequestTimestamp = OptionalNumber(initialJson, L"newestIncomingRequestTimestamp");
        for (auto const& value : initialJson.GetNamedArray(L"seenMessages"))
        {
            auto object = value.GetObject();
            initial.seenMessages.emplace_back(object.GetNamedString(L"type").c_str(),
                object.GetNamedString(L"eventID").c_str(), static_cast<int64_t>(object.GetNamedNumber(L"seenAtMs")));
        }
        for (auto const& value : initialJson.GetNamedArray(L"nextEventIDs")) initial.nextEventIds.emplace_back(value.GetString());

        StateMachineConfig config{ initial.localPlatform, pairingCode, initial.coordinationEnabled,
            initial.usbAutomationEnabled, referenceTime, initial.nextEventIds };
        HandoverStateMachine machine(config, initial, [] { return std::wstring{}; });
        std::vector<TimedAction> actual;
        int64_t cursor = -1;
        for (auto const& stepValue : vector.GetNamedArray(L"steps"))
        {
            auto step = stepValue.GetObject();
            auto atMs = static_cast<int64_t>(step.GetNamedNumber(L"atMs"));
            for (int64_t tick = cursor + 1; tick <= atMs; ++tick) Append(actual, tick, machine.Advance(tick));
            cursor = atMs;
            auto input = step.GetNamedObject(L"input");
            auto kind = std::wstring(input.GetNamedString(L"kind"));
            if (kind == L"usbPresenceChanged") Append(actual, atMs, machine.OnUsbPresenceChanged(atMs, input.GetNamedBoolean(L"present")));
            else if (kind == L"receiveMessage") Append(actual, atMs, machine.OnPeerMessage(atMs, ParseMessage(input.GetNamedObject(L"message"))));
            else if (kind == L"wakeCompleted") Append(actual, atMs, machine.OnWakeCompleted(atMs, input.GetNamedString(L"eventID").c_str(), input.GetNamedBoolean(L"success")));
            else if (kind == L"switchCompleted") Append(actual, atMs, machine.OnSwitchCompleted(atMs, input.GetNamedString(L"eventID").c_str(), input.GetNamedBoolean(L"success")));
            else if (kind == L"coordinationChanged") Append(actual, atMs, machine.OnCoordinationEnabledChanged(atMs, input.GetNamedBoolean(L"enabled")));
        }

        auto expected = vector.GetNamedArray(L"expectedActions");
        int failures = actual.size() == expected.Size() ? 0 : 1;
        auto count = std::min<size_t>(actual.size(), expected.Size());
        for (size_t index = 0; index < count; ++index)
            if (!Matches(actual[index], expected.GetObjectAt(static_cast<uint32_t>(index)))) ++failures;

        auto final = vector.GetNamedObject(L"finalState");
        auto snapshot = machine.Snapshot();
        if (snapshot.coordinationEnabled != final.GetNamedBoolean(L"coordinationEnabled")) ++failures;
        if (snapshot.usbPresent != final.GetNamedBoolean(L"usbPresent")) ++failures;
        if (snapshot.peerReachable != final.GetNamedBoolean(L"peerReachable")) ++failures;
        if (snapshot.peerLastSeenAtMs != OptionalInteger(final, L"peerLastSeenAtMs")) ++failures;
        if (snapshot.incomingEventId != OptionalString(final, L"incomingEventID")) ++failures;
        if (snapshot.outgoingEventId != OptionalString(final, L"outgoingEventID")) ++failures;
        if (final.HasKey(L"newestIncomingRequestTimestamp") && snapshot.newestIncomingRequestTimestamp != OptionalNumber(final, L"newestIncomingRequestTimestamp")) ++failures;
        if (final.HasKey(L"seenMessageCount") && snapshot.seenMessageCount != static_cast<int>(final.GetNamedNumber(L"seenMessageCount"))) ++failures;
        if (failures) std::wcerr << L"FAIL " << id << L": " << failures << L" mismatch(es), actual actions=" << actual.size() << L", expected=" << expected.Size() << L'\n';
        return failures;
    }

    int RunMessageVector(JsonObject const& vector, double referenceTime, std::wstring const& pairingCode)
    {
        auto const id = std::wstring(vector.GetNamedString(L"id"));
        auto input = vector.GetNamedObject(L"input");
        std::string json;
        if (input.GetNamedString(L"encoding") == L"rawUtf8") json = to_string(input.GetNamedString(L"value"));
        else json = to_string(input.GetNamedObject(L"value").Stringify());

        PeerMessage message;
        auto result = ParsePeerMessage(json, message);
        auto localPlatform = std::wstring(vector.GetNamedString(L"localPlatform"));
        if (result.accepted) result = ValidatePeerMessage(message, localPlatform, pairingCode, referenceTime);
        auto expected = vector.GetNamedObject(L"expected");
        int failures = 0;
        if (result.accepted != expected.GetNamedBoolean(L"accepted")) ++failures;
        if (result.reason != expected.GetNamedString(L"reason").c_str()) ++failures;

        int wakeCalls = 0;
        int switchCalls = 0;
        bool refreshed = false;
        std::vector<std::wstring> replyTypes;
        if (result.accepted)
        {
            StateMachineConfig config{ localPlatform, pairingCode, true, true, referenceTime, {} };
            HandoverStateMachine machine(config, [] { return std::wstring{}; });
            for (auto const& action : machine.OnPeerMessage(0, message))
            {
                if (action.kind == StateMachineAction::Kind::SetPeerReachable && action.value) refreshed = true;
                if (action.kind == StateMachineAction::Kind::SendMessage || action.kind == StateMachineAction::Kind::SendBurst)
                    replyTypes.push_back(action.type);
                if (action.kind == StateMachineAction::Kind::RequestWake) ++wakeCalls;
                if (action.kind == StateMachineAction::Kind::RequestSwitch) ++switchCalls;
            }
        }
        if (refreshed != expected.GetNamedBoolean(L"refreshPeer")) ++failures;
        auto expectedReplies = expected.GetNamedArray(L"replyTypes");
        if (replyTypes.size() != expectedReplies.Size()) ++failures;
        else for (uint32_t index = 0; index < expectedReplies.Size(); ++index)
            if (replyTypes[index] != expectedReplies.GetStringAt(index).c_str()) ++failures;
        auto hardware = expected.GetNamedObject(L"hardwareCalls");
        if (wakeCalls != static_cast<int>(hardware.GetNamedNumber(L"wake"))) ++failures;
        if (switchCalls != static_cast<int>(hardware.GetNamedNumber(L"switchDisplay"))) ++failures;
        if (failures) std::wcerr << L"FAIL " << id << L": " << failures << L" message validation mismatch(es)\n";
        return failures;
    }

    int TestDuplicateStatusProbeRestoresLiveness()
    {
        constexpr double ReferenceTime = 1788000000.0;
        std::wstring const eventId = L"10000000-0000-4000-8000-000000000099";
        PeerMessage probe{ 1, L"status_probe", eventId, L"mac", L"windows", ReferenceTime,
            L"TEST-CODE-0001", std::nullopt };
        HandoverStateMachine machine({ L"windows", L"TEST-CODE-0001", true, true, ReferenceTime, {} },
            [] { return std::wstring{}; });

        auto first = machine.OnPeerMessage(0, probe);
        auto expired = machine.Advance(6001);
        probe.timestamp = ReferenceTime + 6.001;
        auto repeated = machine.OnPeerMessage(6001, probe);

        auto responseCount = [&](std::vector<StateMachineAction> const& actions)
        {
            return std::count_if(actions.begin(), actions.end(), [&](StateMachineAction const& action)
            {
                return action.kind == StateMachineAction::Kind::SendMessage &&
                    action.type == L"status_response" && action.eventId == eventId;
            });
        };
        auto hardwareCount = [](std::vector<StateMachineAction> const& actions)
        {
            return std::count_if(actions.begin(), actions.end(), [](StateMachineAction const& action)
            {
                return action.kind == StateMachineAction::Kind::RequestWake ||
                    action.kind == StateMachineAction::Kind::RequestSwitch ||
                    action.kind == StateMachineAction::Kind::SendBurst;
            });
        };
        bool expiredOffline = std::any_of(expired.begin(), expired.end(), [](StateMachineAction const& action)
        {
            return action.kind == StateMachineAction::Kind::SetPeerReachable && !action.value;
        });
        bool restoredOnline = std::any_of(repeated.begin(), repeated.end(), [](StateMachineAction const& action)
        {
            return action.kind == StateMachineAction::Kind::SetPeerReachable && action.value;
        });
        auto snapshot = machine.Snapshot();
        bool passed = responseCount(first) == 1 && expiredOffline && responseCount(repeated) == 1 &&
            restoredOnline && snapshot.peerReachable && snapshot.peerLastSeenAtMs == 6001 &&
            hardwareCount(first) == 0 && hardwareCount(expired) == 0 && hardwareCount(repeated) == 0;
        if (!passed) std::wcerr << L"FAIL duplicate status probe must reply and restore liveness without hardware calls\n";
        return passed ? 0 : 1;
    }
}

int RunStateMachineVectorTests()
{
    auto root = FindRepositoryRoot();
    auto document = ReadJson(root / L"contracts/protocol-v1/state-machine-vectors.json");
    auto referenceTime = document.GetNamedNumber(L"referenceTime");
    auto pairingCode = std::wstring(document.GetNamedString(L"configuredPairingCode"));
    int failures = 0;
    for (auto const& value : document.GetNamedArray(L"vectors")) failures += RunVector(value.GetObject(), referenceTime, pairingCode);
    auto messages = ReadJson(root / L"contracts/protocol-v1/message-validation-vectors.json");
    for (auto const& value : messages.GetNamedArray(L"vectors"))
        failures += RunMessageVector(value.GetObject(), messages.GetNamedNumber(L"referenceTime"),
            messages.GetNamedString(L"configuredPairingCode").c_str());
    failures += TestDuplicateStatusProbeRestoresLiveness();
    if (!failures) std::wcout << L"DS-001 state-machine vectors passed\n";
    return failures;
}
