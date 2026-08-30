#pragma once

#include "SettingsWindow.g.h"
#include "AboutInfo.h"
#include "AppConfig.h"
#include "DdcControl.h"
#include "ProfileDetection.h"
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
            std::function<void(::DisplaySwitcher::Native::AppConfig const&,
                std::function<void(bool, std::wstring const&)>)> checkNetworkAccess,
            std::function<void(::DisplaySwitcher::Native::AppConfig const&, std::wstring const&,
                std::function<void(::DisplaySwitcher::Native::ProfileDetectionResult const&)>)> detectProfile,
            std::function<void()> beginUsbLearning,
            std::function<void()> endUsbLearning,
            std::function<void()> closed);
        void SetConnectionStatus(std::wstring const& status, bool connected);
        void ShowWindow();
        void CloseForExit();

    private:
        Microsoft::UI::Xaml::UIElement BuildContent();
        Microsoft::UI::Xaml::Controls::Border CreateSection(
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
        void StartUsbLearning(std::wstring const& profileId);
        void PollUsbLearning();
        void ShowUsbLearningCandidates();
        void EndUsbLearning(std::wstring const& message = {});
        void LoadDdcMonitors();
        void CaptureDisplayEditors();
        void RebuildDisplayEditors();
        void RebuildUsbMappingEditors();
        void CaptureProfileEditors();
        void RebuildProfileEditors();
        void RefreshProfileSelectors();
        void RefreshUsbDeviceSelection();
        void RemoveProfile(std::wstring const& id);
        void DetectProfile(std::wstring const& id);
        void CompleteProfileDetection(std::wstring const& id,
            ::DisplaySwitcher::Native::ProfileDetectionResult const& result);
        void UpdateDisplayBackendVisibility();
        ::DisplaySwitcher::Native::AppConfig WorkingDdcConfig();
        void ReadDdc(std::wstring const& displayId);
        void WriteDdc(std::wstring const& displayId, ::DisplaySwitcher::Native::DdcVcpCode code, int value);
        void CompleteDdcOperation(::DisplaySwitcher::Native::AppConfig const& config,
            ::DisplaySwitcher::Native::DdcControlBatchResult const& result,
            ::DisplaySwitcher::Native::DdcCancellationToken const& cancellation, bool write);
        bool Save(bool hideAfterSave = false);
        bool SaveImmediately();
        void ShowValidationError(std::wstring const& message);

        ::DisplaySwitcher::Native::AppConfig original_;
        std::function<bool(::DisplaySwitcher::Native::AppConfig const&)> saved_;
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::vector<std::wstring> const&, ::DisplaySwitcher::Native::DdcCancellationToken const&)> readDdc_;
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::wstring const&, ::DisplaySwitcher::Native::DdcVcpCode, int, bool,
            ::DisplaySwitcher::Native::DdcCancellationToken const&)> writeDdc_;
        std::function<bool(std::vector<::DisplaySwitcher::Native::DisplayConfig> const&)> commitDdcCache_;
        std::function<void(::DisplaySwitcher::Native::AppConfig const&,
            std::function<void(bool, std::wstring const&)>)> checkNetworkAccess_;
        std::function<void(::DisplaySwitcher::Native::AppConfig const&, std::wstring const&,
            std::function<void(::DisplaySwitcher::Native::ProfileDetectionResult const&)>)> detectProfile_;
        std::function<void()> beginUsbLearning_;
        std::function<void()> endUsbLearning_;
        std::function<void()> closed_;
        ::DisplaySwitcher::Native::DdcCancellationSource ddcCancellation_;
        ::DisplaySwitcher::Native::UsbLearningSession usbLearning_;
        Microsoft::UI::Dispatching::DispatcherQueueTimer usbLearningTimer_{ nullptr };
        uint64_t usbLearningGeneration_{};
        bool usbLearningDialogOpen_{};
        bool usbLearningRuntimePaused_{};
        std::vector<::DisplaySwitcher::Native::UsbDeviceInfo> devices_;
        std::vector<::DisplaySwitcher::Native::DdcMonitorInfo> ddcMonitors_;
        std::vector<::DisplaySwitcher::Native::DisplayConfig> workingDisplays_;
        std::vector<::DisplaySwitcher::Native::CollaborationProfile> workingProfiles_;
        std::wstring selectedProfileId_;
        std::wstring usbSelectedProfileId_;
        struct DisplayEditorControls
        {
            std::wstring id;
            Microsoft::UI::Xaml::Controls::ToggleSwitch brightnessEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch brightnessShowInTray{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch contrastEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch contrastShowInTray{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch volumeEnabled{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch volumeShowInTray{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider brightness{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider contrast{ nullptr };
            Microsoft::UI::Xaml::Controls::Slider volume{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock status{ nullptr };
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
        Microsoft::UI::Xaml::Controls::ToggleSwitch usbSwitchDisplaysOnArrival_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel profileEditorsPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox profileSelector_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox usbProfileSelector_{ nullptr };
        Microsoft::UI::Xaml::Controls::ComboBox usbDevices_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock usbDeviceStatus_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel usbMappingsPanel_{ nullptr };
        struct UsbMappingEditor
        {
            std::wstring displayId;
            Microsoft::UI::Xaml::Controls::TextBox targetInput{ nullptr };
        };
        std::vector<UsbMappingEditor> usbMappingEditors_;
        std::wstring selectedUsbLocalReference_;
        std::wstring selectedUsbName_;
        int selectedUsbVendorId_{ -1 };
        int selectedUsbProductId_{ -1 };
        Microsoft::UI::Xaml::Controls::ComboBox displayBackend_{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel displayEditorsPanel_{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBox controlMyMonitor_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch linkAllDisplays_{ nullptr };
        Microsoft::UI::Xaml::Controls::ToggleSwitch autoStart_{ nullptr };
        bool initialized_{};
        bool loading_{};
    };
}

namespace winrt::DisplaySwitcher::Native::factory_implementation
{
    struct SettingsWindow : SettingsWindowT<SettingsWindow, implementation::SettingsWindow> {};
}
