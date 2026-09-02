#include "pch.h"
#include "SettingsWindow.xaml.h"
#include "resource.h"

#if __has_include("SettingsWindow.g.cpp")
#include "SettingsWindow.g.cpp"
#endif

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Windowing;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Media;
using namespace Microsoft::UI::Xaml::Automation;

namespace
{
    void Header(Control const& control, wchar_t const* text)
    {
        if (auto textBox = control.try_as<TextBox>()) textBox.Header(box_value(text));
        else if (auto passwordBox = control.try_as<PasswordBox>()) passwordBox.Header(box_value(text));
        else if (auto comboBox = control.try_as<ComboBox>()) comboBox.Header(box_value(text));
        else if (auto toggleSwitch = control.try_as<ToggleSwitch>()) toggleSwitch.Header(box_value(text));
    }

    void ConfigureCompactToggle(ToggleSwitch const& toggle, std::wstring const& automationName)
    {
        toggle.Header(nullptr);
        toggle.OnContent(box_value(L""));
        toggle.OffContent(box_value(L""));
        toggle.MinWidth(0);
        toggle.Width(40);
        toggle.HorizontalAlignment(HorizontalAlignment::Right);
        toggle.VerticalAlignment(VerticalAlignment::Center);
        AutomationProperties::SetName(toggle, automationName);
    }

    Grid LabeledToggleRow(std::wstring const& text, ToggleSwitch const& toggle)
    {
        ConfigureCompactToggle(toggle, text);

        auto row = Grid();
        row.HorizontalAlignment(HorizontalAlignment::Stretch);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto toggleColumn = ColumnDefinition(); toggleColumn.Width(GridLengthHelper::Auto());
        row.ColumnDefinitions().Append(labelColumn); row.ColumnDefinitions().Append(toggleColumn);

        auto label = TextBlock(); label.Text(text); label.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(toggle, 1);
        row.Children().Append(label); row.Children().Append(toggle);
        return row;
    }

    Grid LabeledControlRow(std::wstring const& text, FrameworkElement const& control)
    {
        if (auto textBox = control.try_as<TextBox>()) textBox.Header(nullptr);
        else if (auto comboBox = control.try_as<ComboBox>()) comboBox.Header(nullptr);
        control.HorizontalAlignment(HorizontalAlignment::Stretch);
        AutomationProperties::SetName(control, text);

        auto row = Grid(); row.ColumnSpacing(16);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto controlColumn = ColumnDefinition(); controlColumn.Width(GridLength{ 120 });
        row.ColumnDefinitions().Append(labelColumn); row.ColumnDefinitions().Append(controlColumn);

        auto label = TextBlock(); label.Text(text); label.VerticalAlignment(VerticalAlignment::Center);
        label.TextTrimming(TextTrimming::CharacterEllipsis);
        Grid::SetColumn(control, 1);
        row.Children().Append(label); row.Children().Append(control);
        return row;
    }

    Grid LabeledControlToggleRow(std::wstring const& text, FrameworkElement const& control,
        ToggleSwitch const& toggle, std::wstring const& toggleAutomationName)
    {
        if (auto textBox = control.try_as<TextBox>()) textBox.Header(nullptr);
        else if (auto comboBox = control.try_as<ComboBox>()) comboBox.Header(nullptr);
        control.HorizontalAlignment(HorizontalAlignment::Stretch);
        AutomationProperties::SetName(control, text);
        ConfigureCompactToggle(toggle, toggleAutomationName);

        auto row = Grid(); row.ColumnSpacing(16);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 200 });
        auto controlColumn = ColumnDefinition(); controlColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto toggleColumn = ColumnDefinition(); toggleColumn.Width(GridLengthHelper::Auto());
        row.ColumnDefinitions().Append(labelColumn); row.ColumnDefinitions().Append(controlColumn);
        row.ColumnDefinitions().Append(toggleColumn);

        auto label = TextBlock(); label.Text(text); label.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(control, 1); Grid::SetColumn(toggle, 2);
        row.Children().Append(label); row.Children().Append(control); row.Children().Append(toggle);
        return row;
    }

    Grid LabeledWideControlRow(std::wstring const& text, Control const& control)
    {
        if (auto textBox = control.try_as<TextBox>()) textBox.Header(nullptr);
        else if (auto passwordBox = control.try_as<PasswordBox>()) passwordBox.Header(nullptr);
        else if (auto comboBox = control.try_as<ComboBox>()) comboBox.Header(nullptr);
        control.HorizontalAlignment(HorizontalAlignment::Stretch);
        AutomationProperties::SetName(control, text);

        auto row = Grid(); row.ColumnSpacing(16);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 200 });
        auto controlColumn = ColumnDefinition(); controlColumn.Width(GridLength{ 1, GridUnitType::Star });
        row.ColumnDefinitions().Append(labelColumn); row.ColumnDefinitions().Append(controlColumn);
        auto label = TextBlock(); label.Text(text); label.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(control, 1); row.Children().Append(label); row.Children().Append(control);
        return row;
    }

    Grid PeerAddressRow(TextBox const& host, TextBox const& port)
    {
        host.Header(nullptr); port.Header(nullptr);
        host.HorizontalAlignment(HorizontalAlignment::Stretch); port.Width(120);
        AutomationProperties::SetName(host, L"对端地址"); AutomationProperties::SetName(port, L"对端端口");

        auto row = Grid(); row.ColumnSpacing(16);
        auto addressLabelColumn = ColumnDefinition(); addressLabelColumn.Width(GridLength{ 200 });
        auto hostColumn = ColumnDefinition(); hostColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto portLabelColumn = ColumnDefinition(); portLabelColumn.Width(GridLengthHelper::Auto());
        auto portColumn = ColumnDefinition(); portColumn.Width(GridLength{ 120 });
        row.ColumnDefinitions().Append(addressLabelColumn); row.ColumnDefinitions().Append(hostColumn);
        row.ColumnDefinitions().Append(portLabelColumn); row.ColumnDefinitions().Append(portColumn);

        auto addressLabel = TextBlock(); addressLabel.Text(L"对端地址"); addressLabel.VerticalAlignment(VerticalAlignment::Center);
        auto portLabel = TextBlock(); portLabel.Text(L"端口"); portLabel.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(host, 1); Grid::SetColumn(portLabel, 2); Grid::SetColumn(port, 3);
        row.Children().Append(addressLabel); row.Children().Append(host);
        row.Children().Append(portLabel); row.Children().Append(port);
        return row;
    }

    Grid UsbDeviceRow(ComboBox const& devices, Button const& learn)
    {
        devices.Header(nullptr); devices.HorizontalAlignment(HorizontalAlignment::Stretch);
        AutomationProperties::SetName(devices, L"USB 触发设备");
        learn.VerticalAlignment(VerticalAlignment::Center);

        auto row = Grid(); row.ColumnSpacing(12);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 200 });
        row.ColumnDefinitions().Append(labelColumn);
        auto devicesColumn = ColumnDefinition(); devicesColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto learnColumn = ColumnDefinition(); learnColumn.Width(GridLengthHelper::Auto());
        row.ColumnDefinitions().Append(devicesColumn); row.ColumnDefinitions().Append(learnColumn);

        auto label = TextBlock(); label.Text(L"触发设备"); label.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(devices, 1); Grid::SetColumn(learn, 2);
        row.Children().Append(label); row.Children().Append(devices);
        row.Children().Append(learn);
        return row;
    }

    std::wstring Trim(std::wstring value)
    {
        auto whitespace = [](wchar_t c) { return iswspace(c) != 0; };
        value.erase(value.begin(), std::find_if_not(value.begin(), value.end(), whitespace));
        value.erase(std::find_if_not(value.rbegin(), value.rend(), whitespace).base(), value.end());
        return value;
    }

    std::optional<int> ParseInteger(std::wstring const& text, int base, int minimum, int maximum)
    {
        auto value = Trim(text);
        if (value.empty()) return std::nullopt;
        wchar_t* end{};
        errno = 0;
        auto number = std::wcstol(value.c_str(), &end, base);
        if (errno || end != value.c_str() + value.size() || number < minimum || number > maximum) return std::nullopt;
        return static_cast<int>(number);
    }

    Microsoft::UI::Xaml::Media::Brush ThemeBrush(std::wstring const& key,
        Windows::UI::Color fallback)
    {
        auto resources = Application::Current().Resources();
        auto themed = resources.TryLookup(box_value(key));
        auto brush = themed.try_as<Microsoft::UI::Xaml::Media::SolidColorBrush>();
        return brush ? brush : Microsoft::UI::Xaml::Media::SolidColorBrush(fallback);
    }

    void ApplyStandardButtonGeometry(Button const& button, double minWidth = 88.0)
    {
        button.MinWidth(minWidth);
        button.MinHeight(32);
    }

    bool DisplayConfigEquals(::DisplaySwitcher::Native::DisplayConfig const& left,
        ::DisplaySwitcher::Native::DisplayConfig const& right)
    {
        return left.id == right.id && left.name == right.name && left.localInput == right.localInput &&
            left.readEnabled == right.readEnabled && left.brightnessEnabled == right.brightnessEnabled &&
            left.brightnessShowInTray == right.brightnessShowInTray && left.contrastEnabled == right.contrastEnabled &&
            left.contrastShowInTray == right.contrastShowInTray && left.volumeEnabled == right.volumeEnabled &&
            left.volumeShowInTray == right.volumeShowInTray && left.macInput == right.macInput &&
            left.nativeMonitorId == right.nativeMonitorId && left.brightnessMax == right.brightnessMax &&
            left.contrastMax == right.contrastMax && left.volumeMax == right.volumeMax &&
            left.brightnessValue == right.brightnessValue && left.contrastValue == right.contrastValue &&
            left.volumeValue == right.volumeValue;
    }

    bool UsbInputMappingEquals(::DisplaySwitcher::Native::UsbDisplayInputMapping const& left,
        ::DisplaySwitcher::Native::UsbDisplayInputMapping const& right)
    {
        return left.displayId == right.displayId && left.targetInput == right.targetInput;
    }

    bool DisplayInputMappingEquals(::DisplaySwitcher::Native::DisplayInputMapping const& left,
        ::DisplaySwitcher::Native::DisplayInputMapping const& right)
    {
        return left.displayId == right.displayId && left.peerInput == right.peerInput;
    }

    bool TriggerDeviceReferenceEquals(::DisplaySwitcher::Native::TriggerDeviceReference const& left,
        ::DisplaySwitcher::Native::TriggerDeviceReference const& right)
    {
        return left.kind == right.kind && left.localReference == right.localReference && left.displayName == right.displayName;
    }

    bool CollaborationProfileEquals(::DisplaySwitcher::Native::CollaborationProfile const& left,
        ::DisplaySwitcher::Native::CollaborationProfile const& right)
    {
        if (left.id != right.id || left.name != right.name || left.coordinationEnabled != right.coordinationEnabled ||
            left.peerHost != right.peerHost || left.peerPort != right.peerPort || left.pairingCode != right.pairingCode ||
            left.peerEndpointId != right.peerEndpointId || left.peerProtocolVersion != right.peerProtocolVersion)
            return false;
        if (left.displayInputs.size() != right.displayInputs.size()) return false;
        for (size_t index = 0; index < left.displayInputs.size(); ++index)
            if (!DisplayInputMappingEquals(left.displayInputs[index], right.displayInputs[index])) return false;
        if (left.triggerDevices.size() != right.triggerDevices.size()) return false;
        for (size_t index = 0; index < left.triggerDevices.size(); ++index)
            if (!TriggerDeviceReferenceEquals(left.triggerDevices[index], right.triggerDevices[index])) return false;
        return true;
    }

    bool UsbSwitchEquals(::DisplaySwitcher::Native::UsbSwitchConfig const& left,
        ::DisplaySwitcher::Native::UsbSwitchConfig const& right)
    {
        if (left.enabled != right.enabled || left.deviceLocalReference != right.deviceLocalReference ||
            left.deviceName != right.deviceName || left.vendorId != right.vendorId || left.productId != right.productId ||
            left.collaborationWakeEnabled != right.collaborationWakeEnabled ||
            left.collaborationProfileId != right.collaborationProfileId)
            return false;
        if (left.displayInputs.size() != right.displayInputs.size()) return false;
        for (size_t index = 0; index < left.displayInputs.size(); ++index)
            if (!UsbInputMappingEquals(left.displayInputs[index], right.displayInputs[index])) return false;
        return true;
    }

    bool AppConfigEquals(::DisplaySwitcher::Native::AppConfig const& left, ::DisplaySwitcher::Native::AppConfig const& right)
    {
        if (left.linkAllDisplays != right.linkAllDisplays || left.localEndpointId != right.localEndpointId ||
            left.localDeviceName != right.localDeviceName || left.listenPort != right.listenPort ||
            left.startWithWindows != right.startWithWindows ||
            left.detailedDiagnosticRecording != right.detailedDiagnosticRecording ||
            left.displayConfigurationSafeMode != right.displayConfigurationSafeMode) return false;
        if (left.displays.size() != right.displays.size()) return false;
        for (size_t index = 0; index < left.displays.size(); ++index)
            if (!DisplayConfigEquals(left.displays[index], right.displays[index])) return false;
        if (!UsbSwitchEquals(left.usbSwitch, right.usbSwitch)) return false;
        if (left.collaborationProfiles.size() != right.collaborationProfiles.size()) return false;
        for (size_t index = 0; index < left.collaborationProfiles.size(); ++index)
            if (!CollaborationProfileEquals(left.collaborationProfiles[index], right.collaborationProfiles[index])) return false;
        return true;
    }

    int64_t SteadyMilliseconds()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    std::vector<::DisplaySwitcher::Native::UsbLearningDevice> LearningDevices(
        std::vector<::DisplaySwitcher::Native::UsbDeviceInfo> const& devices)
    {
        std::vector<::DisplaySwitcher::Native::UsbLearningDevice> result;
        result.reserve(devices.size());
        for (size_t index = 0; index < devices.size(); ++index)
        {
            auto item = devices[index].LearningDevice();
            auto sameNameCount = std::count_if(devices.begin(), devices.end(), [&](auto const& device)
                { return _wcsicmp(device.name.c_str(), devices[index].name.c_str()) == 0; });
            if (sameNameCount > 1)
            {
                auto ordinal = 1 + std::count_if(devices.begin(), devices.begin() + static_cast<std::ptrdiff_t>(index), [&](auto const& device)
                    { return _wcsicmp(device.name.c_str(), devices[index].name.c_str()) == 0; });
                item.displayName += L"（" + std::to_wstring(ordinal) + L"）";
            }
            result.push_back(std::move(item));
        }
        return result;
    }
}

