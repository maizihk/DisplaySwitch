#pragma once

#include "SettingsWindow.g.h"
#include "AppConfig.h"
#include "DdcControl.h"
#include "SystemActions.h"
#include "UsbWatcher.h"

namespace winrt::DisplaySwitcher::Native::implementation
{
    struct SettingsWindow : SettingsWindowT<SettingsWindow>
    {
        SettingsWindow();
        void Initialize(::DisplaySwitcher::Native::AppConfig const& config,
            std::function<bool(::DisplaySwitcher::Native::AppConfig const&)> saved,
            std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
                std::vector<std::wstring> const&, ::DisplaySwitcher::Native::DdcCancellationToken const&)> readDdc,
            std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
                std::wstring const&, ::DisplaySwitcher::Native::DdcVcpCode, int, bool,
                ::DisplaySwitcher::Native::DdcCancellationToken const&)> writeDdc,
            std::function<bool(std::vector<::DisplaySwitcher::Native::DisplayConfig> const&)> commitDdcCache,
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
        void CaptureDisplayEditors();
        void RebuildDisplayEditors();
        void CaptureProfileEditors();
        void RebuildProfileEditors();
        void RemoveProfile(std::wstring const& id);
        void DetectProfile(std::wstring const& id);
        void UpdateDisplayBackendVisibility();
        ::DisplaySwitcher::Native::AppConfig WorkingDdcConfig();
        void ReadDdc(std::wstring const& displayId);
        void WriteDdc(std::wstring const& displayId, ::DisplaySwitcher::Native::DdcVcpCode code, int value);
        void CompleteDdcOperation(::DisplaySwitcher::Native::AppConfig const& config,
            ::DisplaySwitcher::Native::DdcControlBatchResult const& result,
            ::DisplaySwitcher::Native::DdcCancellationToken const& cancellation, bool write);
        void Save();
        void ShowValidationError(std::wstring const& message);

        ::DisplaySwitcher::Native::AppConfig original_;
        std::function<bool(::DisplaySwitcher::Native::AppConfig const&)> saved_;
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::vector<std::wstring> const&, ::DisplaySwitcher::Native::DdcCancellationToken const&)> readDdc_;
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::wstring const&, ::DisplaySwitcher::Native::DdcVcpCode, int, bool,
            ::DisplaySwitcher::Native::DdcCancellationToken const&)> writeDdc_;
        std::function<bool(std::vector<::DisplaySwitcher::Native::DisplayConfig> const&)> commitDdcCache_;
        std::function<void()> closed_;
        ::DisplaySwitcher::Native::DdcCancellationSource ddcCancellation_;
        std::vector<::DisplaySwitcher::Native::UsbDeviceInfo> devices_;
        std::vector<::DisplaySwitcher::Native::DdcMonitorInfo> ddcMonitors_;
        std::vector<::DisplaySwitcher::Native::DisplayConfig> workingDisplays_;
        std::vector<::DisplaySwitcher::Native::CollaborationProfile> workingProfiles_;
        struct DisplayEditorControls
        {
            std::wstring id;
            Microsoft::UI::Xaml::Controls::TextBox name{ nullptr };
            Microsoft::UI::Xaml::Controls::ComboBox backend{ nullptr };
            Microsoft::UI::Xaml::Controls::ComboBox nativeMonitor{ nullptr };
            std::vector<std::wstring> nativeMonitorIds;
            Microsoft::UI::Xaml::Controls::TextBox controlMonitorPath{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBox macInput{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch readEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch brightnessEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch contrastEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch volumeEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider brightness{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider contrast{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider volume{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock status{ nullptr };
            Microsoft::UI::Xaml::FrameworkElement nativeFields{ nullptr };
            Microsoft::UI::Xaml::FrameworkElement controlMyMonitorFields{ nullptr };
        };
        std::vector<DisplayEditorControls> displayEditors_;
        struct ProfileMappingControls
        {
            std::wstring displayId;
            Microsoft::UI::Xaml::Controls::TextBox peerInput{ nullptr };
        };
        struct ProfileEditorControls
        {
            std::wstring id;
            Microsoft::UI::Xaml::Controls::TextBox name{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch enabled{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBox peerHost{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBox peerPort{ nullptr };
            Microsoft::UI::Xaml::Controls::PasswordBox pairingCode{ nullptr };
            std::vector<ProfileMappingControls> mappings;
        };
        std::vector<ProfileEditorControls> profileEditors_;
        Microsoft::UI::Windowing::AppWindow appWindow_{ nullptr };
        Microsoft::UI::Xaml::Controls::TabView tabs_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock validation_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock connectionDot_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock connectionStatus_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch usbAutomation_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel profileEditorsPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox usbDevices_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox vendorId_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox productId_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox displayBackend_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel displayEditorsPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel nativeDdcPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel controlMyMonitorPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox controlMyMonitor_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch linkAllDisplays_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch autoStart_{ nullptr };
        bool initialized_{};
    };
}

namespace winrt::DisplaySwitcher::Native::factory_implementation
{
    struct SettingsWindow : SettingsWindowT<SettingsWindow, implementation::SettingsWindow> {};
}
