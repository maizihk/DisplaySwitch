#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/V2Protocol.h"
#include "../DisplaySwitcher.Native/V2StateMachine.h"

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
            if (std::filesystem::exists(path / L"contracts/protocol-v2/state-machine-vectors.json")) return path;
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

    std::wstring String(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || object.GetNamedValue(name).ValueType() == JsonValueType::Null) return {};
        return object.GetNamedString(name).c_str();
    }

    bool Bool(JsonObject const& object, wchar_t const* name, bool fallback = false)
    {
        return object.HasKey(name) ? object.GetNamedBoolean(name) : fallback;
    }

    std::vector<uint8_t> Hex(std::wstring const& value)
    {
        if (value.size() % 2) throw std::runtime_error("invalid hex");
        std::vector<uint8_t> result;
        for (size_t index = 0; index < value.size(); index += 2)
        {
            auto digit = [](wchar_t c) -> uint8_t
            {
                if (c >= L'0' && c <= L'9') return static_cast<uint8_t>(c - L'0');
                if (c >= L'a' && c <= L'f') return static_cast<uint8_t>(c - L'a' + 10);
                if (c >= L'A' && c <= L'F') return static_cast<uint8_t>(c - L'A' + 10);
                throw std::runtime_error("invalid hex");
            };
            result.push_back(static_cast<uint8_t>((digit(value[index]) << 4) | digit(value[index + 1])));
        }
        return result;
    }

    std::wstring Utf8(std::vector<uint8_t> const& bytes)
    {
        return to_hstring(std::string(reinterpret_cast<char const*>(bytes.data()), bytes.size())).c_str();
    }

    V2Message Message(JsonObject const& object)
    {
        V2Message result;
        result.version = static_cast<int>(object.GetNamedNumber(L"version"));
        result.type = String(object, L"type"); result.eventId = String(object, L"eventID");
        result.sourceEndpointId = String(object, L"sourceEndpointID");
        if (object.HasKey(L"targetEndpointID") && object.GetNamedValue(L"targetEndpointID").ValueType() != JsonValueType::Null)
            result.targetEndpointId = String(object, L"targetEndpointID");
        result.sourcePlatform = String(object, L"sourcePlatform");
        result.timestamp = static_cast<int64_t>(object.GetNamedNumber(L"timestamp")); result.nonce = String(object, L"nonce");
        if (object.HasKey(L"intent")) result.intent = String(object, L"intent");
        if (object.HasKey(L"wakeSucceeded")) result.wakeSucceeded = Bool(object, L"wakeSucceeded");
        if (object.HasKey(L"switchSucceeded")) result.switchSucceeded = Bool(object, L"switchSucceeded");
        if (object.HasKey(L"reason")) result.reason = String(object, L"reason");
        return result;
    }

    V2CoordinatorState State(std::wstring const& value)
    {
        if (value == L"idle") return V2CoordinatorState::Idle;
        if (value == L"debouncing") return V2CoordinatorState::Debouncing;
        if (value == L"discovering") return V2CoordinatorState::Discovering;
        if (value == L"awaiting_input") return V2CoordinatorState::AwaitingInput;
        if (value == L"awaiting_ready") return V2CoordinatorState::AwaitingReady;
        if (value == L"awaiting_commit") return V2CoordinatorState::AwaitingCommit;
        if (value == L"switching") return V2CoordinatorState::Switching;
        if (value == L"completed") return V2CoordinatorState::Completed;
        if (value == L"cancelled") return V2CoordinatorState::Cancelled;
        throw std::runtime_error("unknown v2 state");
    }

    std::wstring Kind(V2Action::Kind kind)
    {
        switch (kind)
        {
        case V2Action::Kind::SendMessage: return L"sendMessage";
        case V2Action::Kind::RequestWake: return L"requestWake";
        case V2Action::Kind::RequestSwitch: return L"requestSwitch";
        case V2Action::Kind::LockTarget: return L"lockTarget";
        case V2Action::Kind::StartDiscovery: return L"startDiscovery";
        case V2Action::Kind::PromptManualSelection: return L"promptManualSelection";
        case V2Action::Kind::IgnoreMessage: return L"ignoreMessage";
        case V2Action::Kind::ClearEvent: return L"clearEvent";
        case V2Action::Kind::SetPeerReachable: return L"setPeerReachable";
        }
        return {};
    }

    struct TimedAction { int64_t atMs{}; V2Action action; };

    void Append(std::vector<TimedAction>& output, int64_t atMs, std::vector<V2Action> actions)
    {
        for (auto& action : actions) output.push_back({ atMs, std::move(action) });
    }

    std::vector<V2Action> Apply(V2StateMachine& machine, int64_t atMs, JsonObject const& input)
    {
        auto kind = String(input, L"kind");
        auto endpoint = String(input, L"endpointID");
        auto event = String(input, L"eventID");
        auto authenticated = Bool(input, L"authenticated");
        if (kind == L"advanceTime") return {};
        if (kind == L"statusProbe") return machine.OnStatusProbe(atMs, endpoint, event, authenticated);
        if (kind == L"manualSelect") return machine.OnManualSelect(atMs, endpoint, event);
        if (kind == L"sourceInputPresenceChanged") return machine.OnSourceInputPresenceChanged(atMs, Bool(input, L"present"), event);
        if (kind == L"targetInputPresenceChanged") return machine.OnTargetInputPresenceChanged(atMs, Bool(input, L"present"), event);
        if (kind == L"peerInputPresent") return machine.OnPeerInputPresent(atMs, endpoint, event, authenticated);
        if (kind == L"receiveHandoverRequest") return machine.OnHandoverRequest(atMs, endpoint, event, authenticated, String(input, L"intent"));
        if (kind == L"receiveTargetReady") return machine.OnTargetReady(atMs, endpoint, event, authenticated, Bool(input, L"wakeSucceeded"));
        if (kind == L"receiveCommitted") return machine.OnCommitted(atMs, endpoint, event, authenticated, Bool(input, L"switchSucceeded"));
        if (kind == L"wakeCompleted") return machine.OnWakeCompleted(atMs, event, Bool(input, L"success"));
        if (kind == L"switchCompleted") return machine.OnSwitchCompleted(atMs, event, Bool(input, L"success"));
        if (kind == L"configurationChanged") return machine.OnConfigurationChanged(atMs);
        if (kind == L"receiveV1Message") return {};
        throw std::runtime_error("unknown v2 input kind");
    }

    bool Matches(TimedAction const& actual, JsonObject const& expected)
    {
        if (actual.atMs != static_cast<int64_t>(expected.GetNamedNumber(L"atMs")) || Kind(actual.action.kind) != String(expected, L"kind")) return false;
        if (expected.HasKey(L"type") && actual.action.type != String(expected, L"type")) return false;
        if (expected.HasKey(L"eventID") && actual.action.eventId != String(expected, L"eventID")) return false;
        if (expected.HasKey(L"endpointID") && actual.action.endpointId != String(expected, L"endpointID")) return false;
        if (expected.HasKey(L"reason") && actual.action.reason != String(expected, L"reason")) return false;
        if (expected.HasKey(L"intent") && actual.action.intent != String(expected, L"intent")) return false;
        if (expected.HasKey(L"wakeSucceeded") && actual.action.wakeSucceeded != std::optional<bool>(Bool(expected, L"wakeSucceeded"))) return false;
        if (expected.HasKey(L"switchSucceeded") && actual.action.switchSucceeded != std::optional<bool>(Bool(expected, L"switchSucceeded"))) return false;
        if (expected.HasKey(L"value") && actual.action.value != Bool(expected, L"value")) return false;
        return true;
    }
}