namespace winrt::DisplaySwitcher::Native::implementation
{
    SettingsWindow::SettingsWindow() { InitializeComponent(); }

    void SettingsWindow::Initialize(::DisplaySwitcher::Native::AppConfig const& config,
        std::function<bool(::DisplaySwitcher::Native::AppConfig const&)> saved,
        std::function<::DisplaySwitcher::Native::DdcEnumerationResult()> enumerateDdc,
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
        std::function<void()> cancelProfileDetection,
        std::function<void()> beginUsbLearning,
        std::function<void()> endUsbLearning,
        std::function<::DisplaySwitcher::Native::DiagnosticSnapshot()> diagnosticSnapshot,
        std::shared_ptr<::DisplaySwitcher::Native::DisplayOperationTracker> displayDiagnostics,
        std::function<void()> closed)
    {
        if (initialized_) return;
        initialized_ = true;
        original_ = config; saved_ = std::move(saved); enumerateDdc_ = std::move(enumerateDdc);
        readDdc_ = std::move(readDdc);
        writeDdc_ = std::move(writeDdc); commitDdcCache_ = std::move(commitDdcCache);
        checkNetworkAccess_ = std::move(checkNetworkAccess);
        detectProfile_ = std::move(detectProfile); cancelProfileDetection_ = std::move(cancelProfileDetection);
        beginUsbLearning_ = std::move(beginUsbLearning); endUsbLearning_ = std::move(endUsbLearning);
        diagnosticSnapshotProvider_ = std::make_unique<::DisplaySwitcher::Native::CallbackDiagnosticSnapshotProvider>(
            std::move(diagnosticSnapshot));
        displayDiagnostics_ = std::move(displayDiagnostics);
        closed_ = std::move(closed);
        Title(L"常规");
        try { SystemBackdrop(MicaBackdrop()); } catch (...) {}
        auto content = BuildContent();
        Content(content);
        if (auto root = content.try_as<FrameworkElement>())
            root.ActualThemeChanged([this](auto const&, auto const&) { ApplyTitleBarTheme(); });
        LoadValues(config); ResizeAndCenter(); ApplyTitleBarTheme();
        Closed([this](auto const&, auto const&)
        {
            windowClosed_ = true; ++profileDetectionGeneration_; CancelProfileDetection();
            ddcCancellation_.Cancel(); EndUsbLearning(); if (closed_) closed_();
        });
        LoadUsbDevices();
        LoadDdcMonitors();
    }

    void SettingsWindow::ReloadConfiguration(::DisplaySwitcher::Native::AppConfig const& config)
    {
        if (windowClosed_) return;
        ddcCancellation_.Cancel();
        original_ = config;
        LoadValues(config);
        LoadDdcMonitors();
    }

