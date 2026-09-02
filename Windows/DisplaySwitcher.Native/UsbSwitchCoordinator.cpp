#include "pch.h"
#include "DisplayModel.h"
#include "UsbSwitchCoordinator.h"

namespace DisplaySwitcher::Native
{
    UsbSwitchCoordinator::UsbSwitchCoordinator(UsbSwitchInitialState initial) : state_(std::move(initial)) {}

    void UsbSwitchCoordinator::UpdateConfiguration(UsbSwitchInitialState initial) noexcept
    {
        auto preserveBaseline = state_.enabled == initial.enabled && state_.learning == initial.learning &&
            state_.safeState == initial.safeState && state_.bindingKey == initial.bindingKey;
        if (preserveBaseline) initial.baselinePresence = state_.baselinePresence;
        else
        {
            initial.baselinePresence.reset();
            lastWakeMilliseconds_.reset();
        }
        state_ = std::move(initial);
    }

    void UsbSwitchCoordinator::ConfigurationChanged() noexcept
    {
        state_.baselinePresence.reset();
        lastWakeMilliseconds_.reset();
    }

    std::vector<UsbSwitchAction> UsbSwitchCoordinator::RequestWake(int64_t nowMilliseconds)
    {
        if (lastWakeMilliseconds_ && nowMilliseconds - *lastWakeMilliseconds_ < WakeCoalescingWindowMilliseconds) return {};
        lastWakeMilliseconds_ = nowMilliseconds;
        return { { UsbSwitchAction::Kind::WakeDisplay } };
    }

    std::vector<UsbSwitchAction> UsbSwitchCoordinator::ReceiveWakeDisplay(int64_t nowMilliseconds)
    {
        if (state_.learning || state_.safeState) return {};
        return RequestWake(nowMilliseconds);
    }

    std::vector<UsbSwitchAction> UsbSwitchCoordinator::ObserveUsb(int64_t nowMilliseconds, bool present)
    {
        if (!state_.enabled || state_.learning || state_.safeState) return {};
        if (!state_.baselinePresence)
        {
            state_.baselinePresence = present;
            return { { UsbSwitchAction::Kind::EstablishBaseline } };
        }
        if (*state_.baselinePresence == present) return {};
        auto wasPresent = *state_.baselinePresence;
        state_.baselinePresence = present;
        if (!wasPresent && present) return RequestWake(nowMilliseconds);

        std::vector<UsbSwitchAction> actions;
        for (auto const& mapping : state_.displayMappings)
        {
            if (!mapping.targetInput || !IsValidInputSourceValue(*mapping.targetInput) || !mapping.available)
            {
                actions.push_back({ UsbSwitchAction::Kind::Report, mapping.displayId, {}, {}, L"missing_mapping" });
                continue;
            }
            actions.push_back({ UsbSwitchAction::Kind::SwitchDisplay, mapping.displayId, mapping.targetInput, mapping.switchSucceeds });
            if (!mapping.switchSucceeds)
                actions.push_back({ UsbSwitchAction::Kind::Report, mapping.displayId, {}, {}, L"ddc_failed" });
        }
        if (state_.collaborationWakeEnabled)
        {
            if (state_.collaborationProfileValid) actions.push_back({ UsbSwitchAction::Kind::SendWakeDisplay });
            else actions.push_back({ UsbSwitchAction::Kind::Report, {}, {}, {}, L"wake_not_sent" });
        }
        return actions;
    }
}
