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
        V2ReplayCache* replayCache)
    {
        if (message.type != L"status_probe" || message.targetEndpointId) return {};
        if (!IsValidDisplayId(localEndpointId) || EqualId(message.sourceEndpointId, localEndpointId))
            return { UnboundProbeMatchStatus::EndpointConflict };
        for (auto const& profile : candidates)
            if (!profile.peerEndpointId.empty() && EqualId(profile.peerEndpointId, message.sourceEndpointId))
                return { UnboundProbeMatchStatus::EndpointConflict };

        std::vector<size_t> hostCandidates;
        std::vector<size_t> authenticatedCandidates;
        for (size_t index = 0; index < candidates.size(); ++index)
        {
            auto const& profile = candidates[index];
            if (!profile.peerEndpointId.empty() || profile.peerProtocolVersion == 1 || !hostMatches(profile, source)) continue;
            hostCandidates.push_back(index);
            try
            {
                auto secret = NormalizeV2PairingSecret(profile.pairingCode);
                auto key = DeriveV2AuthenticationKey(secret, message.sourceEndpointId);
                if (ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
                    nowUnixSeconds, nullptr, nowMilliseconds).accepted)
                    authenticatedCandidates.push_back(index);
            }
            catch (...) {}
        }
        if (authenticatedCandidates.empty())
            return { hostCandidates.empty() ? UnboundProbeMatchStatus::NoMatch : UnboundProbeMatchStatus::AuthenticationFailed };
        if (authenticatedCandidates.size() != 1) return { UnboundProbeMatchStatus::Ambiguous };

        auto index = authenticatedCandidates.front();
        auto const& profile = candidates[index];
        auto secret = NormalizeV2PairingSecret(profile.pairingCode);
        auto key = DeriveV2AuthenticationKey(secret, message.sourceEndpointId);
        auto validation = ValidateV2Message(message, localEndpointId, message.sourceEndpointId, key,
            nowUnixSeconds, replayCache, nowMilliseconds);
        if (!validation.accepted)
            return { validation.reason == L"authentication_failed" ? UnboundProbeMatchStatus::AuthenticationFailed
                : UnboundProbeMatchStatus::NoMatch };
        return { UnboundProbeMatchStatus::Matched, index, validation.duplicate };
    }

    V2Message CreateUnboundStatusResponse(V2Message const& probe, std::wstring const& localEndpointId,
        int64_t nowUnixSeconds, std::wstring nonce, std::wstring const& pairingCode)
    {
        V2Message response;
        response.type = L"status_response";
        response.eventId = probe.eventId;
        response.sourceEndpointId = localEndpointId;
        response.targetEndpointId = probe.sourceEndpointId;
        response.sourcePlatform = L"windows";
        response.timestamp = nowUnixSeconds;
        response.nonce = std::move(nonce);
        auto secret = NormalizeV2PairingSecret(pairingCode);
        auto key = DeriveV2AuthenticationKey(secret, localEndpointId);
        return SignV2Message(std::move(response), key);
    }
}
