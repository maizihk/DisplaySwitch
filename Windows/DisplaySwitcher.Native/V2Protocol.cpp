#include "pch.h"
#include "V2Protocol.h"
#include "AppConfig.h"
#include "DisplayModel.h"

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    constexpr int64_t ReplayRetentionMilliseconds = 20000;

    struct AlgorithmHandle
    {
        BCRYPT_ALG_HANDLE value{};
        ~AlgorithmHandle() { if (value) BCryptCloseAlgorithmProvider(value, 0); }
    };

    struct HashHandle
    {
        BCRYPT_HASH_HANDLE value{};
        ~HashHandle() { if (value) BCryptDestroyHash(value); }
    };

    std::wstring Lower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), ::towlower);
        return value;
    }

    bool Required(JsonObject const& object, wchar_t const* name, JsonValueType type)
    {
        return object.HasKey(name) && object.GetNamedValue(name).ValueType() == type;
    }

    std::optional<std::wstring> OptionalString(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name)) return std::nullopt;
        if (object.GetNamedValue(name).ValueType() != JsonValueType::String) throw std::runtime_error("invalid type");
        return std::wstring(object.GetNamedString(name));
    }

    std::optional<bool> OptionalBoolean(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name)) return std::nullopt;
        if (object.GetNamedValue(name).ValueType() != JsonValueType::Boolean) throw std::runtime_error("invalid type");
        return object.GetNamedBoolean(name);
    }

    bool KnownType(std::wstring const& value)
    {
        return value == L"status_probe" || value == L"status_response" || value == L"input_present" ||
            value == L"handover_request" || value == L"target_ready" || value == L"committed" || value == L"cancelled";
    }

    bool ValidNonce(std::wstring const& value, size_t length)
    {
        return value.size() == length && std::all_of(value.begin(), value.end(), [](wchar_t character)
        {
            return iswalnum(character) || character == L'_' || character == L'-';
        });
    }

    bool ValidTypeFields(DisplaySwitcher::Native::V2Message const& message)
    {
        auto count = static_cast<int>(message.intent.has_value()) + static_cast<int>(message.wakeSucceeded.has_value()) +
            static_cast<int>(message.switchSucceeded.has_value()) + static_cast<int>(message.reason.has_value());
        if (message.type == L"handover_request")
            return count == 1 && message.intent && (*message.intent == L"manual" || *message.intent == L"input_handover") && message.targetEndpointId;
        if (message.type == L"target_ready") return count == 1 && message.wakeSucceeded && message.targetEndpointId;
        if (message.type == L"committed") return count == 1 && message.switchSucceeded && message.targetEndpointId;
        if (message.type == L"cancelled")
            return count == 1 && message.reason && message.targetEndpointId &&
                (*message.reason == L"source_input_returned" || *message.reason == L"configuration_changed" ||
                 *message.reason == L"user_cancelled" || *message.reason == L"peer_unavailable");
        return count == 0 && (message.type == L"status_probe" || message.targetEndpointId.has_value());
    }

    std::vector<uint8_t> Utf8(std::wstring const& value)
    {
        if (value.empty()) return {};
        auto size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
        if (size <= 0) throw std::runtime_error("invalid unicode");
        std::vector<uint8_t> result(static_cast<size_t>(size));
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
            reinterpret_cast<char*>(result.data()), size, nullptr, nullptr) != size) throw std::runtime_error("invalid unicode");
        return result;
    }

    std::array<uint8_t, 32> HmacSha256(std::span<uint8_t const> key, std::span<uint8_t const> data)
    {
        AlgorithmHandle algorithm;
        winrt::check_nt(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG));
        HashHandle hash;
        winrt::check_nt(BCryptCreateHash(algorithm.value, &hash.value, nullptr, 0,
            const_cast<PUCHAR>(key.data()), static_cast<ULONG>(key.size()), 0));
        winrt::check_nt(BCryptHashData(hash.value, const_cast<PUCHAR>(data.data()), static_cast<ULONG>(data.size()), 0));
        std::array<uint8_t, 32> result{};
        winrt::check_nt(BCryptFinishHash(hash.value, result.data(), static_cast<ULONG>(result.size()), 0));
        return result;
    }
}

namespace DisplaySwitcher::Native
{
    std::optional<int> ParseProtocolVersion(std::string_view json)
    {
        try
        {
            auto object = JsonObject::Parse(to_hstring(std::string(json)));
            if (!Required(object, L"version", JsonValueType::Number)) return std::nullopt;
            auto number = object.GetNamedNumber(L"version");
            if (!std::isfinite(number) || std::trunc(number) != number) return std::nullopt;
            return static_cast<int>(number);
        }
        catch (...) { return std::nullopt; }
    }

