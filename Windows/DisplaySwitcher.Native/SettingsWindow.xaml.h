#pragma once

#include "SettingsWindow.g.h"
#include "AppConfig.h"
#include "SystemActions.h"
#include "UsbWatcher.h"

namespace winrt::DisplaySwitcher::Native::implementation
{
    struct SettingsWindow : SettingsWindowT<SettingsWindow>
    {
        SettingsWindow();
        void Initialize(::DisplaySwitcher::Native::AppConfig const& config,
            std::function<void(::DisplaySwitcher::Native::AppConfig const&)> saved,
            std::function<void()> closed);
        void SetConnectionStatus(std::wstring const& status, bool connected);
        void ShowWindow();
        void CloseForExit();

    private:
        Microsoft::UI::Xaml::UIElement BuildContent();
        Microsoft::UI::Xaml::Controls::Border CreateSection(std::wstring const& title,
            std::vector<Microsoft::UI::Xaml::UIElement> const& children);
        Microsoft::UI::Xaml::Controls::Border CreateCard(Microsoft::UI::Xaml::UIElement const& child);
        Microsoft::UI::Xaml::Controls::ScrollViewer CreatePage(
            std::vector<Microsoft::UI::Xaml::UIElement> const& children);
        Microsoft::UI::Xaml::Controls::StackPanel CreateTabHeader(wchar_t const* glyph, wchar_t const* text);
        Microsoft::UI::Xaml::Controls::Grid CreateTwoColumn(Microsoft::UI::Xaml::FrameworkElement const& left,
            Microsoft::UI::Xaml::FrameworkElement const& right, double rightWidth = -1);
        Microsoft::UI::Xaml::Controls::TextBlock CreateSubheading(std::wstring const& text);
        void ResizeAndCenter();
        void ApplyTitleBarTheme();
        void LoadValues(::DisplaySwitcher::Native::AppConfig const& config);
        void LoadUsbDevices();
        void LoadDdcMonitors();
        void UpdateDisplayBackendVisibility();
        void Save();
        void ShowValidationError(std::wstring const& message);

        ::DisplaySwitcher::Native::AppConfig original_;
        std::function<void(::DisplaySwitcher::Native::AppConfig const&)> saved_;
        std::function<void()> closed_;
        std::vector<::DisplaySwitcher::Native::UsbDeviceInfo> devices_;
        std::vector<::DisplaySwitcher::Native::DdcMonitorInfo> ddcMonitors_;
        Microsoft::UI::Windowing::AppWindow appWindow_{ nullptr };
        Microsoft::UI::Xaml::Controls::TabView tabs_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock validation_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock connectionDot_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock connectionStatus_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch usbAutomation_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch coordination_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox peerHost_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox port_{ nullptr };
        Microsoft::UI::Xaml::Controls::PasswordBox pairingCode_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox usbDevices_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox vendorId_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox productId_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox displayBackend_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox redmiNativeMonitor_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox dellNativeMonitor_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel nativeDdcPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel controlMyMonitorPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox controlMyMonitor_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox redmiPath_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox redmiInput_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox dellPath_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox dellInput_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch autoStart_{ nullptr };
        bool initialized_{};
    };
}

namespace winrt::DisplaySwitcher::Native::factory_implementation
{
    struct SettingsWindow : SettingsWindowT<SettingsWindow, implementation::SettingsWindow> {};
}
