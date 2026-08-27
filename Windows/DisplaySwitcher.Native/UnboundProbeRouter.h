#pragma once

#include "DisplayModel.h"
#include "V2Protocol.h"

namespace DisplaySwitcher::Native
{
    struct DatagramSource
    {
        std::wstring address;
        int port{};
    };

    enum class UnboundProbeMatchStatus
    {
        Matched,
        NotApplicable,
        NoMatch,
        AuthenticationFailed,
        Ambiguous,
        EndpointConflict,
    };

    struct UnboundProbeMatch
    {
        UnboundProbeMatchStatus status{ UnboundProbeMatchStatus::NotApplicable };
        std::optional<size_t> profileIndex;
        bool duplicate{};
    };

    using ProbeHostMatcher = std::function<bool(CollaborationProfile const&, DatagramSource const&)>;

    UnboundProbeMatch MatchUnboundStatusProbe(std::vector<CollaborationProfile> const& candidates,
        std::wstring const& localEndpointId, DatagramSource const& source, V2Message const& message,
        int64_t nowUnixSeconds, int64_t nowMilliseconds, ProbeHostMatcher const& hostMatches,
        V2ReplayCache* replayCache = nullptr);

    V2Message CreateUnboundStatusResponse(V2Message const& probe, std::wstring const& localEndpointId,
        int64_t nowUnixSeconds, std::wstring nonce, std::wstring const& pairingCode);
}
