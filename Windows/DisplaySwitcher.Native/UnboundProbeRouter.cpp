#include "pch.h"
#include "UnboundProbeRouter.h"

namespace
{
    bool EqualId(std::wstring const& left, std::wstring const& right)
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }
}

namespace DisplaySwitcher::Native
{
    UnboundProbeMatch MatchUnboundStatusProbe(std::vector<CollaborationProfile> const& candidates,
        std::wstring const& localEndpointId, DatagramSource const& source, V2Message const& message,
        int64_t nowUnixSeconds, int64_t nowMilliseconds, ProbeHostMatcher const& hostMatches,
        V2ReplayCache* replayCache, ProbeKeyProvider const& keyProvider)
    {
        if (message.type != L"status_probe" || message.targetEndpointId) return {};
        if (!IsValidDisplayId(localEndpointId) || EqualId(message.sourceEndpointId, localEndpointId))
            return { UnboundProbeMatchStatus::EndpointConflict };

        std::vector<size_t> exactBoundCandidates;
        for (size_t index = 0; index < candidates.size(); ++index)
            if (!candidates[index].peerEndpointId.empty() &&
                EqualId(candidates[index].peerEndpointId, message.sourceEndpointId))
                exactBoundCandidates.push_back(index);
        if (exactBoundCandidates.size() > 1) return { UnboundProbeMatchStatus::EndpointConflict };

        auto authenticates = [&](size_t index)
        {
            auto const& profile = candidates[index];
            try
            {
                auto key = keyProvider ? keyProvider(profile.pairingCode, message.sourceEndpointId) :
                    DeriveV2AuthenticationKey(NormalizeV2PairingSecret(profile.pairingCode), message.sourceEndpointId);
                return ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
                    nowUnixSeconds, nullptr, nowMilliseconds).accepted;
            }
            catch (...) { return false; }
        };

        if (exactBoundCandidates.size() == 1)
        {
            auto index = exactBoundCandidates.front();
            auto const& profile = candidates[index];
            if (profile.peerProtocolVersion != 2 || !hostMatches(profile, source))
                return { UnboundProbeMatchStatus::NoMatch };
            if (!authenticates(index)) return { UnboundProbeMatchStatus::AuthenticationFailed };
            auto key = keyProvider ? keyProvider(profile.pairingCode, message.sourceEndpointId) :
                DeriveV2AuthenticationKey(NormalizeV2PairingSecret(profile.pairingCode), message.sourceEndpointId);
            auto validation = ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
                nowUnixSeconds, replayCache, nowMilliseconds);
            if (!validation.accepted) return { UnboundProbeMatchStatus::NoMatch };
            return { UnboundProbeMatchStatus::Matched, index, validation.duplicate };
        }

        // A correctly authenticated peer arriving from a bound profile's address but
        // claiming a different endpoint is an identity change, not a new bootstrap.
        for (size_t index = 0; index < candidates.size(); ++index)
        {
            auto const& profile = candidates[index];
            if (!profile.peerEndpointId.empty() && profile.peerProtocolVersion == 2 &&
                hostMatches(profile, source) && authenticates(index))
                return { UnboundProbeMatchStatus::EndpointConflict };
        }

        std::vector<size_t> hostCandidates;
        std::vector<size_t> authenticatedCandidates;
        for (size_t index = 0; index < candidates.size(); ++index)
        {
            auto const& profile = candidates[index];
            if (!profile.peerEndpointId.empty() ||
                (profile.peerProtocolVersion && *profile.peerProtocolVersion != 2) ||
                !hostMatches(profile, source)) continue;
            hostCandidates.push_back(index);
            if (authenticates(index)) authenticatedCandidates.push_back(index);
        }
        if (authenticatedCandidates.empty())
            return { hostCandidates.empty() ? UnboundProbeMatchStatus::NoMatch : UnboundProbeMatchStatus::AuthenticationFailed };
        if (authenticatedCandidates.size() != 1) return { UnboundProbeMatchStatus::Ambiguous };

        auto index = authenticatedCandidates.front();
        auto const& profile = candidates[index];
        auto key = keyProvider ? keyProvider(profile.pairingCode, message.sourceEndpointId) :
            DeriveV2AuthenticationKey(NormalizeV2PairingSecret(profile.pairingCode), message.sourceEndpointId);
        auto validation = ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
            nowUnixSeconds, replayCache, nowMilliseconds);
        if (!validation.accepted)
            return { validation.reason == L"authentication_failed" ? UnboundProbeMatchStatus::AuthenticationFailed
                : UnboundProbeMatchStatus::NoMatch };
        return { UnboundProbeMatchStatus::Matched, index, validation.duplicate };
    }

    V2Message CreateUnboundStatusResponse(V2Message const& probe, std::wstring const& localEndpointId,
        int64_t nowUnixSeconds, std::wstring nonce, std::wstring const& pairingCode,
        ProbeKeyProvider const& keyProvider)
    {
        V2Message response;
        response.type = L"status_response";
        response.eventId = probe.eventId;
        response.sourceEndpointId = localEndpointId;
        response.targetEndpointId = probe.sourceEndpointId;
        response.sourcePlatform = L"windows";
        response.timestamp = nowUnixSeconds;
        response.nonce = std::move(nonce);
        auto key = keyProvider ? keyProvider(pairingCode, localEndpointId) :
            DeriveV2AuthenticationKey(NormalizeV2PairingSecret(pairingCode), localEndpointId);
        return SignV2Message(std::move(response), key);
    }
}
