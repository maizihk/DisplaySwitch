#pragma once

#include <optional>
#include <string>

namespace DisplaySwitcher::Native
{
    struct PeerMessage
    {
        int version{};
        std::wstring type;
        std::wstring eventId;
        std::wstring source;
        std::wstring target;
        double timestamp{};
        std::wstring pairingCode;
        std::optional<bool> wakeSucceeded;
    };
}
