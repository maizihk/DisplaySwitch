#pragma once

#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    struct InputSourceWriteResult
    {
        bool success{};
        DdcErrorKind error{ DdcErrorKind::None };
        std::wstring message;
        uint64_t topologyGeneration{};
    };

    class IInputSourceTransport
    {
    public:
        virtual ~IInputSourceTransport() = default;
        virtual DdcBackendStatus Status() const = 0;
        virtual InputSourceWriteResult WriteInputSource(std::wstring const& monitorId, int value,
            DdcCancellationToken const& cancellation) = 0;
        virtual uint64_t TopologyGeneration() const noexcept = 0;
        virtual DisplayTopologyTrust TopologyTrust() const noexcept = 0;
        virtual void InvalidateTopology() noexcept = 0;
    };

    using DisplayActionObserver = std::function<void(DisplayConfig const&, bool, DdcErrorKind)>;

    struct InputSourceActionPlan
    {
        AppConfig config;
        bool topologyTrusted{};
        std::wstring error;
    };

    InputSourceActionPlan PrepareInputSourceActionPlan(AppConfig const& config,
        DdcEnumerationResult const& enumeration);

    InputSourceWriteResult WriteInputSourceWithOneRefresh(IInputSourceTransport& transport,
        std::wstring const& monitorId, int value, DdcCancellationToken const& cancellation);

    class InputSourceSwitchService final
    {
    public:
        explicit InputSourceSwitchService(IInputSourceTransport* transport,
            std::function<bool()> sideEffectsAllowed = {});
        ActionResult SwitchDisplaysToMac(AppConfig const& config, DdcCancellationToken const& cancellation,
            DisplayActionObserver observer = {}) const;

    private:
        bool Allowed(AppConfig const& config, DdcCancellationToken const& cancellation) const;

        IInputSourceTransport* transport_{};
        std::function<bool()> sideEffectsAllowed_;
    };

    ActionResult SwitchDisplaysToMac(AppConfig const& config, IInputSourceTransport* transport,
        DisplayActionObserver observer = {});
}