    V2ValidationResult ParseV2Message(std::string_view json, V2Message& message)
    {
        JsonObject object;
        try { object = JsonObject::Parse(to_hstring(std::string(json))); }
        catch (...) { return { false, false, L"parse_error" }; }
        for (auto name : { L"version", L"type", L"eventID", L"sourceEndpointID", L"targetEndpointID", L"sourcePlatform", L"timestamp", L"nonce", L"authTag" })
            if (!object.HasKey(name)) return { false, false, L"missing_field" };
        if (!Required(object, L"version", JsonValueType::Number) || !Required(object, L"type", JsonValueType::String) ||
            !Required(object, L"eventID", JsonValueType::String) || !Required(object, L"sourceEndpointID", JsonValueType::String) ||
            !(object.GetNamedValue(L"targetEndpointID").ValueType() == JsonValueType::Null || Required(object, L"targetEndpointID", JsonValueType::String)) ||
            !Required(object, L"sourcePlatform", JsonValueType::String) || !Required(object, L"timestamp", JsonValueType::Number) ||
            !Required(object, L"nonce", JsonValueType::String) || !Required(object, L"authTag", JsonValueType::String))
            return { false, false, L"invalid_field_type" };
        auto version = object.GetNamedNumber(L"version"), timestamp = object.GetNamedNumber(L"timestamp");
        if (!std::isfinite(version) || std::trunc(version) != version || version < 0 || version > 2147483647 ||
            !std::isfinite(timestamp) || std::trunc(timestamp) != timestamp || timestamp < 0 || timestamp > 9007199254740991.0)
            return { false, false, L"invalid_field_type" };
        message = {};
        message.version = static_cast<int>(version);
        message.type = object.GetNamedString(L"type").c_str();
        message.eventId = object.GetNamedString(L"eventID").c_str();
        message.sourceEndpointId = object.GetNamedString(L"sourceEndpointID").c_str();
        if (object.GetNamedValue(L"targetEndpointID").ValueType() == JsonValueType::String)
            message.targetEndpointId = std::wstring(object.GetNamedString(L"targetEndpointID"));
        message.sourcePlatform = object.GetNamedString(L"sourcePlatform").c_str();
        message.timestamp = static_cast<int64_t>(timestamp);
        message.nonce = object.GetNamedString(L"nonce").c_str();
        message.authTag = object.GetNamedString(L"authTag").c_str();
        try
        {
            message.intent = OptionalString(object, L"intent");
            message.wakeSucceeded = OptionalBoolean(object, L"wakeSucceeded");
            message.switchSucceeded = OptionalBoolean(object, L"switchSucceeded");
            message.reason = OptionalString(object, L"reason");
        }
        catch (...) { return { false, false, L"invalid_field_type" }; }
        if (message.version != 2) return { false, false, L"unsupported_version" };
        if (!KnownType(message.type)) return { false, false, L"unknown_type" };
        if (!IsValidDisplayId(message.eventId)) return { false, false, L"invalid_event_id" };
        if (!IsValidDisplayId(message.sourceEndpointId)) return { false, false, L"unknown_source" };
        if (message.targetEndpointId && !IsValidDisplayId(*message.targetEndpointId)) return { false, false, L"wrong_target" };
        if (message.sourcePlatform != L"macos" && message.sourcePlatform != L"windows") return { false, false, L"invalid_field_type" };
        if (message.timestamp < 0) return { false, false, L"invalid_field_type" };
        if (!ValidNonce(message.nonce, 22)) return { false, false, L"invalid_nonce" };
        if (!ValidNonce(message.authTag, 43)) return { false, false, L"invalid_auth_tag" };
        if (!ValidTypeFields(message)) return { false, false, L"invalid_type_fields" };
        return { true, false, L"parsed" };
    }