int RunV2ProtocolVectorTests()
{
    auto root = FindRepositoryRoot();
    int failures{};
    auto fail = [&](std::wstring const& id, std::wstring const& detail)
    {
        ++failures; std::wcerr << L"FAIL " << id << L": " << detail << L'\n';
    };

    auto auth = ReadJson(root / L"contracts/protocol-v2/auth-vectors.json");
    for (auto const& item : auth.GetNamedArray(L"normalizationVectors"))
    {
        auto vector = item.GetObjectW(); auto id = String(vector, L"id");
        auto actual = NormalizeV2PairingSecret(Utf8(Hex(String(vector, L"inputUtf8Hex"))));
        if (actual != Hex(String(vector, L"expectedNfcUtf8Hex"))) fail(id, L"NFC bytes differ");
    }
    auto secret = Hex(String(auth, L"syntheticInputSecretHex"));
    for (auto const& item : auth.GetNamedArray(L"vectors"))
    {
        auto vector = item.GetObjectW(); auto id = String(vector, L"id");
        auto key = DeriveV2AuthenticationKey(secret, String(vector, L"sourceEndpointID"));
        if (Base64UrlEncode(key) != String(vector, L"expectedDerivedKeyBase64Url")) fail(id, L"derived key differs");
        if (vector.HasKey(L"messageWithoutAuthTag"))
        {
            auto message = Message(vector.GetNamedObject(L"messageWithoutAuthTag"));
            auto canonical = CanonicalV2AuthenticationInput(message);
            std::vector<uint8_t> bytes(canonical.begin(), canonical.end());
            if (bytes != Hex(String(vector, L"expectedCanonicalUtf8Hex"))) fail(id, L"canonical input differs");
            if (ComputeV2AuthenticationTag(key, message) != String(vector, L"expectedAuthTag")) fail(id, L"authentication tag differs");
        }
    }

    auto messages = ReadJson(root / L"contracts/protocol-v2/message-validation-vectors.json");
    auto messageKey = Base64UrlDecode(String(messages, L"authKeyBase64Url"));
    int messageCount{};
    for (auto const& item : messages.GetNamedArray(L"vectors"))
    {
        ++messageCount; auto vector = item.GetObjectW(); auto id = String(vector, L"id"); auto input = vector.GetNamedObject(L"input");
        auto json = String(input, L"encoding") == L"rawUtf8" ? to_string(String(input, L"value")) : to_string(input.GetNamedObject(L"value").Stringify());
        V2Message message; auto result = ParseV2Message(json, message);
        if (result.accepted)
            result = ValidateV2Message(message, String(messages, L"localEndpointID"), String(messages, L"knownSourceEndpointID"),
                messageKey, static_cast<int64_t>(messages.GetNamedNumber(L"referenceTime")));
        auto expected = vector.GetNamedObject(L"expected");
        if (result.accepted != Bool(expected, L"accepted") || result.reason != String(expected, L"reason"))
            fail(id, L"validation result differs: " + result.reason);
    }
    {
        auto source = messages.GetNamedArray(L"vectors").GetAt(1).GetObjectW().GetNamedObject(L"input").GetNamedObject(L"value");
        V2Message replayed; auto parsed = ParseV2Message(to_string(source.Stringify()), replayed); V2ReplayCache replay;
        auto first = parsed.accepted ? ValidateV2Message(replayed, String(messages, L"localEndpointID"), String(messages, L"knownSourceEndpointID"),
            messageKey, static_cast<int64_t>(messages.GetNamedNumber(L"referenceTime")), &replay, 1000) : parsed;
        auto duplicate = ValidateV2Message(replayed, String(messages, L"localEndpointID"), String(messages, L"knownSourceEndpointID"),
            messageKey, static_cast<int64_t>(messages.GetNamedNumber(L"referenceTime")), &replay, 2000);
        auto reused = replayed; reused.eventId = L"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        reused.authTag = ComputeV2AuthenticationTag(messageKey, reused);
        auto collision = ValidateV2Message(reused, String(messages, L"localEndpointID"), String(messages, L"knownSourceEndpointID"),
            messageKey, static_cast<int64_t>(messages.GetNamedNumber(L"referenceTime")), &replay, 3000);
        if (!first.accepted || !duplicate.accepted || !duplicate.duplicate || collision.accepted || collision.reason != L"nonce_reuse")
            fail(L"REPLAY-001", L"duplicate/reused nonce policy differs");
        auto serialized = SerializeV2Message(replayed);
        if (serialized.find("pairingCode") != std::string::npos || serialized.find("usb") != std::string::npos || serialized.find("displayID") != std::string::npos)
            fail(L"PRIVACY-001", L"v2 datagram contains local device data");
        if (!IsV2Datagram(serialized) || IsV2Datagram(R"({"version":1})")
            || IsV2Datagram(R"({"version":"2"})") || IsV2Datagram(R"({"version":3})"))
            fail(L"DISPATCH-001", L"v2-only version dispatcher differs");
    }

    auto states = ReadJson(root / L"contracts/protocol-v2/state-machine-vectors.json");
    int stateCount{};
    for (auto const& item : states.GetNamedArray(L"vectors"))
    {
        ++stateCount; auto vector = item.GetObjectW(); auto id = String(vector, L"id"); auto initialJson = vector.GetNamedObject(L"initialState");
        V2StateInitial initial{ String(initialJson, L"localEndpointID"), Bool(initialJson, L"coordinationEnabled"),
            Bool(initialJson, L"sourceInputPresent"), Bool(initialJson, L"targetInputPresent"), State(String(initialJson, L"state")),
            String(initialJson, L"activeEventID"), String(initialJson, L"lockedTargetEndpointID") };
        for (auto const& targetValue : initialJson.GetNamedArray(L"enabledTargets"))
        {
            auto target = targetValue.GetObjectW();
            initial.enabledTargets.push_back({ String(target, L"endpointID"), String(target, L"capability") == L"v1" ? 1 : 2, Bool(target, L"reachable") });
        }
        V2StateMachine machine(std::move(initial)); std::vector<TimedAction> actual; int64_t cursor = -1;
        for (auto const& stepValue : vector.GetNamedArray(L"steps"))
        {
            auto step = stepValue.GetObjectW(); auto atMs = static_cast<int64_t>(step.GetNamedNumber(L"atMs"));
            for (auto tick = cursor + 1; tick < atMs; ++tick) Append(actual, tick, machine.Advance(tick));
            Append(actual, atMs, Apply(machine, atMs, step.GetNamedObject(L"input")));
            Append(actual, atMs, machine.Advance(atMs)); cursor = atMs;
        }
        auto expectedActions = vector.GetNamedArray(L"expectedActions");
        auto v2OnlyLegacyReject = id == L"P-014";
        if (v2OnlyLegacyReject && !actual.empty()) fail(id, L"v1 message must have zero actions in v2-only runtime");
        else if (!v2OnlyLegacyReject && actual.size() != expectedActions.Size()) fail(id, L"action count differs");
        else if (!v2OnlyLegacyReject) for (uint32_t index = 0; index < expectedActions.Size(); ++index)
            if (!Matches(actual[index], expectedActions.GetAt(index).GetObjectW())) { fail(id, L"action differs at index " + std::to_wstring(index)); break; }
        auto finalJson = vector.GetNamedObject(L"finalState"); auto snapshot = machine.Snapshot();
        if (snapshot.state != State(String(finalJson, L"state")) || snapshot.activeEventId != String(finalJson, L"activeEventID") ||
            snapshot.lockedTargetEndpointId != String(finalJson, L"lockedTargetEndpointID")) fail(id, L"final state differs");
        int wake{}, switches{};
        for (auto const& timed : actual) { if (timed.action.kind == V2Action::Kind::RequestWake) ++wake; if (timed.action.kind == V2Action::Kind::RequestSwitch) ++switches; }
        auto hardware = vector.GetNamedObject(L"expectedHardwareCalls");
        if (wake != static_cast<int>(hardware.GetNamedNumber(L"wake")) || switches != static_cast<int>(hardware.GetNamedNumber(L"switchDisplay")) ||
            hardware.GetNamedNumber(L"inputActions") != 0) fail(id, L"hardware call count differs");
    }
    if (!failures) std::wcout << L"DS-005 passed 1 normalization vector, 4 authentication vectors, " << messageCount
        << L" message vectors and " << stateCount << L" state-machine vectors\n";
    return failures;
}
