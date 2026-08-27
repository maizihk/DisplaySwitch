#pragma once

#include "ProtocolTypes.h"

#include <string>
#include <string_view>

namespace DisplaySwitcher::Native
{
    struct MessageValidationResult
    {
        bool accepted{};
        std::wstring reason;
    };

    MessageValidationResult ParsePeerMessage(std::string_view json, PeerMessage& message);
    MessageValidationResult ValidatePeerMessage(PeerMessage const& message, std::wstring const& localPlatform,
        std::wstring const& configuredPairingCode, double nowUnixSeconds);
}