    V2ValidationResult ValidateV2Message(V2Message const& message,
        std::wstring const& localEndpointId, std::wstring const& knownSourceEndpointId,
        std::span<uint8_t const> authenticationKey, int64_t nowUnixSeconds,
        V2ReplayCache* replayCache, int64_t nowMilliseconds)
    {
        if (_wcsicmp(message.sourceEndpointId.c_str(), knownSourceEndpointId.c_str()) != 0)
            return { false, false, L"unknown_source" };
        if (message.type == L"status_probe")
        {
            if (message.targetEndpointId && _wcsicmp(message.targetEndpointId->c_str(), localEndpointId.c_str()) != 0)
                return { false, false, L"wrong_target" };
        }
        else if (!message.targetEndpointId || _wcsicmp(message.targetEndpointId->c_str(), localEndpointId.c_str()) != 0)
            return { false, false, L"wrong_target" };
        if (std::llabs(message.timestamp - nowUnixSeconds) > 10) return { false, false, L"timestamp_out_of_window" };
        auto expected = ComputeV2AuthenticationTag(authenticationKey, message);
        if (!ConstantTimeEquals(message.authTag, expected)) return { false, false, L"authentication_failed" };
        if (replayCache)
        {
            auto replay = replayCache->CheckAndRemember(message, nowMilliseconds);
            if (replay == V2ReplayResult::NonceReuse) return { false, false, L"nonce_reuse" };
            if (replay == V2ReplayResult::Duplicate) return { true, true, L"duplicate" };
        }
        return { true, false, L"accepted" };
    }

    std::string CanonicalV2AuthenticationInput(V2Message const& message)
    {
        auto narrow = [](std::wstring const& value) { return winrt::to_string(winrt::hstring(value)); };
        auto nullable = [&](std::optional<std::wstring> const& value, bool lower)
        {
            if (!value) return std::string("null");
            return narrow(lower ? Lower(*value) : *value);
        };
        auto boolean = [](std::optional<bool> value) { return value ? (*value ? "true" : "false") : "null"; };
        std::string result = "DisplaySwitch/v2\nversion:2\n";
        result += "type:" + narrow(message.type) + "\n";
        result += "eventID:" + narrow(Lower(message.eventId)) + "\n";
        result += "sourceEndpointID:" + narrow(Lower(message.sourceEndpointId)) + "\n";
        result += "targetEndpointID:" + nullable(message.targetEndpointId, true) + "\n";
        result += "sourcePlatform:" + narrow(message.sourcePlatform) + "\n";
        result += "timestamp:" + std::to_string(message.timestamp) + "\n";
        result += "nonce:" + narrow(message.nonce) + "\n";
        result += "intent:" + nullable(message.intent, false) + "\n";
        result += "wakeSucceeded:" + std::string(boolean(message.wakeSucceeded)) + "\n";
        result += "switchSucceeded:" + std::string(boolean(message.switchSucceeded)) + "\n";
        result += "reason:" + nullable(message.reason, false) + "\n";
        return result;
    }

    std::vector<uint8_t> NormalizeV2PairingSecret(std::wstring const& pairingCode)
    {
        auto normalized = AppConfig::NormalizeNfc(pairingCode);
        auto bytes = Utf8(normalized);
        if (bytes.size() < 8 || bytes.size() > 128) throw std::runtime_error("invalid pairing secret");
        return bytes;
    }

