#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace DisplaySwitcher::Native
{
    struct V2Message
    {
        int version{ 2 };
        std::wstring type;
        std::wstring eventId;
        std::wstring sourceEndpointId;
        std::optional<std::wstring> targetEndpointId;
        std::wstring sourcePlatform;
        int64_t timestamp{};
        std::wstring nonce;
        std::wstring authTag;
        std::optional<std::wstring> intent;
        std::optional<bool> wakeSucceeded;
        std::optional<bool> switchSucceeded;
        std::optional<std::wstring> reason;
    };

    struct V2ValidationResult
    {
        bool accepted{};
        bool duplicate{};
        std::wstring reason;
    };

    enum class V2ReplayResult { Fresh, Duplicate, NonceReuse };

    class V2ReplayCache final
    {
    public:
        V2ReplayResult CheckAndRemember(V2Message const& message, int64_t nowMilliseconds);
        void Clear() noexcept { entries_.clear(); }

    private:
        struct Entry
        {
            std::wstring sourceEndpointId;
            std::wstring nonce;
            std::string canonical;
            int64_t seenAtMilliseconds{};
        };
        std::deque<Entry> entries_;
    };

    std::optional<int> ParseProtocolVersion(std::string_view json);
    bool IsV2Datagram(std::string_view json);
    V2ValidationResult ParseV2Message(std::string_view json, V2Message& message);
    V2ValidationResult ValidateV2Message(V2Message const& message,
        std::wstring const& localEndpointId, std::wstring const& knownSourceEndpointId,
        std::span<uint8_t const> authenticationKey, int64_t nowUnixSeconds,
        V2ReplayCache* replayCache = nullptr, int64_t nowMilliseconds = 0);
    std::string SerializeV2Message(V2Message const& message);
    std::string CanonicalV2AuthenticationInput(V2Message const& message);
    std::vector<uint8_t> NormalizeV2PairingSecret(std::wstring const& pairingCode);
    std::array<uint8_t, 32> DeriveV2AuthenticationKey(std::span<uint8_t const> secret,
        std::wstring const& sourceEndpointId);
    std::wstring ComputeV2AuthenticationTag(std::span<uint8_t const> key, V2Message const& message);
    std::wstring GenerateV2Nonce();
    bool ConstantTimeEquals(std::wstring_view left, std::wstring_view right) noexcept;
    std::wstring Base64UrlEncode(std::span<uint8_t const> bytes);
    std::vector<uint8_t> Base64UrlDecode(std::wstring_view text);
    V2Message SignV2Message(V2Message message, std::span<uint8_t const> key);
}