    UIElement SettingsWindow::BuildContent()
    {
        layoutPresenter_.Reset();
        auto createDivider = []
        {
            auto divider = Border();
            divider.Height(1);
            divider.Background(ThemeBrush(L"CardStrokeColorDefaultBrush", Colors::Gray()));
            return divider;
        };
        operationStatus_ = TextBlock();
        operationStatus_.TextWrapping(TextWrapping::Wrap); operationStatus_.Visibility(Visibility::Collapsed);
        operationStatus_.HorizontalAlignment(HorizontalAlignment::Left);
        saveStatus_ = TextBlock();
        saveStatus_.TextWrapping(TextWrapping::Wrap); saveStatus_.Visibility(Visibility::Collapsed);
        saveStatus_.HorizontalAlignment(HorizontalAlignment::Left);
        saveStatus_.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        usbAutomation_ = ToggleSwitch();
        usbSwitchDisplaysOnArrival_ = ToggleSwitch();
        usbProfileSelector_ = ComboBox();
        usbProfileSelector_.HorizontalAlignment(HorizontalAlignment::Stretch);
        usbDevices_ = ComboBox(); Header(usbDevices_, L"当前 USB 设备"); usbDevices_.HorizontalAlignment(HorizontalAlignment::Stretch);
        usbDeviceStatus_ = TextBlock(); usbDeviceStatus_.Opacity(0.72); usbDeviceStatus_.TextWrapping(TextWrapping::Wrap);
        linkAllDisplays_ = ToggleSwitch();
        autoStart_ = ToggleSwitch();
        detailedDiagnostics_ = ToggleSwitch();
        usbAutomation_.Toggled([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb); });
        usbSwitchDisplaysOnArrival_.Toggled([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb); });
        linkAllDisplays_.Toggled([this](auto const&, auto const&)
        {
            if (SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None))
            {
                auto strong = get_strong();
                DispatcherQueue().TryEnqueue([strong] { strong->RebuildDisplayEditors(); });
            }
        });
        autoStart_.Toggled([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None); });
        detailedDiagnostics_.Toggled([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None); });
        usbDevices_.SelectionChanged([this](auto const&, auto const&)
        {
            if (loading_) return;
            auto index = usbDevices_.SelectedIndex();
            if (index < 0 || static_cast<size_t>(index) >= devices_.size()) return;
            auto learned = devices_[static_cast<size_t>(index)].LearningDevice();
            selectedUsbLocalReference_ = learned.localReference;
            selectedUsbName_ = learned.displayName;
            selectedUsbVendorId_ = devices_[index].vendorId;
            selectedUsbProductId_ = devices_[index].productId;
            SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb);
            RefreshUsbDeviceSelection();
        });
        usbProfileSelector_.SelectionChanged([this](auto const&, auto const&)
        {
            if (loading_) return;
            auto index = usbProfileSelector_.SelectedIndex();
            usbSelectedProfileId_ = index >= 0 && static_cast<size_t>(index) < workingProfiles_.size()
                ? workingProfiles_[static_cast<size_t>(index)].id : L"";
            SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb);
        });

        auto root = Grid();
        auto contentRow = RowDefinition(); contentRow.Height(GridLength{ 1, GridUnitType::Star });
        auto statusRow = RowDefinition(); statusRow.Height(GridLengthHelper::Auto());
        root.RowDefinitions().Append(contentRow); root.RowDefinitions().Append(statusRow);

        tabs_ = TabView(); tabs_.IsAddTabButtonVisible(false);
        tabs_.TabWidthMode(TabViewWidthMode::Equal);
        tabs_.HorizontalAlignment(HorizontalAlignment::Stretch); tabs_.VerticalAlignment(VerticalAlignment::Stretch);
        auto tabStripHeaderInset = Grid(); tabStripHeaderInset.Width(12);
        auto tabStripFooterInset = Grid(); tabStripFooterInset.Width(12);
        tabs_.TabStripHeader(tabStripHeaderInset); tabs_.TabStripFooter(tabStripFooterInset);

        auto commonTab = TabViewItem(); commonTab.IsClosable(false); commonTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        commonTab.Header(CreateTabHeader(L"\uE713", L"常规"));
        auto diagnosticsHint = TextBlock();
        diagnosticsHint.Text(L"仅排障时开启；切换开关会清空已有详细记录。");
        diagnosticsHint.TextWrapping(TextWrapping::Wrap); diagnosticsHint.Opacity(0.72);
        commonTab.Content(CreatePage({ CreateSection({}, {
            LabeledToggleRow(L"登录时启动", autoStart_),
            LabeledToggleRow(L"详细诊断记录", detailedDiagnostics_), diagnosticsHint }) }));

        auto learnCurrentUsb = Button(); learnCurrentUsb.Content(box_value(L"学习"));
        AutomationProperties::SetName(learnCurrentUsb, L"学习 USB 触发设备");
        learnCurrentUsb.HorizontalAlignment(HorizontalAlignment::Left);
        ApplyStandardButtonGeometry(learnCurrentUsb);
        learnCurrentUsb.Click([this](auto const&, auto const&)
        {
            StartUsbLearning(L"usb-switch");
        });
        auto usbTab = TabViewItem(); usbTab.IsClosable(false); usbTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        usbTab.Header(CreateTabHeader(L"\uE88E", L"USB 切换"));
        usbMappingsPanel_ = StackPanel(); usbMappingsPanel_.Spacing(8);
        auto usbHint = TextBlock(); usbHint.Text(L"只监听明确选择的一个本机设备。USB 离开立即切换显示器；接入只唤醒本机。联动协同默认关闭。");
        usbHint.TextWrapping(TextWrapping::Wrap); usbHint.Opacity(0.72);
        auto usbStatusLabel = TextBlock(); usbStatusLabel.Text(L"当前状态");
        usbStatusLabel.VerticalAlignment(VerticalAlignment::Center);
        auto usbStatusRow = Grid(); usbStatusRow.ColumnSpacing(16); auto usbStatusLabelColumn = ColumnDefinition();
        usbStatusLabelColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto usbStatusValueColumn = ColumnDefinition(); usbStatusValueColumn.Width(GridLengthHelper::Auto());
        usbStatusRow.ColumnDefinitions().Append(usbStatusLabelColumn); usbStatusRow.ColumnDefinitions().Append(usbStatusValueColumn);
        Grid::SetColumn(usbStatusLabel, 0); Grid::SetColumn(usbDeviceStatus_, 1);
        usbStatusRow.Children().Append(usbStatusLabel);
        AppendLayoutElement(usbStatusRow, usbDeviceStatus_,
            ::DisplaySwitcher::Native::SettingsLayoutElement::UsbDeviceStatus,
            ::DisplaySwitcher::Native::SettingsLayoutRegion::UsbCurrentStatusRow);
        auto usbLayout = ::DisplaySwitcher::Native::SettingsPageLayout(::DisplaySwitcher::Native::SettingsPage::Usb);
        auto usbAutoCard = StackPanel(); usbAutoCard.Spacing(16);
        usbAutoCard.Children().Append(LabeledToggleRow(L"自动切换", usbAutomation_));
        usbAutoCard.Children().Append(UsbDeviceRow(usbDevices_, learnCurrentUsb));
        usbAutoCard.Children().Append(createDivider());
        usbAutoCard.Children().Append(usbStatusRow);
        usbAutoCard.Children().Append(createDivider());
        usbAutoCard.Children().Append(usbMappingsPanel_);
        auto usbLinkCard = StackPanel(); usbLinkCard.Spacing(16);
        usbLinkCard.Children().Append(LabeledControlToggleRow(L"联动目标", usbProfileSelector_, usbSwitchDisplaysOnArrival_, L"联动协同"));
        usbTab.Content(CreatePage({
            CreateSection(usbLayout.cards.at(0), { usbAutoCard }),
            CreateSection(usbLayout.cards.at(1), { usbLinkCard }),
            usbHint }));

        auto peerTab = TabViewItem(); peerTab.IsClosable(false); peerTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        peerTab.Header(CreateTabHeader(L"\uE968", L"协同"));
        auto peerStatus = StackPanel(); peerStatus.Orientation(Orientation::Horizontal); peerStatus.Spacing(8);
        connectionDot_ = TextBlock(); connectionDot_.Text(L"●"); connectionDot_.FontSize(16);
        connectionStatus_ = TextBlock(); connectionStatus_.VerticalAlignment(VerticalAlignment::Center);
        peerStatus.Children().Append(connectionDot_); peerStatus.Children().Append(connectionStatus_);
        SetConnectionStatus(L"协同未启用", false);
        auto peerHint = TextBlock(); peerHint.Text(L"先检查网络权限，再检测连接。两项操作都不会执行 USB、唤醒或显示器操作。");
        peerHint.TextWrapping(TextWrapping::Wrap); peerHint.Opacity(0.72);
        auto checkNetwork = Button(); checkNetwork.Content(box_value(L"检查网络权限"));
        ApplyStandardButtonGeometry(checkNetwork);
        checkNetwork.Click([this](auto const&, auto const&)
        {
            if (!checkNetworkAccess_) { SetOperationFeedback(L"网络权限检查服务不可用。", true); return; }
            CaptureDisplayEditors(); CaptureProfileEditors();
            auto config = original_; config.displays = workingDisplays_; config.collaborationProfiles = workingProfiles_;
            SetOperationFeedback(L"正在检查本机 UDP 监听；若 Windows 弹出提示，请允许专用网络访问。");
            auto weak = get_weak();
            checkNetworkAccess_(config, [weak](bool ready, std::wstring const& message)
            {
                if (auto self = weak.get(); self && !self->windowClosed_)
                {
                    self->SetOperationFeedback(message,
                        ::DisplaySwitcher::Native::NetworkAccessFeedbackSeverity(ready));
                    if (!ready) self->SetConnectionStatus(L"网络权限未就绪", false);
                }
            });
        });
        detectProfileButton_ = Button(); detectProfileButton_.Content(box_value(L"检测连接"));
        ApplyStandardButtonGeometry(detectProfileButton_);
        detectProfileButton_.Click([this](auto const&, auto const&)
        {
            CaptureProfileEditors();
            if (!selectedProfileId_.empty()) DetectProfile(selectedProfileId_);
        });
        auto peerActions = StackPanel(); peerActions.Orientation(Orientation::Horizontal); peerActions.Spacing(8);
        peerActions.Children().Append(checkNetwork); peerActions.Children().Append(detectProfileButton_);
        auto addProfile = Button(); addProfile.Content(box_value(L"添加配置"));
        addProfile.VerticalAlignment(VerticalAlignment::Bottom);
        ApplyStandardButtonGeometry(addProfile);
        addProfile.Click([this](auto const&, auto const&)
        {
            CaptureProfileEditors();
            ::DisplaySwitcher::Native::CollaborationProfile profile;
            profile.id = ::DisplaySwitcher::Native::GenerateIdentifier();
            auto number = workingProfiles_.size() + 1;
            do { profile.name = L"配置 " + std::to_wstring(number++); }
            while (std::any_of(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
            { return _wcsicmp(item.name.c_str(), profile.name.c_str()) == 0; }));
            workingProfiles_.push_back(std::move(profile));
            selectedProfileId_ = workingProfiles_.back().id;
            RebuildProfileEditors();
            SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration);
        });
        profileSelector_ = ComboBox(); Header(profileSelector_, L"当前配置"); profileSelector_.HorizontalAlignment(HorizontalAlignment::Stretch);
        profileSelector_.SelectionChanged([this](auto const&, auto const&)
        {
            if (loading_) return;
            CancelProfileDetection();
            CaptureProfileEditors();
            auto index = profileSelector_.SelectedIndex();
            selectedProfileId_ = index >= 0 && static_cast<size_t>(index) < workingProfiles_.size()
                ? workingProfiles_[static_cast<size_t>(index)].id : L"";
            saveFeedback_.ClearTransientSuccess(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration);
            ResetSaveFeedbackTimer();
            ApplySaveFeedback(std::chrono::milliseconds{});
            RebuildProfileEditors();
        });
        profileEditorsPanel_ = StackPanel(); profileEditorsPanel_.Spacing(14);
        auto profileConfigSection = StackPanel(); profileConfigSection.Spacing(12);
        profileConfigSection.Children().Append(CreateSubheading(L"当前配置"));
        profileConfigSection.Children().Append(CreateTwoColumn(profileSelector_, addProfile));
        profileConfigSection.Children().Append(createDivider());
        profileConfigSection.Children().Append(CreateSubheading(L"配置详情"));
        auto peerLayout = ::DisplaySwitcher::Native::SettingsPageLayout(::DisplaySwitcher::Native::SettingsPage::Collaboration);
        peerTab.Content(CreatePage({
            CreateSection(peerLayout.cards.at(0), { CreateTwoColumn(peerStatus, peerActions), peerHint }),
            CreateSection(peerLayout.cards.at(1), { profileConfigSection, profileEditorsPanel_ }) }));

        auto displayTab = TabViewItem(); displayTab.IsClosable(false); displayTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        displayTab.Header(CreateTabHeader(L"\uE7F4", L"显示器"));
        auto displayHint = TextBlock(); displayHint.Text(L"新显示器的功能和托盘开关默认关闭。读取只访问亮度、对比度和音量。");
        displayHint.TextWrapping(TextWrapping::Wrap); displayHint.Opacity(0.72);
        auto refreshDdc = Button(); refreshDdc.Content(box_value(L"重新检测显示器"));
        ApplyStandardButtonGeometry(refreshDdc, 132);
        AutomationProperties::SetName(refreshDdc, L"重新检测显示器");
        refreshDdc.Click([this](auto const&, auto const&) { LoadDdcMonitors(); });
        displayEditorsPanel_ = StackPanel(); displayEditorsPanel_.Spacing(14);
        linkedDdcControlsPanel_ = StackPanel(); linkedDdcControlsPanel_.Spacing(14);
        displayTab.Content(CreatePage({ CreateSection({}, { displayHint,
            LabeledToggleRow(L"联动调节所有显示器", linkAllDisplays_),
            refreshDdc, linkedDdcControlsPanel_, displayEditorsPanel_ }) }));

        auto diagnosticTab = TabViewItem(); diagnosticTab.IsClosable(false);
        diagnosticTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        diagnosticTab.Header(CreateTabHeader(L"\uE9D9", L"诊断"));
        auto diagnosticHint = TextBlock();
        diagnosticHint.Text(L"预览只读取当前配置快照和内存状态，不会发起网络检测、USB 或显示器操作。复制内容与下方可见文本完全一致。");
        diagnosticHint.TextWrapping(TextWrapping::Wrap); diagnosticHint.Opacity(0.72);
        diagnosticPreview_ = TextBox();
        diagnosticPreview_.IsReadOnly(true); diagnosticPreview_.AcceptsReturn(true);
        diagnosticPreview_.TextWrapping(TextWrapping::NoWrap); diagnosticPreview_.MinHeight(390);
        diagnosticPreview_.HorizontalAlignment(HorizontalAlignment::Stretch);
        ScrollViewer::SetVerticalScrollBarVisibility(diagnosticPreview_, ScrollBarVisibility::Auto);
        ScrollViewer::SetHorizontalScrollBarVisibility(diagnosticPreview_, ScrollBarVisibility::Auto);
        AutomationProperties::SetName(diagnosticPreview_, L"诊断预览");
        auto refreshDiagnostic = Button(); refreshDiagnostic.Content(box_value(L"刷新预览"));
        ApplyStandardButtonGeometry(refreshDiagnostic);
        refreshDiagnostic.Click([this](auto const&, auto const&) { RefreshDiagnosticPreview(); });
        auto copyDiagnostic = Button(); copyDiagnostic.Content(box_value(L"复制诊断"));
        ApplyStandardButtonGeometry(copyDiagnostic);
        copyDiagnostic.Click([this](auto const&, auto const&) { CopyDiagnosticPreview(); });
        auto diagnosticActions = StackPanel(); diagnosticActions.Orientation(Orientation::Horizontal);
        diagnosticActions.Spacing(8); diagnosticActions.Children().Append(refreshDiagnostic);
        diagnosticActions.Children().Append(copyDiagnostic);
        diagnosticTab.Content(CreatePage({ CreateSection({}, { diagnosticHint, diagnosticActions, diagnosticPreview_ }) }));
        RefreshDiagnosticPreview();

        auto aboutTab = TabViewItem(); aboutTab.IsClosable(false); aboutTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        aboutTab.Header(CreateTabHeader(L"\uE946", L"关于"));
        auto info = ::DisplaySwitcher::Native::PublicAboutInfo();
        auto aboutIcon = Image(); aboutIcon.Width(72); aboutIcon.Height(72); aboutIcon.HorizontalAlignment(HorizontalAlignment::Center);
        aboutIcon.Source(Microsoft::UI::Xaml::Media::Imaging::BitmapImage(Windows::Foundation::Uri(L"ms-appx:///AppIcon-256.png")));
        auto aboutName = TextBlock(); aboutName.Text(info.applicationName); aboutName.FontSize(24);
        aboutName.FontWeight(Windows::UI::Text::FontWeights::SemiBold()); aboutName.HorizontalAlignment(HorizontalAlignment::Center);
        auto aboutDetails = TextBlock(); aboutDetails.Text(L"版本 " + info.publicVersion + L"\n" + info.architecture + L"\n协议 v2");
        aboutDetails.TextAlignment(TextAlignment::Center); aboutDetails.HorizontalAlignment(HorizontalAlignment::Center);
        auto project = HyperlinkButton(); project.Content(box_value(L"GitHub")); project.NavigateUri(Windows::Foundation::Uri(info.projectUrl));
        auto license = HyperlinkButton(); license.Content(box_value(L"MIT 许可证")); license.NavigateUri(Windows::Foundation::Uri(info.licenseUrl));
        auto notices = HyperlinkButton(); notices.Content(box_value(L"Windows 第三方说明")); notices.NavigateUri(Windows::Foundation::Uri(info.thirdPartyNoticesUrl));
        auto aboutLinks = StackPanel(); aboutLinks.Orientation(Orientation::Horizontal); aboutLinks.HorizontalAlignment(HorizontalAlignment::Center);
        aboutLinks.Children().Append(project); aboutLinks.Children().Append(license); aboutLinks.Children().Append(notices);
        auto buildNotice = TextBlock(); buildNotice.Text(info.buildNotice); buildNotice.TextWrapping(TextWrapping::Wrap);
        buildNotice.TextAlignment(TextAlignment::Center); buildNotice.Opacity(0.72);
        aboutTab.Content(CreatePage({ CreateSection({}, { aboutIcon, aboutName, aboutDetails, aboutLinks, buildNotice }) }));

        tabs_.TabItems().Append(commonTab); tabs_.TabItems().Append(usbTab);
        tabs_.TabItems().Append(peerTab); tabs_.TabItems().Append(displayTab);
        tabs_.TabItems().Append(diagnosticTab); tabs_.TabItems().Append(aboutTab);
        tabs_.SelectedIndex(0);
        tabs_.SelectionChanged([this](auto const&, auto const&)
        {
            static constexpr wchar_t const* titles[]{ L"常规", L"USB 切换", L"协同", L"显示器", L"诊断", L"关于" };
            auto index = tabs_.SelectedIndex();
            if (index >= 0 && index < 6) Title(titles[index]);
            SetOperationFeedback({});
            saveFeedback_.ClearTransientSuccesses();
            ResetSaveFeedbackTimer();
            ApplySaveFeedback(std::chrono::milliseconds{});
        });
        Grid::SetRow(tabs_, 0); root.Children().Append(tabs_);

        auto statusPanel = StackPanel(); statusPanel.Spacing(4); statusPanel.HorizontalAlignment(HorizontalAlignment::Left);
        statusPanel.Children().Append(operationStatus_);
        AppendLayoutElement(statusPanel, saveStatus_,
            ::DisplaySwitcher::Native::SettingsLayoutElement::ScopedSaveFeedback,
            ::DisplaySwitcher::Native::SettingsLayoutRegion::FixedWindowFooter);
        statusPanelBorder_ = Border(); statusPanelBorder_.Padding(Thickness{ 24, 8, 24, 12 });
        statusPanelBorder_.Child(statusPanel);
        Grid::SetRow(statusPanelBorder_, 1); root.Children().Append(statusPanelBorder_);
        saveFeedbackTimer_ = DispatcherQueue().CreateTimer();
        saveFeedbackTimer_.IsRepeating(true);
        saveFeedbackTimer_.Interval(std::chrono::milliseconds(150));
        auto statusWeak = get_weak();
        saveFeedbackTimer_.Tick([statusWeak](auto const&, auto const&) { if (auto self = statusWeak.get()) self->ApplySaveFeedback(std::chrono::milliseconds{}); });

        return root;
    }

    Border SettingsWindow::CreateSection(::DisplaySwitcher::Native::SettingsCardContract const& contract,
        std::vector<UIElement> const& children)
    {
        auto panel = StackPanel(); panel.Spacing(16);
        for (auto const& child : children) panel.Children().Append(child);
        auto card = CreateCard(panel);
        if (!contract.title.empty()) AutomationProperties::SetName(card, contract.title);
        return card;
    }

    Border SettingsWindow::CreateCard(UIElement const& child)
    {
        auto border = Border(); border.Child(child); border.Padding(Thickness{ 20, 20, 20, 20 });
        border.CornerRadius(CornerRadius{ 8, 8, 8, 8 });
        border.BorderThickness(Thickness{ 1, 1, 1, 1 });
        border.Background(ThemeBrush(L"CardBackgroundFillColorDefaultBrush", Windows::UI::Colors::White()));
        border.BorderBrush(ThemeBrush(L"CardStrokeColorDefaultBrush", Windows::UI::Colors::Transparent()));
        return border;
    }

    ScrollViewer SettingsWindow::CreatePage(std::vector<UIElement> const& children)
    {
        auto scroll = ScrollViewer(); scroll.VerticalScrollBarVisibility(ScrollBarVisibility::Auto);
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled); scroll.HorizontalScrollMode(ScrollMode::Disabled);
        scroll.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        auto content = StackPanel(); content.Spacing(16); content.Padding(Thickness{ 24, 20, 24, 20 });
        content.HorizontalAlignment(HorizontalAlignment::Stretch);
        for (auto const& child : children) content.Children().Append(child);
        scroll.Content(content); return scroll;
    }

    StackPanel SettingsWindow::CreateTabHeader(wchar_t const* glyph, wchar_t const* text)
    {
        auto header = StackPanel(); header.Orientation(Orientation::Vertical); header.Width(112); header.Spacing(3);
        header.HorizontalAlignment(HorizontalAlignment::Center);
        auto icon = FontIcon(); icon.FontFamily(FontFamily(L"Segoe Fluent Icons")); icon.Glyph(glyph); icon.FontSize(18);
        icon.HorizontalAlignment(HorizontalAlignment::Center);
        auto label = TextBlock(); label.Text(text); label.FontSize(12); label.HorizontalAlignment(HorizontalAlignment::Center);
        header.Children().Append(icon); header.Children().Append(label); return header;
    }

    Grid SettingsWindow::CreateTwoColumn(FrameworkElement const& left, FrameworkElement const& right, double rightWidth)
    {
        auto grid = Grid(); grid.ColumnSpacing(16); auto leftColumn = ColumnDefinition(); leftColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto rightColumn = ColumnDefinition();
        if (rightWidth < 0) rightColumn.Width(GridLengthHelper::Auto());
        else if (rightWidth == 0) rightColumn.Width(GridLength{ 1, GridUnitType::Star });
        else rightColumn.Width(GridLength{ rightWidth });
        grid.ColumnDefinitions().Append(leftColumn); grid.ColumnDefinitions().Append(rightColumn);
        Grid::SetColumn(left, 0); Grid::SetColumn(right, 1); grid.Children().Append(left); grid.Children().Append(right); return grid;
    }

    TextBlock SettingsWindow::CreateSubheading(std::wstring const& text)
    {
        auto heading = TextBlock(); heading.Text(text); heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        heading.Margin(Thickness{ 0, 2, 0, -6 }); return heading;
    }

    void SettingsWindow::ResizeAndCenter()
    {
        HWND window{}; check_hresult(this->get_strong().as<::IWindowNative>()->get_WindowHandle(&window)); auto id = Microsoft::UI::GetWindowIdFromWindow(window);
        if (auto icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON)))
        {
            SendMessageW(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
            SendMessageW(window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
        }
        appWindow_ = AppWindow::GetFromWindowId(id);
        if (auto presenter = appWindow_.Presenter().try_as<OverlappedPresenter>()) { presenter.IsMaximizable(false); presenter.IsMinimizable(false); }
        auto area = DisplayArea::GetFromWindowId(id, DisplayAreaFallback::Primary).WorkArea();
        auto dpi = GetDpiForWindow(window); double scale = dpi ? dpi / 96.0 : 1.0;
        int width = (std::min)(static_cast<int>(std::lround(720 * scale)), area.Width);
        int height = (std::min)(static_cast<int>(std::lround(690 * scale)), area.Height);
        int x = area.X + (std::max)(0, (area.Width - width) / 2); int y = area.Y + (std::max)(0, (area.Height - height) / 2);
        appWindow_.MoveAndResize(Windows::Graphics::RectInt32{ x, y, width, height });
    }

    void SettingsWindow::ApplyTitleBarTheme()
    {
        HWND window{};
        if (FAILED(this->get_strong().as<::IWindowNative>()->get_WindowHandle(&window)) || !window) return;
        auto root = Content().try_as<FrameworkElement>();
        BOOL dark = root && root.ActualTheme() == ElementTheme::Dark;
        constexpr DWORD immersiveDarkMode = 20;
        if (FAILED(DwmSetWindowAttribute(window, immersiveDarkMode, &dark, sizeof(dark))))
        {
            constexpr DWORD immersiveDarkModeBefore20H1 = 19;
            DwmSetWindowAttribute(window, immersiveDarkModeBefore20H1, &dark, sizeof(dark));
        }
    }

    void SettingsWindow::ShowWindow()
    {
        appWindow_.Show();
        Activate();
        HWND window{};
        if (SUCCEEDED(this->get_strong().as<::IWindowNative>()->get_WindowHandle(&window)) && window)
        {
            if (IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
            SetForegroundWindow(window);
        }
    }
    void SettingsWindow::CloseForExit() { ddcCancellation_.Cancel(); Close(); }

    void SettingsWindow::SetConnectionStatus(std::wstring const& status, bool connected)
    {
        if (!connectionStatus_ || !connectionDot_) return;
        connectionStatus_.Text(status);
        connectionDot_.Foreground(ThemeBrush(
            connected ? L"SystemFillColorSuccessBrush" : L"TextFillColorSecondaryBrush",
            connected ? Colors::Green() : Colors::Gray()));
    }

    void SettingsWindow::LoadValues(::DisplaySwitcher::Native::AppConfig const& config)
    {
        saveFeedback_.ClearTransientSuccesses();
        ResetSaveFeedbackTimer();
        loading_ = true;
        usbAutomation_.IsOn(config.usbSwitch.enabled);
        usbSwitchDisplaysOnArrival_.IsOn(config.usbSwitch.collaborationWakeEnabled);
        selectedUsbLocalReference_ = config.usbSwitch.deviceLocalReference;
        selectedUsbName_ = config.usbSwitch.deviceName;
        selectedUsbVendorId_ = config.usbSwitch.vendorId;
        selectedUsbProductId_ = config.usbSwitch.productId;
        usbSelectedProfileId_ = config.usbSwitch.collaborationProfileId;
        workingDisplays_ = config.displays;
        workingProfiles_ = config.collaborationProfiles;
        linkAllDisplays_.IsOn(config.linkAllDisplays);
        mappingProjection_.Refresh(workingDisplays_,
            ::DisplaySwitcher::Native::DisplayTopologyTrust::LocalPhysicalAuthoritative);
        RebuildUsbMappingEditors();
        for (auto const& editor : usbMappingEditors_)
        {
            auto value = config.UsbInputForDisplay(editor.displayId);
            editor.targetInput.Text(::DisplaySwitcher::Native::FormatInputSourceText(value));
        }
        RebuildDisplayEditors();
        RebuildProfileEditors();
        autoStart_.IsOn(config.startWithWindows);
        detailedDiagnostics_.IsOn(config.detailedDiagnosticRecording);
        loading_ = false;
    }

    void SettingsWindow::LoadUsbDevices()
    {
        try
        {
            auto wasLoading = loading_; loading_ = true;
            devices_ = ::DisplaySwitcher::Native::UsbWatcher::EnumerateDevices(); usbDevices_.Items().Clear();
            for (size_t index = 0; index < devices_.size(); ++index)
            {
                auto label = devices_[index].DisplayName();
                auto sameNameCount = std::count_if(devices_.begin(), devices_.end(), [&](auto const& device)
                    { return _wcsicmp(device.name.c_str(), devices_[index].name.c_str()) == 0; });
                if (sameNameCount > 1)
                {
                    auto ordinal = 1 + std::count_if(devices_.begin(), devices_.begin() + static_cast<std::ptrdiff_t>(index), [&](auto const& device)
                        { return _wcsicmp(device.name.c_str(), devices_[index].name.c_str()) == 0; });
                    label += L"（" + std::to_wstring(ordinal) + L"）";
                }
                auto item = ComboBoxItem(); item.Content(box_value(label)); usbDevices_.Items().Append(item);
            }
            loading_ = wasLoading;
            RefreshUsbDeviceSelection();
            SetOperationFeedback({});
        }
        catch (hresult_error const& error) { loading_ = false; SetOperationFeedback(L"读取 USB 失败：" + std::wstring(error.message()), true); }
        catch (...) { loading_ = false; SetOperationFeedback(L"读取 USB 失败。", true); }
    }

    void SettingsWindow::StartUsbLearning(std::wstring const& profileId)
    {
        EndUsbLearning();
        CaptureProfileEditors();
        ddcCancellation_.Cancel();
        if (beginUsbLearning_) beginUsbLearning_();
        usbLearningRuntimePaused_ = true;
        try
        {
            auto baseline = ::DisplaySwitcher::Native::UsbWatcher::EnumerateDevices();
            usbLearningGeneration_ = usbLearning_.Start(profileId, LearningDevices(baseline), SteadyMilliseconds());
            usbLearningTimer_ = DispatcherQueue().CreateTimer();
            usbLearningTimer_.Interval(std::chrono::milliseconds(250));
            usbLearningTimer_.IsRepeating(true);
            usbLearningTimer_.Tick([this](auto const&, auto const&) { PollUsbLearning(); });
            usbLearningTimer_.Start();
            SetOperationFeedback(L"正在学习本机 USB 设备：请在 30 秒内接入目标设备。学习完成前网络和硬件操作保持暂停。");
        }
        catch (...)
        {
            EndUsbLearning();
            SetOperationFeedback(L"无法开始 USB 学习；原绑定保持不变。", true);
        }
    }

    void SettingsWindow::PollUsbLearning()
    {
        if (!usbLearning_.Active() || usbLearningDialogOpen_) return;
        auto generation = usbLearningGeneration_;
        auto profileExists = usbLearning_.ProfileId() == L"usb-switch";
        try
        {
            auto devices = ::DisplaySwitcher::Native::UsbWatcher::EnumerateDevices();
            usbLearning_.Observe(generation, LearningDevices(devices), SteadyMilliseconds(), profileExists);
        }
        catch (...)
        {
            EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion::Failure,
                L"读取 USB 设备失败；原绑定保持不变。");
            return;
        }
        if (!usbLearning_.Active())
        {
            EndUsbLearning(profileExists ? ::DisplaySwitcher::Native::UsbLearningCompletion::TimedOut :
                ::DisplaySwitcher::Native::UsbLearningCompletion::Invalidated,
                profileExists ? L"USB 学习已在 30 秒后超时；原绑定保持不变。" :
                    L"目标配置已删除；原 USB 绑定保持不变。");
            return;
        }
        if (!usbLearning_.Candidates().empty()) ShowUsbLearningCandidates();
    }

    void SettingsWindow::ShowUsbLearningCandidates()
    {
        if (!usbLearning_.Active() || usbLearningDialogOpen_) return;
        usbLearningDialogOpen_ = true;
        if (usbLearningTimer_) usbLearningTimer_.Stop();
        auto generation = usbLearningGeneration_;
        auto profileId = usbLearning_.ProfileId();
        auto candidates = usbLearning_.Candidates();

        auto picker = ComboBox();
        picker.Header(box_value(candidates.size() > 1 ? L"检测到多个新增设备，请明确选择" : L"检测到新增设备，请确认"));
        picker.HorizontalAlignment(HorizontalAlignment::Stretch);
        for (auto const& candidate : candidates) picker.Items().Append(box_value(candidate.displayName));
        if (candidates.size() == 1) picker.SelectedIndex(0);

        auto note = TextBlock();
        note.Text(L"确认前不会修改原绑定，也不会恢复 UDP、自动 USB 交接、DDC 或唤醒。");
        note.TextWrapping(TextWrapping::Wrap); note.Opacity(0.72);
        auto content = StackPanel(); content.Spacing(12); content.Children().Append(picker); content.Children().Append(note);
        auto dialog = ContentDialog(); dialog.Title(box_value(L"选择 USB 学习候选")); dialog.Content(content);
        dialog.PrimaryButtonText(L"绑定所选设备"); dialog.CloseButtonText(L"取消");
        dialog.DefaultButton(ContentDialogButton::Close); dialog.IsPrimaryButtonEnabled(picker.SelectedIndex() >= 0);
        picker.SelectionChanged([dialog](auto const& sender, auto const&)
            { dialog.IsPrimaryButtonEnabled(sender.template as<ComboBox>().SelectedIndex() >= 0); });
        dialog.XamlRoot(Content().XamlRoot());
        dialog.ShowAsync().Completed([this, generation, profileId, candidates, picker, dialog](auto const& operation, auto const& status)
        {
            usbLearningDialogOpen_ = false;
            if (status != Windows::Foundation::AsyncStatus::Completed || operation.GetResults() != ContentDialogResult::Primary)
            {
                usbLearning_.Cancel(generation);
                EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion::Cancelled,
                    L"USB 学习已取消；原绑定保持不变。");
                return;
            }
            auto index = picker.SelectedIndex();
            if (index < 0 || static_cast<size_t>(index) >= candidates.size() || profileId != L"usb-switch")
            {
                usbLearning_.Cancel(generation);
                EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion::Invalidated,
                    L"目标配置或候选已失效；原 USB 绑定保持不变。");
                return;
            }
            auto selected = usbLearning_.Confirm(generation, candidates[static_cast<size_t>(index)].localReference,
                SteadyMilliseconds(), true);
            if (!selected)
            {
                EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion::TimedOut,
                    L"USB 学习已超时或结果已失效；原绑定保持不变。");
                return;
            }
            selectedUsbLocalReference_ = selected->localReference;
            selectedUsbName_ = selected->displayName;
            selectedUsbVendorId_ = selected->vendorId;
            selectedUsbProductId_ = selected->productId;
            usbDevices_.SelectedIndex(-1);
            auto saved = SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb);
            EndUsbLearning(saved ? ::DisplaySwitcher::Native::UsbLearningCompletion::Success :
                ::DisplaySwitcher::Native::UsbLearningCompletion::Failure,
                saved ? L"已选择 USB 设备并保存。" :
                    L"USB 绑定未能保存；原配置已保留，自动操作保持停用。");
        });
    }

    void SettingsWindow::EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion completion,
        std::wstring const& message)
    {
        if (usbLearningTimer_)
        {
            usbLearningTimer_.Stop();
            usbLearningTimer_ = nullptr;
        }
        if (usbLearning_.Active()) usbLearning_.Cancel(usbLearningGeneration_);
        if (usbLearningRuntimePaused_)
        {
            usbLearningRuntimePaused_ = false;
            if (endUsbLearning_) endUsbLearning_();
        }
        if (!message.empty())
        {
            SetOperationFeedback(message, ::DisplaySwitcher::Native::UsbLearningFeedbackSeverity(completion));
        }
    }

    void SettingsWindow::LoadDdcMonitors()
    {
        CaptureDisplayEditors();
        try
        {
            auto enumeration = enumerateDdc_ ? enumerateDdc_()
                : ::DisplaySwitcher::Native::DdcEnumerationResult{ false,
                    ::DisplaySwitcher::Native::DdcErrorKind::BackendUnavailable,
                    L"Windows 原生 DDC 后端不可用", {}, false };
            if (!enumeration.success)
            {
                ddcTopologyTrust_ = ::DisplaySwitcher::Native::DisplayTopologyTrust::IncompleteOrUnavailable;
                RebuildDisplayEditors();
                SetOperationFeedback(enumeration.message.empty() ? L"读取 Windows 原生 DDC/CI 显示器失败。" : enumeration.message, true);
                return;
            }
            if (!enumeration.IsTrustedNonEmptySnapshot())
            {
                ddcTopologyTrust_ = enumeration.topologyTrust;
                RebuildDisplayEditors();
                SetOperationFeedback(enumeration.topologyTrust == ::DisplaySwitcher::Native::DisplayTopologyTrust::RemoteSessionLimited
                    ? L"远程桌面会话中，已保留本地物理显示器配置，返回本地后重新检测。"
                    : enumeration.monitors.empty()
                    ? L"暂未检测到显示器；已保留现有设置和映射，显示器可能处于休眠或短暂断开状态。"
                    : L"显示器枚举结果不完整；已保留现有设置和映射。", true);
                return;
            }
            ddcMonitors_ = std::move(enumeration.monitors);
            ddcTopologyTrust_ = enumeration.topologyTrust;
            auto reconciled = ::DisplaySwitcher::Native::ReconcileDisplayConfigurations(
                workingDisplays_, ddcMonitors_, enumeration.topologyTrust);
            workingDisplays_ = std::move(reconciled.displays);
            mappingProjection_.Refresh(workingDisplays_, enumeration.topologyTrust);
            RebuildDisplayEditors();
            RebuildUsbMappingEditors();
            RebuildProfileEditors();
            if (reconciled.changed) SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None);
            if (ddcMonitors_.empty())
                SetOperationFeedback(L"没有检测到支持 Windows 物理显示器接口的显示器。", true);
            else if (!enumeration.message.empty()) SetOperationFeedback(enumeration.message, true);
            else SetOperationFeedback({});
        }
        catch (...) { SetOperationFeedback(L"读取原生 DDC/CI 显示器失败。", true); }
    }

    void SettingsWindow::CaptureDisplayEditors()
    {
        if (displayEditors_.size() != workingDisplays_.size()) return;
        for (size_t index = 0; index < displayEditors_.size(); ++index)
        {
            auto& display = workingDisplays_[index];
            auto const& controls = displayEditors_[index];
            display.readEnabled = true;
            display.brightnessEnabled = controls.brightnessEnabled.IsOn();
            display.brightnessShowInTray = controls.brightnessShowInTray.IsOn() && display.brightnessEnabled;
            display.contrastEnabled = controls.contrastEnabled.IsOn();
            display.contrastShowInTray = controls.contrastShowInTray.IsOn() && display.contrastEnabled;
            display.volumeEnabled = controls.volumeEnabled.IsOn();
            display.volumeShowInTray = controls.volumeShowInTray.IsOn() && display.volumeEnabled;
        }
    }

    void SettingsWindow::RebuildUsbMappingEditors()
    {
        if (!usbMappingsPanel_) return;
        std::map<std::wstring, std::wstring> previous;
        for (auto const& editor : usbMappingEditors_) previous[editor.displayId] = editor.targetInput.Text().c_str();
        usbMappingsPanel_.Children().Clear(); usbMappingEditors_.clear();
        auto grid = CreatePeerInputMappingGrid([&](auto const& display)
        {
            auto input = TextBox();
            input.HorizontalAlignment(HorizontalAlignment::Stretch);
            input.MaxLength(5);
            auto old = previous.find(display.displayId);
            if (old != previous.end()) input.Text(old->second);
            else input.Text(::DisplaySwitcher::Native::FormatInputSourceText(original_.UsbInputForDisplay(display.displayId)));
            input.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb); });
            input.KeyDown([this](auto const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args)
            { if (args.Key() == Windows::System::VirtualKey::Enter) SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Usb); });
            usbMappingEditors_.push_back({ display.displayId, input });
            return input;
        });
        usbMappingsPanel_.Children().Append(grid);
    }

    Grid SettingsWindow::CreatePeerInputMappingGrid(
        std::function<Control(::DisplaySwitcher::Native::DisplayMappingRow const&)> const& createInput)
    {
        auto const layout = ::DisplaySwitcher::Native::PeerInputMappingLayoutModel{};
        auto const& rows = mappingProjection_.Rows();
        auto grid = Grid(); grid.ColumnSpacing(layout.columnSpacing); grid.RowSpacing(layout.rowSpacing);
        auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ layout.labelColumnWidth });
        auto nameColumn = ColumnDefinition(); nameColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto inputColumn = ColumnDefinition(); inputColumn.Width(GridLength{ layout.inputColumnWidth });
        grid.ColumnDefinitions().Append(labelColumn); grid.ColumnDefinitions().Append(nameColumn);
        grid.ColumnDefinitions().Append(inputColumn);
        for (size_t index = 0; index < layout.LabelRowSpan(rows.size()); ++index)
        {
            auto row = RowDefinition(); row.Height(GridLengthHelper::Auto()); grid.RowDefinitions().Append(row);
        }

        auto label = TextBlock(); label.Text(L"对端输入源");
        label.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(label, 0); Grid::SetRow(label, 0);
        Grid::SetRowSpan(label, static_cast<int>(layout.LabelRowSpan(rows.size())));
        grid.Children().Append(label);
        if (rows.empty())
        {
            auto empty = TextBlock(); empty.Text(L"当前没有已解析且可唯一绑定的物理显示器。");
            empty.Opacity(0.72); empty.TextWrapping(TextWrapping::Wrap);
            Grid::SetColumn(empty, 1); Grid::SetColumnSpan(empty, 2); grid.Children().Append(empty);
            return grid;
        }
        for (size_t index = 0; index < rows.size(); ++index)
        {
            auto name = TextBlock(); name.Text(rows[index].displayName);
            name.VerticalAlignment(VerticalAlignment::Center);
            name.TextTrimming(TextTrimming::CharacterEllipsis);
            auto input = createInput(rows[index]);
            input.HorizontalAlignment(HorizontalAlignment::Stretch);
            AutomationProperties::SetName(input, rows[index].displayName + L" 输入源");
            Grid::SetColumn(name, 1); Grid::SetRow(name, static_cast<int>(index));
            Grid::SetColumn(input, 2); Grid::SetRow(input, static_cast<int>(index));
            grid.Children().Append(name); grid.Children().Append(input);
        }
        return grid;
    }

    void SettingsWindow::RebuildDisplayEditors()
    {
        if (!displayEditorsPanel_) return;
        displayEditorsPanel_.Children().Clear();
        displayEditors_.clear();
        if (linkedDdcControlsPanel_) linkedDdcControlsPanel_.Children().Clear();

        auto linked = linkAllDisplays_ && linkAllDisplays_.IsOn();
        if (linked && linkedDdcControlsPanel_)
        {
            auto projectionConfig = original_;
            projectionConfig.linkAllDisplays = true;
            projectionConfig.displays = workingDisplays_;
            auto projections = ::DisplaySwitcher::Native::BuildDdcControlProjection(
                projectionConfig, ddcTopologyTrust_, false);
            if (!projections.empty())
            {
                auto shared = StackPanel(); shared.Spacing(10);
                auto heading = TextBlock(); heading.Text(L"联动调节");
                heading.FontSize(18); heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
                shared.Children().Append(heading);
                for (auto const& projection : projections)
                {
                    auto row = Grid(); row.ColumnSpacing(12);
                    auto labelColumn = ColumnDefinition(); labelColumn.Width(GridLength{ 96 });
                    auto sliderColumn = ColumnDefinition(); sliderColumn.Width(GridLength{ 1, GridUnitType::Star });
                    auto valueColumn = ColumnDefinition(); valueColumn.Width(GridLength{ 56 });
                    row.ColumnDefinitions().Append(labelColumn); row.ColumnDefinitions().Append(sliderColumn);
                    row.ColumnDefinitions().Append(valueColumn);
                    auto label = TextBlock(); label.Text(projection.label); label.VerticalAlignment(VerticalAlignment::Center);
                    auto slider = Slider(); slider.Minimum(0); slider.Maximum(projection.maximum);
                    slider.Value(projection.value); slider.StepFrequency(1); slider.SmallChange(1); slider.LargeChange(10);
                    slider.HorizontalAlignment(HorizontalAlignment::Stretch);
                    slider.IsEnabled(!projection.targetDisplayIds.empty());
                    auto sliderHost = Grid();
                    auto neutralTrack = Border(); neutralTrack.Height(4); neutralTrack.CornerRadius(CornerRadius{ 2, 2, 2, 2 });
                    neutralTrack.VerticalAlignment(VerticalAlignment::Center);
                    neutralTrack.Background(ThemeBrush(L"ControlStrongStrokeColorDefaultBrush", Colors::Gray()));
                    neutralTrack.Visibility(projection.valueState == ::DisplaySwitcher::Native::DdcProjectedValueState::Value
                        ? Visibility::Collapsed : Visibility::Visible);
                    slider.Opacity(projection.valueState == ::DisplaySwitcher::Native::DdcProjectedValueState::Value ? 1.0 : 0.0);
                    sliderHost.Children().Append(neutralTrack); sliderHost.Children().Append(slider);
                    auto value = TextBlock(); value.VerticalAlignment(VerticalAlignment::Center);
                    value.HorizontalAlignment(HorizontalAlignment::Right);
                    value.Text(projection.valueState == ::DisplaySwitcher::Native::DdcProjectedValueState::Mixed
                        ? L"混合" : projection.valueState == ::DisplaySwitcher::Native::DdcProjectedValueState::Unavailable
                        ? L"—" : std::to_wstring(projection.value));
                    auto accessibleValue = value.Text();
                    AutomationProperties::SetName(slider, L"联动" + projection.label + L"，当前" + std::wstring(accessibleValue.c_str()));
                    slider.ValueChanged([value, neutralTrack, labelText = projection.label](auto const& sender, auto const&)
                    {
                        auto currentSlider = sender.template as<Slider>();
                        auto current = static_cast<int>(std::lround(currentSlider.Value()));
                        currentSlider.Opacity(1); neutralTrack.Visibility(Visibility::Collapsed);
                        value.Text(std::to_wstring(current));
                        AutomationProperties::SetName(currentSlider,
                            L"联动" + labelText + L"，当前" + std::to_wstring(current));
                    });
                    slider.PointerCaptureLost(Microsoft::UI::Xaml::Input::PointerEventHandler(
                        [this, id = projection.displayId, code = projection.code, slider](IInspectable const&,
                            Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const&)
                        {
                            if (!id.empty()) WriteDdc(id, code, static_cast<int>(std::lround(slider.Value())));
                        }));
                    slider.KeyUp(Microsoft::UI::Xaml::Input::KeyEventHandler(
                        [this, id = projection.displayId, code = projection.code, slider](IInspectable const&,
                            Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args)
                        {
                            if (!id.empty() && args.Key() == Windows::System::VirtualKey::Enter)
                                WriteDdc(id, code, static_cast<int>(std::lround(slider.Value())));
                        }));
                    Grid::SetColumn(sliderHost, 1); Grid::SetColumn(value, 2);
                    row.Children().Append(label); row.Children().Append(sliderHost); row.Children().Append(value);
                    shared.Children().Append(row);
                }
                linkedDdcControlsPanel_.Children().Append(CreateCard(shared));
            }
        }

        auto diagnosticStates = displayDiagnostics_ ? displayDiagnostics_->Snapshot(workingDisplays_)
            : std::vector<::DisplaySwitcher::Native::DiagnosticDisplaySummary>{};
        for (size_t index = 0; index < workingDisplays_.size(); ++index)
        {
            auto const display = workingDisplays_[index];
            DisplayEditorControls controls;
            controls.id = display.id;
            controls.brightnessEnabled = ToggleSwitch();
            controls.brightnessEnabled.IsOn(display.brightnessEnabled);
            controls.brightnessShowInTray = ToggleSwitch(); controls.brightnessShowInTray.IsOn(display.brightnessShowInTray);
            controls.contrastEnabled = ToggleSwitch();
            controls.contrastEnabled.IsOn(display.contrastEnabled);
            controls.contrastShowInTray = ToggleSwitch(); controls.contrastShowInTray.IsOn(display.contrastShowInTray);
            controls.volumeEnabled = ToggleSwitch();
            controls.volumeEnabled.IsOn(display.volumeEnabled);
            controls.volumeShowInTray = ToggleSwitch(); controls.volumeShowInTray.IsOn(display.volumeShowInTray);
            auto configureSlider = [](Slider const& slider, std::optional<int> value, std::optional<int> maximum)
            {
                auto current = value.value_or(0);
                slider.Minimum(0); slider.Maximum(::DisplaySwitcher::Native::DdcControlService::EffectiveMaximum(
                    current, maximum.value_or(100)));
                slider.Value(current); slider.StepFrequency(1); slider.SmallChange(1); slider.LargeChange(10);
            };
            controls.brightness = Slider(); configureSlider(controls.brightness, display.brightnessValue, display.brightnessMax);
            controls.contrast = Slider(); configureSlider(controls.contrast, display.contrastValue, display.contrastMax);
            controls.volume = Slider(); configureSlider(controls.volume, display.volumeValue, display.volumeMax);
            controls.status = TextBlock();
            if (index < diagnosticStates.size() &&
                diagnosticStates[index].lastState != ::DisplaySwitcher::Native::DiagnosticOperationState::Idle)
                controls.status.Text(::DisplaySwitcher::Native::DescribeDiagnosticOperation(diagnosticStates[index]));
            else controls.status.Text(display.bindingMessage.empty() ? L"状态尚未读取" : display.bindingMessage);
            controls.status.Opacity(0.72);
            controls.status.TextWrapping(TextWrapping::Wrap);

            auto read = Button(); read.Content(box_value(L"读取 DDC 参数"));
            read.IsEnabled(::DisplaySwitcher::Native::IsDisplayDdcResolved(display));
            AutomationProperties::SetName(read, L"读取 " + display.name + L" 的 DDC 参数");
            read.Click([this, id = display.id](auto const&, auto const&) { ReadDdc(id); });
            auto remove = Button(); remove.Content(box_value(L"删除"));
            remove.Visibility(::DisplaySwitcher::Native::CanDeleteOfflineDisplay(display, ddcTopologyTrust_)
                ? Visibility::Visible : Visibility::Collapsed);
            AutomationProperties::SetName(remove, L"删除离线显示器 " + display.name);
            remove.Click([this, id = display.id](auto const&, auto const&) { RemoveOfflineDisplay(id); });
            auto controlsGrid = Grid();
            controlsGrid.ColumnSpacing(12); controlsGrid.RowSpacing(10);
            controlsGrid.HorizontalAlignment(HorizontalAlignment::Stretch);
            for (auto width : { 96.0, 132.0, 132.0 })
            {
                auto column = ColumnDefinition(); column.Width(GridLength{ width });
                controlsGrid.ColumnDefinitions().Append(column);
            }
            if (!linked)
            {
                auto sliderColumn = ColumnDefinition();
                sliderColumn.Width(GridLength{ 1, GridUnitType::Star });
                controlsGrid.ColumnDefinitions().Append(sliderColumn);
                auto valueColumn = ColumnDefinition(); valueColumn.Width(GridLength{ 44 });
                controlsGrid.ColumnDefinitions().Append(valueColumn);
            }
            for (int rowIndex = 0; rowIndex < 4; ++rowIndex)
            {
                auto row = RowDefinition(); row.Height(GridLengthHelper::Auto());
                controlsGrid.RowDefinitions().Append(row);
            }

            auto functionHeader = TextBlock(); functionHeader.Text(L"功能"); functionHeader.Opacity(0.66);
            functionHeader.HorizontalAlignment(HorizontalAlignment::Left);
            auto trayHeader = TextBlock(); trayHeader.Text(L"托盘"); trayHeader.Opacity(0.66);
            trayHeader.HorizontalAlignment(HorizontalAlignment::Left);
            Grid::SetColumn(functionHeader, 1); Grid::SetColumn(trayHeader, 2);
            controlsGrid.Children().Append(functionHeader); controlsGrid.Children().Append(trayHeader);

            auto controlRow = [&](wchar_t const* name, ::DisplaySwitcher::Native::DdcVcpCode code, Slider const& slider,
                ToggleSwitch const& enabled, ToggleSwitch const& showInTray, int rowIndex)
            {
                auto label = TextBlock(); label.Text(name); label.VerticalAlignment(VerticalAlignment::Center);
                auto value = TextBlock(); value.Text(std::to_wstring(static_cast<int>(std::lround(slider.Value())))); value.VerticalAlignment(VerticalAlignment::Center);
                value.HorizontalAlignment(HorizontalAlignment::Right);
                enabled.HorizontalAlignment(HorizontalAlignment::Left);
                showInTray.HorizontalAlignment(HorizontalAlignment::Left);
                slider.HorizontalAlignment(HorizontalAlignment::Stretch);
                AutomationProperties::SetName(enabled, std::wstring(name) + L"功能开关");
                AutomationProperties::SetName(showInTray, std::wstring(name) + L"在托盘显示");
                AutomationProperties::SetName(slider, std::wstring(name) + L"调节");
                Grid::SetColumn(enabled, 1); Grid::SetColumn(showInTray, 2);
                for (auto const& element : { label.as<FrameworkElement>(), enabled.as<FrameworkElement>(),
                    showInTray.as<FrameworkElement>() })
                    Grid::SetRow(element, rowIndex);
                controlsGrid.Children().Append(label); controlsGrid.Children().Append(enabled);
                controlsGrid.Children().Append(showInTray);
                if (!linked)
                {
                    Grid::SetColumn(slider, 3); Grid::SetColumn(value, 4);
                    Grid::SetRow(slider, rowIndex); Grid::SetRow(value, rowIndex);
                    controlsGrid.Children().Append(slider); controlsGrid.Children().Append(value);
                }
                enabled.Toggled([this, slider, showInTray](auto const& sender, auto const&)
                {
                    auto on = sender.template as<ToggleSwitch>().IsOn(); slider.IsEnabled(on);
                    showInTray.IsEnabled(on); if (!on) showInTray.IsOn(false);
                    if (SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None))
                    {
                        auto strong = get_strong();
                        DispatcherQueue().TryEnqueue([strong] { strong->RebuildDisplayEditors(); });
                    }
                });
                showInTray.Toggled([this](auto const&, auto const&)
                {
                    SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None);
                });
                slider.ValueChanged([value](auto const& sender, auto const&) { value.Text(std::to_wstring(static_cast<int>(std::lround(sender.template as<Slider>().Value())))); });
                slider.PointerCaptureLost(Microsoft::UI::Xaml::Input::PointerEventHandler(
                    [this, id = display.id, code, slider](IInspectable const&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const&)
                    { WriteDdc(id, code, static_cast<int>(std::lround(slider.Value()))); }));
                slider.KeyUp(Microsoft::UI::Xaml::Input::KeyEventHandler(
                    [this, id = display.id, code, slider](IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args)
                    { if (args.Key() == Windows::System::VirtualKey::Enter) WriteDdc(id, code, static_cast<int>(std::lround(slider.Value()))); }));
                slider.IsEnabled(enabled.IsOn()); showInTray.IsEnabled(enabled.IsOn());
            };
            controlRow(L"亮度", ::DisplaySwitcher::Native::DdcVcpCode::Brightness,
                controls.brightness, controls.brightnessEnabled, controls.brightnessShowInTray, 1);
            controlRow(L"对比度", ::DisplaySwitcher::Native::DdcVcpCode::Contrast,
                controls.contrast, controls.contrastEnabled, controls.contrastShowInTray, 2);
            controlRow(L"音量", ::DisplaySwitcher::Native::DdcVcpCode::Volume,
                controls.volume, controls.volumeEnabled, controls.volumeShowInTray, 3);

            auto fields = StackPanel(); fields.Spacing(10);
            auto header = Grid();
            auto titleColumn = ColumnDefinition();
            titleColumn.Width(GridLength{ 1, GridUnitType::Star });
            header.ColumnDefinitions().Append(titleColumn);
            auto actionColumn = ColumnDefinition();
            actionColumn.Width(GridLengthHelper::Auto());
            header.ColumnDefinitions().Append(actionColumn);
            auto displayTitle = TextBlock(); displayTitle.Text(display.name);
            displayTitle.FontSize(18); displayTitle.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            displayTitle.VerticalAlignment(VerticalAlignment::Center);
            read.VerticalAlignment(VerticalAlignment::Center);
            auto actions = StackPanel(); actions.Orientation(Orientation::Horizontal); actions.Spacing(8);
            actions.Children().Append(read); actions.Children().Append(remove);
            actions.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(actions, 1);
            header.Children().Append(displayTitle);
            header.Children().Append(actions);
            fields.Children().Append(header); fields.Children().Append(controlsGrid);
            fields.Children().Append(controls.status);
            displayEditorsPanel_.Children().Append(CreateCard(fields));
            displayEditors_.push_back(std::move(controls));
        }
    }

    void SettingsWindow::RemoveOfflineDisplay(std::wstring const& id)
    {
        auto found = std::find_if(workingDisplays_.begin(), workingDisplays_.end(), [&](auto const& display)
            { return _wcsicmp(display.id.c_str(), id.c_str()) == 0; });
        if (found == workingDisplays_.end() ||
            !::DisplaySwitcher::Native::CanDeleteOfflineDisplay(*found, ddcTopologyTrust_))
        {
            SetOperationFeedback(L"当前检测结果不允许删除该显示器；请返回本地会话并重新检测。", true);
            return;
        }
        auto dialog = ContentDialog(); dialog.Title(box_value(L"删除离线显示器？"));
        dialog.Content(box_value(L"将同时删除该显示器的 USB、协同和托盘/DDC 设置。保存失败时会完整保留旧配置。"));
        dialog.PrimaryButtonText(L"删除"); dialog.CloseButtonText(L"取消");
        dialog.DefaultButton(ContentDialogButton::Close); dialog.XamlRoot(Content().XamlRoot());
        dialog.ShowAsync().Completed([this, id, dialog](auto const& operation, auto const& status)
        {
            if (status != Windows::Foundation::AsyncStatus::Completed ||
                operation.GetResults() != ContentDialogResult::Primary) return;
            auto current = std::find_if(workingDisplays_.begin(), workingDisplays_.end(), [&](auto const& display)
                { return _wcsicmp(display.id.c_str(), id.c_str()) == 0; });
            if (current == workingDisplays_.end() ||
                !::DisplaySwitcher::Native::CanDeleteOfflineDisplay(*current, ddcTopologyTrust_))
            {
                SetOperationFeedback(L"检测状态已经变化，未删除显示器。", true);
                return;
            }
            auto candidate = original_;
            if (!::DisplaySwitcher::Native::RemoveDisplayAndDependencies(candidate.displays,
                candidate.collaborationProfiles, candidate.usbSwitch, id)) return;
            if (!saved_ || !saved_(candidate))
            {
                LoadValues(original_);
                SetOperationFeedback(L"显示器删除未保存；目录和全部映射已完整保留。", true);
                return;
            }
            original_ = std::move(candidate);
            LoadValues(original_);
            SetOperationFeedback(L"离线显示器及其关联设置已删除。");
        });
    }

    void SettingsWindow::CaptureProfileEditors()
    {
        for (auto const& controls : profileEditors_)
        {
            auto profile = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
            { return _wcsicmp(item.id.c_str(), controls.id.c_str()) == 0; });
            if (profile == workingProfiles_.end()) continue;
            profile->name = Trim(controls.name.Text().c_str());
            profile->coordinationEnabled = controls.enabled.IsOn();
            profile->peerHost = Trim(controls.peerHost.Text().c_str());
            profile->peerPort = ParseInteger(controls.peerPort.Text().c_str(), 10, 1, 65535).value_or(-1);
            profile->pairingCode = controls.pairingCode.Password().c_str();
            std::vector<::DisplaySwitcher::Native::VisibleDisplayInputEdit> visibleEdits;
            for (auto const& mapping : controls.mappings)
            {
                auto parsed = ::DisplaySwitcher::Native::ParseInputSourceText(mapping.peerInput.Text().c_str());
                visibleEdits.push_back({ mapping.displayId,
                    parsed.status == ::DisplaySwitcher::Native::InputSourceTextStatus::Invalid
                        ? std::optional<int>{ -1 } : parsed.value });
            }
            profile->displayInputs = ::DisplaySwitcher::Native::MergeVisibleProfileDisplayInputs(
                profile->displayInputs, visibleEdits);
        }
    }

    void SettingsWindow::RebuildProfileEditors()
    {
        if (!profileEditorsPanel_) return;
        RefreshProfileSelectors();
        profileEditorsPanel_.Children().Clear(); profileEditors_.clear();
        auto selectedProfile = profileSelector_.SelectedIndex();
        for (size_t index = 0; index < workingProfiles_.size(); ++index)
        {
            if (selectedProfile >= 0 && index != static_cast<size_t>(selectedProfile)) continue;
            auto const profile = workingProfiles_[index];
            ProfileEditorControls controls; controls.id = profile.id;
            controls.name = TextBox(); Header(controls.name, L"配置名称"); controls.name.Text(profile.name); controls.name.MaxLength(32);
            controls.enabled = ToggleSwitch(); controls.enabled.IsOn(profile.coordinationEnabled);
            controls.peerHost = TextBox(); Header(controls.peerHost, L"对端 IP 或主机名"); controls.peerHost.Text(profile.peerHost); controls.peerHost.MaxLength(253);
            controls.peerPort = TextBox(); Header(controls.peerPort, L"对端端口"); controls.peerPort.Text(std::to_wstring(profile.peerPort)); controls.peerPort.MaxLength(5);
            controls.pairingCode = PasswordBox(); Header(controls.pairingCode, L"配对密码"); controls.pairingCode.Password(profile.pairingCode);
            controls.pairingCode.PlaceholderText(L"NFC 后 8–128 个 UTF-8 字节");
            controls.enabled.Toggled([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
            controls.name.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
            controls.peerHost.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
            controls.peerPort.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
            controls.pairingCode.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
            auto commitOnReturn = [this](Control const& control)
            {
                control.KeyUp(Microsoft::UI::Xaml::Input::KeyEventHandler(
                    [this](IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args)
                    { if (args.Key() == Windows::System::VirtualKey::Enter) SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); }));
            };
            commitOnReturn(controls.name); commitOnReturn(controls.peerHost);
            commitOnReturn(controls.peerPort); commitOnReturn(controls.pairingCode);

            auto fields = StackPanel(); fields.Spacing(12);
            fields.Children().Append(LabeledControlToggleRow(
                L"配置名称", controls.name, controls.enabled, L"启用此协同配置"));
            fields.Children().Append(PeerAddressRow(controls.peerHost, controls.peerPort));
            fields.Children().Append(LabeledWideControlRow(L"配对密码", controls.pairingCode));
            auto mappingGrid = CreatePeerInputMappingGrid([&](auto const& display)
            {
                ProfileMappingControls mapping; mapping.displayId = display.displayId; mapping.peerInput = TextBox();
                mapping.peerInput.MaxLength(5);
                auto existing = std::find_if(profile.displayInputs.begin(), profile.displayInputs.end(), [&](auto const& item)
                { return _wcsicmp(item.displayId.c_str(), display.displayId.c_str()) == 0; });
                if (existing != profile.displayInputs.end())
                    mapping.peerInput.Text(::DisplaySwitcher::Native::FormatInputSourceText(existing->peerInput));
                mapping.peerInput.LostFocus([this](auto const&, auto const&) { SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration); });
                auto input = mapping.peerInput;
                controls.mappings.push_back(std::move(mapping));
                return input;
            });
            fields.Children().Append(mappingGrid);

            auto triggerSummary = TextBlock();
            triggerSummary.Text(profile.triggerDevices.empty() ? L"未引用本机触发设备" : L"已引用 " + std::to_wstring(profile.triggerDevices.size()) + L" 个本机触发设备");
            triggerSummary.Opacity(0.72); fields.Children().Append(triggerSummary);
            auto remove = Button(); remove.Content(box_value(L"删除配置")); remove.IsEnabled(workingProfiles_.size() > 1);
            remove.Click([this, id = profile.id](auto const&, auto const&) { RemoveProfile(id); });
            ApplyStandardButtonGeometry(remove);
            fields.Children().Append(remove);
            profileEditorsPanel_.Children().Append(fields);
            profileEditors_.push_back(std::move(controls));
        }
    }

    void SettingsWindow::RefreshProfileSelectors()
    {
        if (selectedProfileId_.empty() && !workingProfiles_.empty()) selectedProfileId_ = workingProfiles_.front().id;
        auto wasLoading = loading_; loading_ = true;
        profileSelector_.Items().Clear(); usbProfileSelector_.Items().Clear();
        int selected = 0;
        int usbSelected = -1;
        for (size_t index = 0; index < workingProfiles_.size(); ++index)
        {
            profileSelector_.Items().Append(box_value(workingProfiles_[index].name));
            usbProfileSelector_.Items().Append(box_value(workingProfiles_[index].name));
            if (_wcsicmp(selectedProfileId_.c_str(), workingProfiles_[index].id.c_str()) == 0) selected = static_cast<int>(index);
            if (_wcsicmp(usbSelectedProfileId_.c_str(), workingProfiles_[index].id.c_str()) == 0) usbSelected = static_cast<int>(index);
        }
        if (!workingProfiles_.empty())
        {
            profileSelector_.SelectedIndex(selected);
            usbProfileSelector_.SelectedIndex(usbSelected);
            selectedProfileId_ = workingProfiles_[static_cast<size_t>(selected)].id;
            if (usbSelected >= 0) usbSelectedProfileId_ = workingProfiles_[static_cast<size_t>(usbSelected)].id;
        }
        loading_ = wasLoading;
        RefreshUsbDeviceSelection();
    }

    void SettingsWindow::RefreshUsbDeviceSelection()
    {
        if (!usbDevices_ || !usbDeviceStatus_) return;
        auto wasLoading = loading_; loading_ = true; int selected = -1;
        if (!selectedUsbLocalReference_.empty())
            for (size_t index = 0; index < devices_.size(); ++index)
                if (_wcsicmp(devices_[index].LearningDevice().localReference.c_str(), selectedUsbLocalReference_.c_str()) == 0)
                { selected = static_cast<int>(index); break; }
        usbDevices_.SelectedIndex(selected); loading_ = wasLoading;
        usbDeviceStatus_.Text(selectedUsbLocalReference_.empty() ? L"（未选择）" :
            (selected >= 0 ? L"（已连接）" : L"（未连接）"));
    }

    void SettingsWindow::RemoveProfile(std::wstring const& id)
    {
        CaptureProfileEditors();
        if (usbLearning_.Active() && _wcsicmp(usbLearning_.ProfileId().c_str(), id.c_str()) == 0)
            EndUsbLearning(::DisplaySwitcher::Native::UsbLearningCompletion::Invalidated,
                L"目标配置已删除；原 USB 绑定保持不变。");
        if (workingProfiles_.size() <= 1) { SetOperationFeedback(L"至少保留一个协同配置。", true); return; }
        auto found = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item) { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
        if (found == workingProfiles_.end()) return;
        auto dialog = ContentDialog(); dialog.Title(box_value(L"删除协同配置？"));
        dialog.Content(box_value(L"删除后会取消该配置尚未完成的本机操作。"));
        dialog.PrimaryButtonText(L"删除"); dialog.CloseButtonText(L"取消"); dialog.DefaultButton(ContentDialogButton::Close);
        dialog.XamlRoot(Content().XamlRoot());
        dialog.ShowAsync().Completed([this, id, dialog](auto const& operation, auto const& status)
        {
            if (status != Windows::Foundation::AsyncStatus::Completed || operation.GetResults() != ContentDialogResult::Primary) return;
            auto item = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& value) { return _wcsicmp(value.id.c_str(), id.c_str()) == 0; });
            if (item != workingProfiles_.end() && workingProfiles_.size() > 1) workingProfiles_.erase(item);
            if (_wcsicmp(usbSelectedProfileId_.c_str(), id.c_str()) == 0)
            {
                usbSelectedProfileId_.clear();
                usbSwitchDisplaysOnArrival_.IsOn(false);
            }
            RebuildProfileEditors(); SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration);
        });
    }

    void SettingsWindow::DetectProfile(std::wstring const& id)
    {
        if (!detectingProfileId_.empty()) return;
        CaptureDisplayEditors(); CaptureProfileEditors();
        auto config = original_; config.displays = workingDisplays_; config.collaborationProfiles = workingProfiles_;
        auto result = config.InspectProfile(id);
        if (config.displayConfigurationSafeMode) result.problems.push_back(L"配置处于安全状态，需成功保存后解除");
        auto profile = config.FindCollaborationProfile(id);
        if (profile && profile->peerProtocolVersion && *profile->peerProtocolVersion != 2)
            result.problems.push_back(L"协议版本无效");
        if (!::DisplaySwitcher::Native::IsValidDisplayId(config.localEndpointId) || config.listenPort < 1 || config.listenPort > 65535)
            result.problems.push_back(L"本机身份或监听端口无效");
        if (!result.problems.empty() || !detectProfile_)
        {
            SetConnectionStatus(L"本机配置不完整", false);
            std::wstring message = L"本机配置不完整";
            for (auto const& problem : result.problems) message += L"；" + problem;
            SetOperationFeedback(message, true);
            return;
        }
        SetOperationFeedback(L"正在检测；不会执行 USB、蓝牙、唤醒或显示器操作。");
        SetConnectionStatus(L"正在检测…", false);
        detectingProfileId_ = id;
        auto generation = ++profileDetectionGeneration_;
        SetProfileDetectionBusy(id, true);
        auto weak = get_weak();
        detectProfile_(config, id, [weak, id, generation](auto const& detection)
        {
            if (auto self = weak.get(); self && !self->windowClosed_ &&
                self->profileDetectionGeneration_ == generation)
                self->CompleteProfileDetection(id, detection);
        });
    }

    void SettingsWindow::CompleteProfileDetection(std::wstring const& id,
        ::DisplaySwitcher::Native::ProfileDetectionResult const& result)
    {
        if (windowClosed_ || detectingProfileId_.empty() ||
            _wcsicmp(detectingProfileId_.c_str(), id.c_str()) != 0) return;
        detectingProfileId_.clear();
        SetProfileDetectionBusy(id, false);
        using Outcome = ::DisplaySwitcher::Native::ProfileDetectionOutcome;
        if (result.outcome == Outcome::NetworkNotReady)
        {
            SetConnectionStatus(L"网络权限未就绪", false);
            SetOperationFeedback(L"请先点击“检查网络权限”，确认本机 UDP 监听已就绪后再检测连接。", true); return;
        }
        if (result.outcome == Outcome::SendFailed)
        {
            SetConnectionStatus(L"探测发送失败", false);
            SetOperationFeedback(L"无法发送状态探测。请检查对端地址、端口和本机网络状态。", true); return;
        }
        if (result.outcome == Outcome::LocalConfigurationIncomplete)
        {
            SetConnectionStatus(L"本机配置不完整", false); SetOperationFeedback(L"本机配置不完整，未发送探测消息。", true); return;
        }
        if (result.outcome == Outcome::AuthenticationFailed)
        {
            SetConnectionStatus(L"认证失败", false); SetOperationFeedback(L"v2 对端已响应，但认证失败。请检查配对密码。", true); return;
        }
        if (result.outcome == Outcome::NoResponse)
        {
            SetConnectionStatus(L"无响应", false); SetOperationFeedback(L"v2 状态探测无响应。", true); return;
        }
        auto profile = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
        { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
        if (profile == workingProfiles_.end()) return;
        if (result.outcome != Outcome::V2Available) return;
        if (!result.endpointConfirmationRequired)
        {
            ::DisplaySwitcher::Native::ApplyProfileDetectionResult(*profile, result, false);
            if (SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration))
            {
                SetConnectionStatus(L"v2 可用", true);
                SetOperationFeedback(L"v2 可用；检测结果已保存，未执行任何硬件操作。");
            }
            return;
        }
        auto title = result.endpointChanged ? L"对端身份已变化" : L"确认首次发现的对端";
        auto message = result.endpointChanged
            ? L"检测到的对端身份与已保存值不同。确认后将立即保存。"
            : L"检测到新的对端身份。确认后将立即保存。";
        auto dialog = ContentDialog(); dialog.Title(box_value(title)); dialog.Content(box_value(message));
        dialog.PrimaryButtonText(L"确认对端"); dialog.CloseButtonText(L"保留原值"); dialog.DefaultButton(ContentDialogButton::Close);
        dialog.XamlRoot(Content().XamlRoot());
        auto observed = result.observedEndpointId;
        auto generation = profileDetectionGeneration_;
        auto weak = get_weak();
        dialog.ShowAsync().Completed([weak, id, observed, dialog, generation](auto const& operation, auto const& status)
        {
            auto self = weak.get();
            if (!self || self->windowClosed_ || self->profileDetectionGeneration_ != generation) return;
            if (status != Windows::Foundation::AsyncStatus::Completed || operation.GetResults() != ContentDialogResult::Primary)
            {
                self->SetConnectionStatus(L"v2 可用，对端身份未确认", false);
                self->SetOperationFeedback(L"未确认对端身份；原配置保持不变。"); return;
            }
            auto target = std::find_if(self->workingProfiles_.begin(), self->workingProfiles_.end(), [&](auto const& item)
            { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
            if (target == self->workingProfiles_.end()) return;
            ::DisplaySwitcher::Native::ProfileDetectionResult confirmed;
            confirmed.outcome = ::DisplaySwitcher::Native::ProfileDetectionOutcome::V2Available;
            confirmed.observedEndpointId = observed; confirmed.endpointConfirmationRequired = true;
            ::DisplaySwitcher::Native::ApplyProfileDetectionResult(*target, confirmed, true);
            if (self->SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope::Collaboration))
            {
                self->SetConnectionStatus(L"v2 可用，对端身份已确认", true);
                self->SetOperationFeedback(L"对端身份已确认并保存。");
            }
        });
    }

    void SettingsWindow::CancelProfileDetection()
    {
        if (detectingProfileId_.empty()) return;
        auto id = std::move(detectingProfileId_);
        detectingProfileId_.clear();
        ++profileDetectionGeneration_;
        SetProfileDetectionBusy(id, false);
        if (cancelProfileDetection_) cancelProfileDetection_();
    }

    void SettingsWindow::SetProfileDetectionBusy(std::wstring const& id, bool busy)
    {
        static_cast<void>(id);
        if (!detectProfileButton_) return;
        detectProfileButton_.IsEnabled(!busy);
        detectProfileButton_.Content(box_value(busy ? L"正在检测…" : L"检测连接"));
    }

    ::DisplaySwitcher::Native::AppConfig SettingsWindow::WorkingDdcConfig()
    {
        CaptureDisplayEditors();
        auto config = original_;
        config.linkAllDisplays = linkAllDisplays_.IsOn();
        config.displays = workingDisplays_;
        return config;
    }

    void SettingsWindow::ReadDdc(std::wstring const& displayId)
    {
        if (!readDdc_) { SetOperationFeedback(L"硬件 DDC 读取服务不可用。", true); return; }
        auto config = WorkingDdcConfig();
        auto token = ddcCancellation_.Begin();
        auto operation = readDdc_;
        auto dispatcher = DispatcherQueue();
        auto strong = get_strong();
        SetOperationFeedback(L"正在读取硬件 DDC 状态…");
        std::thread([strong, dispatcher, operation, config = std::move(config), displayId, token]() mutable
        {
            ::DisplaySwitcher::Native::DdcControlBatchResult result;
            try { result = operation(config, { displayId }, token); }
            catch (...) { result.items.push_back({ displayId, {}, false, false, false, false, {}, {},
                ::DisplaySwitcher::Native::DdcAvailability::TemporarilyUnavailable,
                ::DisplaySwitcher::Native::DdcErrorKind::ReadFailed, L"读取硬件 DDC 状态时发生异常" }); }
            dispatcher.TryEnqueue([strong, config = std::move(config), result = std::move(result), token]()
            { strong->CompleteDdcOperation(config, result, token, false); });
        }).detach();
    }

    void SettingsWindow::WriteDdc(std::wstring const& displayId, ::DisplaySwitcher::Native::DdcVcpCode code, int value)
    {
        if (!writeDdc_) { SetOperationFeedback(L"硬件 DDC 写入服务不可用。", true); return; }
        auto config = WorkingDdcConfig();
        auto token = ddcCancellation_.Begin();
        auto operation = writeDdc_;
        auto linkAll = original_.linkAllDisplays;
        auto dispatcher = DispatcherQueue();
        auto strong = get_strong();
        SetOperationFeedback(L"正在提交硬件 DDC 设置…");
        std::thread([strong, dispatcher, operation, config = std::move(config), displayId, code, value, linkAll, token]() mutable
        {
            ::DisplaySwitcher::Native::DdcControlBatchResult result;
            try { result = operation(config, displayId, code, value, linkAll, token); }
            catch (...) { result.items.push_back({ displayId, code, false, false, false, false, {}, {},
                ::DisplaySwitcher::Native::DdcAvailability::TemporarilyUnavailable,
                ::DisplaySwitcher::Native::DdcErrorKind::WriteFailed, L"写入硬件 DDC 设置时发生异常" }); }
            dispatcher.TryEnqueue([strong, config = std::move(config), result = std::move(result), token]()
            { strong->CompleteDdcOperation(config, result, token, true); });
        }).detach();
    }

    void SettingsWindow::CompleteDdcOperation(::DisplaySwitcher::Native::AppConfig const& config,
        ::DisplaySwitcher::Native::DdcControlBatchResult const& result,
        ::DisplaySwitcher::Native::DdcCancellationToken const& cancellation, bool write)
    {
        if (cancellation.IsCanceled() || result.canceled) return;
        auto cacheChanged = std::any_of(result.items.begin(), result.items.end(), [](auto const& item)
        { return item.success && item.trusted; });
        if (cacheChanged)
        {
            auto cacheDisplays = workingDisplays_;
            for (auto const& updated : config.displays)
            {
                auto found = ::DisplaySwitcher::Native::FindDisplayById(cacheDisplays, updated.id);
                if (!found) continue;
                auto& current = cacheDisplays[*found];
                current.brightnessValue = updated.brightnessValue; current.brightnessMax = updated.brightnessMax;
                current.contrastValue = updated.contrastValue; current.contrastMax = updated.contrastMax;
                current.volumeValue = updated.volumeValue; current.volumeMax = updated.volumeMax;
            }
            if (!commitDdcCache_ || !commitDdcCache_(cacheDisplays))
            {
                ddcCancellation_.Cancel();
                SetOperationFeedback(L"无法保存 DDC 估计缓存；当前进程已进入安全状态。", true);
                return;
            }
            workingDisplays_ = std::move(cacheDisplays);
            RebuildDisplayEditors();
        }
        for (auto const& editor : displayEditors_)
        {
            auto first = std::find_if(result.items.begin(), result.items.end(), [&](auto const& item)
            { return _wcsicmp(item.displayId.c_str(), editor.id.c_str()) == 0; });
            if (first == result.items.end()) continue;
            auto failed = std::find_if(first, result.items.end(), [&](auto const& item)
            { return _wcsicmp(item.displayId.c_str(), editor.id.c_str()) == 0 && (!item.success || !item.trusted); });
            editor.status.Text(::DisplaySwitcher::Native::DescribeBasicDdcResult(
                failed != result.items.end() ? *failed : *first, write));
        }
        auto failures = std::count_if(result.items.begin(), result.items.end(), [](auto const& item) { return !item.success || !item.trusted; });
        if (result.items.empty()) SetOperationFeedback(L"未执行 DDC 操作：功能可能已关闭或显示器配置不完整。", true);
        else if (failures)
        {
            auto first = std::find_if(result.items.begin(), result.items.end(), [](auto const& item) { return !item.success || !item.trusted; });
            SetOperationFeedback(first->error == ::DisplaySwitcher::Native::DdcErrorKind::AmbiguousMonitor
                ? L"硬件 DDC 操作失败：显示器匹配不唯一。"
                : (write ? L"部分硬件 DDC 写入失败。" : L"部分硬件 DDC 读取失败。"), true);
        }
        else
        {
            SetOperationFeedback(write ? L"硬件 DDC 设置已提交。" : L"硬件 DDC 状态已读取。");
        }
    }

    bool SettingsWindow::Save(::DisplaySwitcher::Native::SettingsSaveFeedbackScope scope, bool hideAfterSave)
    {
        if (loading_) return false;
        ddcCancellation_.Cancel();
        auto reject = [&](int tab, std::wstring const& message)
        {
            tabs_.SelectedIndex(tab);
            LoadValues(original_);
            SetOperationFeedback(message, true);
        };
        CaptureProfileEditors();
        std::set<std::wstring> profileNames;
        for (auto& profile : workingProfiles_)
        {
            auto normalizedName = profile.name; std::transform(normalizedName.begin(), normalizedName.end(), normalizedName.begin(), towlower);
            if (profile.name.empty() || !profileNames.insert(normalizedName).second)
            { reject(2, L"协同配置名称不能为空，且忽略大小写后必须唯一。"); return false; }
            if (profile.peerPort < 1 || profile.peerPort > 65535)
            { reject(2, profile.name + L"的对端端口必须为 1–65535。"); return false; }
            if (!profile.pairingCode.empty() && !::DisplaySwitcher::Native::AppConfig::IsValidPairingCode(profile.pairingCode))
            { reject(2, profile.name + L"的配对密码在 NFC 规范化后必须为 8–128 个 UTF-8 字节。"); return false; }
            profile.pairingCode = ::DisplaySwitcher::Native::AppConfig::NormalizeNfc(profile.pairingCode);
            for (auto const& mapping : profile.displayInputs)
                if (!::DisplaySwitcher::Native::IsValidInputSourceValue(mapping.peerInput))
                { reject(2, profile.name + L"包含无效的显示器输入源编号。"); return false; }
            if (profile.coordinationEnabled)
            {
                auto candidate = original_; candidate.displays = workingDisplays_; candidate.collaborationProfiles = workingProfiles_;
                auto inspection = candidate.InspectProfile(profile.id);
                if (!inspection.complete || profile.peerProtocolVersion != 2 ||
                    !::DisplaySwitcher::Native::IsValidDisplayId(profile.peerEndpointId))
                { reject(2, profile.name + L"配置不完整，无法启用。"); return false; }
            }
        }
        CaptureDisplayEditors();
        if (usbAutomation_.IsOn() && workingDisplays_.empty())
        { reject(1, L"启用 USB 自动切换前，请先完成显示器配置。"); return false; }
        std::vector<::DisplaySwitcher::Native::VisibleDisplayInputEdit> visibleUsbEdits;
        bool hasUsbMapping{};
        for (auto const& editor : usbMappingEditors_)
        {
            auto parsed = ::DisplaySwitcher::Native::ParseInputSourceText(editor.targetInput.Text().c_str());
            if (parsed.status == ::DisplaySwitcher::Native::InputSourceTextStatus::Invalid)
            { reject(1, L"USB 显示器输入源必须留空或填写 1–65535。"); return false; }
            visibleUsbEdits.push_back({ editor.displayId, parsed.value });
            if (parsed.value) hasUsbMapping = true;
        }
        auto usbMappings = ::DisplaySwitcher::Native::MergeVisibleUsbDisplayInputs(
            original_.usbSwitch.displayInputs, visibleUsbEdits);
        if (usbAutomation_.IsOn() && (selectedUsbLocalReference_.empty() || !hasUsbMapping))
        { reject(1, L"启用 USB 自动切换前，必须选择一个设备并至少配置一台显示器输入源。"); return false; }
        if (usbSwitchDisplaysOnArrival_.IsOn())
        {
            auto profile = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
                { return _wcsicmp(item.id.c_str(), usbSelectedProfileId_.c_str()) == 0; });
            auto candidate = original_; candidate.displays = workingDisplays_; candidate.collaborationProfiles = workingProfiles_;
            if (profile == workingProfiles_.end() || !profile->coordinationEnabled || !candidate.InspectProfile(profile->id).complete)
            { reject(1, L"启用联动协同前，必须选择一个已开启且完整的协同配置。"); return false; }
        }
        std::set<std::wstring> hardwareIds;
        for (auto const& display : workingDisplays_)
        {
            if (display.name.empty())
            { reject(3, L"显示器信息不完整，已恢复最后有效配置。"); return false; }
            std::wstring backend = L"native_ddc";
            auto hardwareId = ::DisplaySwitcher::Native::CanonicalDdcMonitorId(display.nativeMonitorId);
            if (hardwareId.empty())
            {
                reject(3, display.name + L"当前未关联可用显示器。");
                return false;
            }
            hardwareId = backend + L":" + hardwareId;
            std::transform(hardwareId.begin(), hardwareId.end(), hardwareId.begin(), towlower);
            if (!hardwareIds.insert(hardwareId).second)
            { reject(3, L"显示器关联发生冲突，已恢复最后有效配置。"); return false; }
        }
        auto result = original_;
        result.usbSwitch.enabled = usbAutomation_.IsOn();
        result.usbSwitch.collaborationWakeEnabled = usbSwitchDisplaysOnArrival_.IsOn();
        result.usbSwitch.collaborationProfileId = usbSelectedProfileId_;
        result.usbSwitch.deviceLocalReference = selectedUsbLocalReference_;
        result.usbSwitch.deviceName = selectedUsbName_;
        result.usbSwitch.vendorId = selectedUsbVendorId_; result.usbSwitch.productId = selectedUsbProductId_;
        result.usbSwitch.displayInputs = std::move(usbMappings);
        result.linkAllDisplays = linkAllDisplays_.IsOn();
        result.displays = workingDisplays_;
        result.collaborationProfiles = workingProfiles_;
        for (auto& display : result.displays) display.macInput = -1;
        result.displayConfigurationSafeMode = false; result.startWithWindows = autoStart_.IsOn();
        result.detailedDiagnosticRecording = detailedDiagnostics_.IsOn();
        if (AppConfigEquals(original_, result))
        {
            if (hideAfterSave) appWindow_.Hide();
            return true;
        }
        if (!saved_ || !saved_(result))
        {
            auto action = saveFeedback_.RecordSaveResult(scope, true, false,
                L"设置未保存；旧配置已保留，自动协同和硬件操作已安全停用。", SteadyMs());
            if (action == ::DisplaySwitcher::Native::SettingsSaveFeedbackAction::ShowOperationFailure)
                SetOperationFeedback(L"设置未保存；旧配置已保留，自动协同和硬件操作已安全停用。", true);
            else if (action == ::DisplaySwitcher::Native::SettingsSaveFeedbackAction::ShowScopedFeedback)
            {
                ResetSaveFeedbackTimer();
                ApplySaveFeedback(std::chrono::milliseconds{});
            }
            LoadValues(original_);
            return false;
        }
        original_ = result;
        auto action = saveFeedback_.RecordSaveResult(scope, true, true, L"✓ 已保存", SteadyMs());
        if (action == ::DisplaySwitcher::Native::SettingsSaveFeedbackAction::ShowScopedFeedback)
        {
            ResetSaveFeedbackTimer();
            ApplySaveFeedback(std::chrono::milliseconds{});
        }
        if (hideAfterSave) appWindow_.Hide();
        return true;
    }

    bool SettingsWindow::SaveImmediately(::DisplaySwitcher::Native::SettingsSaveFeedbackScope scope)
    {
        if (!detectingProfileId_.empty()) CancelProfileDetection();
        return !loading_ && Save(scope, false);
    }

    void SettingsWindow::RefreshDiagnosticPreview()
    {
        if (!diagnosticPreview_) return;
        if (diagnosticSnapshotProvider_)
            diagnosticPreview_.Text(diagnosticPreviewModel_.Refresh(*diagnosticSnapshotProvider_));
    }

    void SettingsWindow::CopyDiagnosticPreview()
    {
        if (!diagnosticPreview_) return;
        auto visible = std::wstring(diagnosticPreview_.Text().c_str());
        // Copy exactly what is visible. No refresh or alternate export path is allowed here.
        auto package = Windows::ApplicationModel::DataTransfer::DataPackage();
        package.SetText(visible);
        Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
        Windows::ApplicationModel::DataTransfer::Clipboard::Flush();
        SetOperationFeedback(L"已复制当前可见的诊断预览。");
    }

    void SettingsWindow::SetOperationFeedback(std::wstring const& message,
        ::DisplaySwitcher::Native::SettingsOperationFeedbackSeverity severity)
    {
        if (!operationStatus_) return;
        operationStatus_.Text(message);
        auto success = severity == ::DisplaySwitcher::Native::SettingsOperationFeedbackSeverity::Success;
        auto failure = severity == ::DisplaySwitcher::Native::SettingsOperationFeedbackSeverity::Failure;
        operationStatus_.Foreground(ThemeBrush(
            success ? L"SystemFillColorSuccessBrush" :
                (failure ? L"SystemFillColorCriticalBrush" : L"TextFillColorSecondaryBrush"),
            success ? Colors::Green() : (failure ? Colors::Red() : Colors::Gray())));
        operationStatus_.Visibility(message.empty() ? Visibility::Collapsed : Visibility::Visible);
    }

    void SettingsWindow::SetOperationFeedback(std::wstring const& message, bool failure)
    {
        SetOperationFeedback(message, failure ?
            ::DisplaySwitcher::Native::SettingsOperationFeedbackSeverity::Failure :
            ::DisplaySwitcher::Native::SettingsOperationFeedbackSeverity::Informational);
    }

    void SettingsWindow::AppendLayoutElement(Panel const& parent, UIElement const& child,
        ::DisplaySwitcher::Native::SettingsLayoutElement element,
        ::DisplaySwitcher::Native::SettingsLayoutRegion region)
    {
        if (!layoutPresenter_.Attach(element, region))
            throw hresult_illegal_method_call(L"Settings layout element has an invalid or duplicate parent.");
        parent.Children().Append(child);
    }

    void SettingsWindow::ShowSaveFailure(::DisplaySwitcher::Native::SettingsSaveFeedbackScope scope, std::wstring const& message)
    {
        if (scope == ::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None) return;
        saveFeedback_.RecordSaveResult(scope, true, false, message, SteadyMs());
        ResetSaveFeedbackTimer();
        ApplySaveFeedback(std::chrono::milliseconds{});
    }

    void SettingsWindow::ShowSaveSuccess(::DisplaySwitcher::Native::SettingsSaveFeedbackScope scope, std::wstring const& message)
    {
        if (scope == ::DisplaySwitcher::Native::SettingsSaveFeedbackScope::None) return;
        saveFeedback_.RecordSaveResult(scope, true, true, message, SteadyMs());
        ResetSaveFeedbackTimer();
        ApplySaveFeedback(std::chrono::milliseconds{});
    }

    void SettingsWindow::ResetSaveFeedbackTimer()
    {
        if (!saveFeedbackTimer_) return;
        saveFeedbackTimer_.Stop();
        if (saveFeedback_.HasActiveSuccess()) saveFeedbackTimer_.Start();
    }

    void SettingsWindow::ApplySaveFeedback(std::chrono::milliseconds const&)
    {
        if (!saveStatus_) return;
        auto selected = tabs_ ? tabs_.SelectedIndex() : -1;
        auto page = selected >= 0 && selected <= static_cast<int32_t>(::DisplaySwitcher::Native::SettingsPage::About)
            ? static_cast<::DisplaySwitcher::Native::SettingsPage>(selected)
            : ::DisplaySwitcher::Native::SettingsPage::General;
        auto feedback = saveFeedback_.VisibleFeedback(page, SteadyMs());
        saveStatus_.Text(feedback ? feedback->message : L"");
        saveStatus_.Foreground(ThemeBrush(
            feedback && feedback->failure ? L"SystemFillColorCriticalBrush" : L"SystemFillColorSuccessBrush",
            feedback && feedback->failure ? Colors::Red() : Colors::Green()));
        saveStatus_.Visibility(feedback ? Visibility::Visible : Visibility::Collapsed);
        if (!saveFeedback_.HasActiveSuccess() && saveFeedbackTimer_) saveFeedbackTimer_.Stop();
    }

    int64_t SettingsWindow::SteadyMs()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    }
}
