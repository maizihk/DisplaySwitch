#include "pch.h"
#include "MediaKeys.h"

namespace
{
    using namespace DisplaySwitcher::Native;

    DdcVcpCode ActionCode(MediaKeyAction action) noexcept
    {
        return action == MediaKeyAction::BrightnessDown || action == MediaKeyAction::BrightnessUp
            ? DdcVcpCode::Brightness : DdcVcpCode::Volume;
    }

    bool IsIncrease(MediaKeyAction action) noexcept
    {
        return action == MediaKeyAction::BrightnessUp || action == MediaKeyAction::VolumeUp;
    }

    bool IsDecrease(MediaKeyAction action) noexcept
    {
        return action == MediaKeyAction::BrightnessDown || action == MediaKeyAction::VolumeDown;
    }
}

namespace DisplaySwitcher::Native
{
    std::optional<MediaKeyAction> NormalizeKeyboardMediaKey(uint16_t virtualKey, bool keyDown) noexcept
    {
        if (!keyDown) return std::nullopt;
        if (virtualKey == VK_VOLUME_MUTE) return MediaKeyAction::VolumeMute;
        if (virtualKey == VK_VOLUME_DOWN) return MediaKeyAction::VolumeDown;
        if (virtualKey == VK_VOLUME_UP) return MediaKeyAction::VolumeUp;
        return std::nullopt;
    }

    std::optional<MediaKeyAction> NormalizeConsumerControlUsage(uint16_t usage, bool pressed) noexcept
    {
        if (!pressed) return std::nullopt;
        // HID Usage Tables, Consumer page: Brightness Increment / Decrement.
        if (usage == 0x006F) return MediaKeyAction::BrightnessUp;
        if (usage == 0x0070) return MediaKeyAction::BrightnessDown;
        if (usage == 0x00E2) return MediaKeyAction::VolumeMute;
        if (usage == 0x00E9) return MediaKeyAction::VolumeUp;
        if (usage == 0x00EA) return MediaKeyAction::VolumeDown;
        return std::nullopt;
    }

    std::wstring MediaKeyRouter::CanonicalId(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), towlower);
        return value;
    }

    std::optional<int> MediaKeyRouter::PendingValue(std::wstring const& displayId, DdcVcpCode code) const
    {
        auto found = pendingValues_.find({ CanonicalId(displayId), code });
        return found == pendingValues_.end() ? std::nullopt : std::optional<int>{ found->second };
    }

    void MediaKeyRouter::SetPending(std::vector<std::wstring> const& displayIds, DdcVcpCode code, int value)
    {
        for (auto const& displayId : displayIds) pendingValues_[{ CanonicalId(displayId), code }] = value;
    }

    MediaKeyPlan MediaKeyRouter::Plan(AppConfig const& config, DisplayTopologyTrust topologyTrust,
        MediaKeyAction action, uint64_t configurationGeneration, int step)
    {
        MediaKeyPlan plan;
        if (configurationGeneration_ != configurationGeneration)
        {
            configurationGeneration_ = configurationGeneration;
            pendingValues_.clear();
        }
        if (config.displayConfigurationSafeMode
            || topologyTrust != DisplayTopologyTrust::LocalPhysicalAuthoritative)
        {
            plan.state = MediaKeyPlanState::UntrustedTopology;
            return plan;
        }
        step = (std::max)(1, step);
        auto code = ActionCode(action);
        auto controls = BuildDdcControlProjection(config, topologyTrust, false);
        controls.erase(std::remove_if(controls.begin(), controls.end(), [=](auto const& control)
            { return control.code != code || control.targetDisplayIds.empty(); }), controls.end());
        if (controls.empty())
        {
            plan.state = MediaKeyPlanState::NoEligibleTargets;
            return plan;
        }

        bool sawMixed{};
        bool sawUnknown{};
        for (auto const& control : controls)
        {
            if (control.valueState == DdcProjectedValueState::Mixed)
            {
                sawMixed = true;
                continue;
            }
            if (control.valueState != DdcProjectedValueState::Value)
            {
                sawUnknown = true;
                continue;
            }

            auto current = control.value;
            if (control.linked)
            {
                std::optional<int> commonPending;
                bool pendingMixed{};
                for (auto const& displayId : control.targetDisplayIds)
                {
                    auto pending = PendingValue(displayId, code);
                    if (!pending) { commonPending.reset(); pendingMixed = true; break; }
                    if (!commonPending) commonPending = pending;
                    else if (*commonPending != *pending) { pendingMixed = true; break; }
                }
                if (!pendingMixed && commonPending) current = *commonPending;
            }
            else if (auto pending = PendingValue(control.displayId, code)) current = *pending;

            std::optional<int> target;
            if (IsIncrease(action)) target = (std::min)(control.maximum, current + step);
            else if (IsDecrease(action)) target = (std::max)(0, current - step);
            else if (current > 0)
            {
                for (auto const& displayId : control.targetDisplayIds)
                    muteRestoreValues_[CanonicalId(displayId)] = current;
                target = 0;
            }
            else
            {
                std::optional<int> commonRestore;
                bool invalidRestore{};
                for (auto const& displayId : control.targetDisplayIds)
                {
                    auto found = muteRestoreValues_.find(CanonicalId(displayId));
                    if (found == muteRestoreValues_.end() || found->second <= 0
                        || found->second > control.maximum)
                    {
                        invalidRestore = true;
                        break;
                    }
                    if (!commonRestore) commonRestore = found->second;
                    else if (control.linked && *commonRestore != found->second)
                    {
                        invalidRestore = true;
                        break;
                    }
                }
                if (!invalidRestore) target = commonRestore;
            }
            if (!target || *target == current) continue;
            SetPending(control.targetDisplayIds, code, *target);
            plan.writes.push_back({ control.displayId, code, *target, control.linked,
                control.targetDisplayIds });
        }
        if (!plan.writes.empty()) plan.state = MediaKeyPlanState::Ready;
        else if (sawMixed) plan.state = MediaKeyPlanState::MixedLinkedValue;
        else if (sawUnknown) plan.state = MediaKeyPlanState::UnknownValue;
        else plan.state = MediaKeyPlanState::NoValueChange;
        return plan;
    }

    void MediaKeyRouter::OnWriteFailed(DdcVcpCode code,
        std::vector<std::wstring> const& targetDisplayIds)
    {
        for (auto const& displayId : targetDisplayIds)
            pendingValues_.erase({ CanonicalId(displayId), code });
    }

    void MediaKeyRouter::ResetPending() noexcept
    {
        pendingValues_.clear();
    }
}
