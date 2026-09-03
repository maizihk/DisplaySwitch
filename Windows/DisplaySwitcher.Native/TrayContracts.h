#pragma once

namespace DisplaySwitcher::Native
{
    enum class TraySemanticIcon
    {
        Usb,
        SwitchProfile,
        Brightness,
        Contrast,
        Volume,
        Settings,
        Exit,
    };

    enum class TrayActivationAction
    {
        None,
        ShowMenu,
    };

    inline wchar_t const* TraySemanticIconGlyph(TraySemanticIcon icon) noexcept
    {
        switch (icon)
        {
        case TraySemanticIcon::Usb: return L"\uE88E";
        case TraySemanticIcon::SwitchProfile: return L"\uE8AB";
        case TraySemanticIcon::Brightness: return L"\uE706";
        case TraySemanticIcon::Contrast: return L"\uE793";
        case TraySemanticIcon::Volume: return L"\uE767";
        case TraySemanticIcon::Settings: return L"\uE713";
        case TraySemanticIcon::Exit: return L"\uE7E8";
        default: return L"\u2022";
        }
    }

    struct TrayPopupLayout
    {
        int width{};
        int iconLeft{};
        int iconWidth{};
        int textLeft{};
        int rightPadding{};
        int sliderLabelWidth{};
        int sliderTrackMinimumWidth{};
        int sliderValueWidth{};
        int sliderGap{};
    };

    inline TrayActivationAction ResolveTrayActivation(UINT notification) noexcept
    {
        return notification == WM_CONTEXTMENU || notification == WM_RBUTTONUP
            || notification == WM_LBUTTONUP || notification == WM_LBUTTONDBLCLK
            || notification == NIN_SELECT || notification == NIN_KEYSELECT
            ? TrayActivationAction::ShowMenu : TrayActivationAction::None;
    }

    inline TrayPopupLayout BuildTrayPopupLayout(UINT dpi, int widestTextWidth,
        int widestSliderLabelWidth, bool hasSliders) noexcept
    {
        if (!dpi) dpi = 96;
        auto scale = [dpi](int value) { return MulDiv(value, dpi, 96); };
        TrayPopupLayout result;
        result.iconLeft = scale(12);
        result.iconWidth = scale(18);
        result.textLeft = scale(40);
        result.rightPadding = scale(12);
        result.sliderLabelWidth = (std::max)(scale(32), (std::max)(0, widestSliderLabelWidth));
        result.sliderTrackMinimumWidth = scale(92);
        result.sliderValueWidth = scale(38);
        result.sliderGap = scale(4);
        auto textMinimum = result.textLeft + (std::max)(0, widestTextWidth) + result.rightPadding;
        auto sliderMinimum = result.textLeft + result.sliderLabelWidth + result.sliderGap
            + result.sliderTrackMinimumWidth + result.sliderGap + result.sliderValueWidth + result.rightPadding;
        auto visualTarget = scale(260);
        result.width = (std::max)(visualTarget, (std::max)(textMinimum, hasSliders ? sliderMinimum : 0));
        return result;
    }

    inline std::wstring UsbTrayStatusText(bool active)
    {
        return active ? L"USB 切换已开启" : L"USB 切换已关闭";
    }

    struct UsbTrayRuntimeConditions
    {
        bool automationConfigured{};
        bool safeState{};
        bool learning{};
        bool authoritativeTopology{};
    };

    inline bool ProjectUsbTrayConfiguredEnabled(bool persistedEnabled,
        UsbTrayRuntimeConditions const&) noexcept
    {
        return persistedEnabled;
    }
}