    std::array<uint8_t, 32> DeriveV2AuthenticationKey(std::span<uint8_t const> secret,
        std::wstring const& sourceEndpointId)
    {
        auto endpoint = Lower(sourceEndpointId);
        if (!IsValidDisplayId(endpoint)) throw std::runtime_error("invalid endpoint");
        auto saltText = std::string("DisplaySwitch-v2-auth|") + winrt::to_string(winrt::hstring(endpoint));
        AlgorithmHandle algorithm;
        winrt::check_nt(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG));
        std::array<uint8_t, 32> result{};
        winrt::check_nt(BCryptDeriveKeyPBKDF2(algorithm.value, const_cast<PUCHAR>(secret.data()), static_cast<ULONG>(secret.size()),
            reinterpret_cast<PUCHAR>(saltText.data()), static_cast<ULONG>(saltText.size()), 200000,
            result.data(), static_cast<ULONG>(result.size()), 0));
        return result;
    }

    std::wstring ComputeV2AuthenticationTag(std::span<uint8_t const> key, V2Message const& message)
    {
        auto canonical = CanonicalV2AuthenticationInput(message);
        auto tag = HmacSha256(key, std::span(reinterpret_cast<uint8_t const*>(canonical.data()), canonical.size()));
        return Base64UrlEncode(tag);
    }

    std::wstring GenerateV2Nonce()
    {
        std::array<uint8_t, 16> bytes{};
        winrt::check_nt(BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG));
        return Base64UrlEncode(bytes);
    }

    bool ConstantTimeEquals(std::wstring_view left, std::wstring_view right) noexcept
    {
        size_t maximum = (std::max)(left.size(), right.size());
        unsigned difference = static_cast<unsigned>(left.size() ^ right.size());
        for (size_t index = 0; index < maximum; ++index)
            difference |= static_cast<unsigned>((index < left.size() ? left[index] : 0) ^ (index < right.size() ? right[index] : 0));
        return difference == 0;
    }

    std::wstring Base64UrlEncode(std::span<uint8_t const> bytes)
    {
        static constexpr wchar_t Alphabet[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        std::wstring result;
        for (size_t index = 0; index < bytes.size(); index += 3)
        {
            uint32_t value = static_cast<uint32_t>(bytes[index]) << 16;
            if (index + 1 < bytes.size()) value |= static_cast<uint32_t>(bytes[index + 1]) << 8;
            if (index + 2 < bytes.size()) value |= bytes[index + 2];
            result.push_back(Alphabet[(value >> 18) & 63]); result.push_back(Alphabet[(value >> 12) & 63]);
            if (index + 1 < bytes.size()) result.push_back(Alphabet[(value >> 6) & 63]);
            if (index + 2 < bytes.size()) result.push_back(Alphabet[value & 63]);
        }
        return result;
    }

    std::vector<uint8_t> Base64UrlDecode(std::wstring_view text)
    {
        auto decode = [](wchar_t value) -> int
        {
            if (value >= L'A' && value <= L'Z') return value - L'A';
            if (value >= L'a' && value <= L'z') return value - L'a' + 26;
            if (value >= L'0' && value <= L'9') return value - L'0' + 52;
            if (value == L'-') return 62; if (value == L'_') return 63; return -1;
        };
        std::vector<uint8_t> result; uint32_t value{}; int bits{};
        for (auto character : text)
        {
            auto digit = decode(character); if (digit < 0) throw std::runtime_error("invalid base64url");
            value = (value << 6) | static_cast<uint32_t>(digit); bits += 6;
            if (bits >= 8) { bits -= 8; result.push_back(static_cast<uint8_t>((value >> bits) & 0xff)); }
        }
        return result;
    }

    V2Message SignV2Message(V2Message message, std::span<uint8_t const> key)
    {
        if (message.nonce.empty()) message.nonce = GenerateV2Nonce();
        message.authTag = ComputeV2AuthenticationTag(key, message);
        return message;
    }

    std::string SerializeV2Message(V2Message const& message)
    {
        JsonObject object;
        object.Insert(L"version", JsonValue::CreateNumberValue(2)); object.Insert(L"type", JsonValue::CreateStringValue(message.type));
        object.Insert(L"eventID", JsonValue::CreateStringValue(message.eventId));
        object.Insert(L"sourceEndpointID", JsonValue::CreateStringValue(message.sourceEndpointId));
        object.Insert(L"targetEndpointID", message.targetEndpointId ? JsonValue::CreateStringValue(*message.targetEndpointId) : JsonValue::CreateNullValue());
        object.Insert(L"sourcePlatform", JsonValue::CreateStringValue(message.sourcePlatform));
        object.Insert(L"timestamp", JsonValue::CreateNumberValue(static_cast<double>(message.timestamp)));
        object.Insert(L"nonce", JsonValue::CreateStringValue(message.nonce)); object.Insert(L"authTag", JsonValue::CreateStringValue(message.authTag));
        if (message.intent) object.Insert(L"intent", JsonValue::CreateStringValue(*message.intent));
        if (message.wakeSucceeded) object.Insert(L"wakeSucceeded", JsonValue::CreateBooleanValue(*message.wakeSucceeded));
        if (message.switchSucceeded) object.Insert(L"switchSucceeded", JsonValue::CreateBooleanValue(*message.switchSucceeded));
        if (message.reason) object.Insert(L"reason", JsonValue::CreateStringValue(*message.reason));
        return winrt::to_string(object.Stringify());
    }

    V2ReplayResult V2ReplayCache::CheckAndRemember(V2Message const& message, int64_t nowMilliseconds)
    {
        while (!entries_.empty() && nowMilliseconds - entries_.front().seenAtMilliseconds > ReplayRetentionMilliseconds) entries_.pop_front();
        auto source = Lower(message.sourceEndpointId);
        auto canonical = CanonicalV2AuthenticationInput(message);
        for (auto const& entry : entries_)
        {
            if (entry.sourceEndpointId != source || entry.nonce != message.nonce) continue;
            return entry.canonical == canonical ? V2ReplayResult::Duplicate : V2ReplayResult::NonceReuse;
        }
        entries_.push_back({ std::move(source), message.nonce, std::move(canonical), nowMilliseconds });
        return V2ReplayResult::Fresh;
    }
}
