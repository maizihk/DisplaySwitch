#pragma once

namespace DisplaySwitcher::Native
{
    inline constexpr double TrayIconStrokeRatio = 0.06;

    enum class TaskbarTheme
    {
        Light,
        Dark,
        Unknown,
    };

    enum class TrayIconTone
    {
        Black,
        White,
    };

    struct TrayIconGeometry
    {
        int pixelSize{};
        int bodyLeft{};
        int bodyTop{};
        int bodySize{};
    };

    struct TrayIconRenderState
    {
        TrayIconTone tone{ TrayIconTone::White };
        int pixelSize{};

        bool operator==(TrayIconRenderState const&) const noexcept = default;
    };

    inline TaskbarTheme ClassifyTaskbarTheme(std::optional<DWORD> systemUsesLightTheme) noexcept
    {
        if (!systemUsesLightTheme || *systemUsesLightTheme > 1) return TaskbarTheme::Unknown;
        return *systemUsesLightTheme ? TaskbarTheme::Light : TaskbarTheme::Dark;
    }

    inline TrayIconTone SelectTrayIconTone(TaskbarTheme theme, int fallbackBackgroundLuminance) noexcept
    {
        if (theme == TaskbarTheme::Light) return TrayIconTone::Black;
        if (theme == TaskbarTheme::Dark) return TrayIconTone::White;
        return fallbackBackgroundLuminance >= 128 ? TrayIconTone::Black : TrayIconTone::White;
    }

    inline int TrayIconPixelSizeForDpi(UINT dpi) noexcept
    {
        if (!dpi) dpi = 96;
        return (std::clamp)(MulDiv(16, static_cast<int>(dpi), 96), 16, 64);
    }

    inline TrayIconGeometry BuildTrayIconGeometry(UINT dpi) noexcept
    {
        TrayIconGeometry result;
        result.pixelSize = TrayIconPixelSizeForDpi(dpi);
        result.bodySize = (std::max)(1, MulDiv(result.pixelSize, 88, 100));
        result.bodyLeft = (result.pixelSize - result.bodySize) / 2;
        result.bodyTop = (result.pixelSize - result.bodySize) / 2;
        return result;
    }

    inline bool TrayIconRefreshRequired(std::optional<TrayIconRenderState> const& current,
        TrayIconRenderState const& desired) noexcept
    {
        return !current || *current != desired;
    }

    inline bool IsTrayAppearanceMessage(UINT message) noexcept
    {
        return message == WM_SETTINGCHANGE || message == WM_THEMECHANGED ||
            message == WM_SYSCOLORCHANGE || message == WM_DWMCOLORIZATIONCOLORCHANGED ||
            message == WM_DPICHANGED;
    }

    std::vector<uint32_t> RenderMonochromeTrayIconPixels(
        TrayIconGeometry const& geometry, TrayIconTone tone);
    HICON CreateMonochromeTrayIcon(TrayIconGeometry const& geometry, TrayIconTone tone);
    TrayIconTone ReadSystemTrayIconTone() noexcept;
}
