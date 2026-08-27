#include "pch.h"
#include "ProtocolMessage.h"
#include "HandoverStateMachine.h"

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    bool Required(JsonObject const& object, wchar_t const* name, JsonValueType type)
    {
        return object.HasKey(name) && object.GetNamedValue(name).ValueType() == type;
    }

    std::wstring Lower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), ::towlower);
        return value;
    }
}

namespace DisplaySwitcher::Native
{
    MessageValidationResult ParsePeerMessage(std::string_view json, PeerMessage& message)
    {
        JsonObject object;
        try { object = JsonObject::Parse(to_hstring(std::string(json))); }
        catch (...) { return { false, L"parse_error" }; }

        for (auto name : { L"version", L"type", L"eventID", L"source", L"target", L"timestamp", L"pairingCode" })
            if (!object.HasKey(name)) return { false, L"missing_field" };
        if (!Required(object, L"version", JsonValueType::Number) ||
            !Required(object, L"type", JsonValueType::String) ||
            !Required(object, L"eventID", JsonValueType::String) ||
            !Required(object, L"source", JsonValueType::String) ||
            !Required(object, L"target", JsonValueType::String) ||
            !Required(object, L"timestamp", JsonValueType::Number) ||
            !Required(object, L"pairingCode", JsonValueType::String) ||
            (object.HasKey(L"wakeSucceeded") && object.GetNamedValue(L"wakeSucceeded").ValueType() != JsonValueType::Boolean))
            return { false, L"invalid_field_type" };

        auto version = object.GetNamedNumber(L"version");
        auto timestamp = object.GetNamedNumber(L"timestamp");
        if (!std::isfinite(version) || std::trunc(version) != version || !std::isfinite(timestamp))
            return { false, L"invalid_field_type" };
        message.version = static_cast<int>(version);
        message.type = object.GetNamedString(L"type").c_str();
        message.eventId = object.GetNamedString(L"eventID").c_str();
        message.source = object.GetNamedString(L"source").c_str();
        message.target = object.GetNamedString(L"target").c_str();
        message.timestamp = timestamp;
        message.pairingCode = object.GetNamedString(L"pairingCode").c_str();
        message.wakeSucceeded.reset();
        if (object.HasKey(L"wakeSucceeded")) message.wakeSucceeded = object.GetNamedBoolean(L"wakeSucceeded");
        return { true, L"parsed" };
    }

    MessageValidationResult ValidatePeerMessage(PeerMessage const& message, std::wstring const& localPlatformValue,
        std::wstring const& configuredPairingCode, double nowUnixSeconds)
    {
        auto const localPlatform = Lower(localPlatformValue);
        auto const remotePlatform = localPlatform == L"windows" ? L"mac" : L"windows";
        if (message.version != 1) return { false, L"unsupported_version" };
        if (!HandoverStateMachine::IsValidUuid(message.eventId)) return { false, L"invalid_event_id" };
        if (Lower(message.source) != remotePlatform || Lower(message.target) != localPlatform)
            return { false, L"wrong_direction" };
        if (message.pairingCode != configuredPairingCode || configuredPairingCode.size() < 8)
            return { false, L"pairing_mismatch" };
        if (!HandoverStateMachine::IsKnownType(message.type)) return { false, L"unknown_type" };
        if (!std::isfinite(message.timestamp) || std::abs(message.timestamp - nowUnixSeconds) > 10.0 + 1e-9)
            return { false, L"timestamp_out_of_window" };
        return { true, L"accepted" };
    }
}
