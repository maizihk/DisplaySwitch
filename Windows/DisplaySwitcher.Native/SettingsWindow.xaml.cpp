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

namespace
{
    void Header(Control const& control, wchar_t const* text)
    {
        if (auto textBox = control.try_as<TextBox>()) textBox.Header(box_value(text));
        else if (auto passwordBox = control.try_as<PasswordBox>()) passwordBox.Header(box_value(text));
        else if (auto comboBox = control.try_as<ComboBox>()) comboBox.Header(box_value(text));
        else if (auto toggleSwitch = control.try_as<ToggleSwitch>()) toggleSwitch.Header(box_value(text));
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
        for (auto const& device : devices) result.push_back(device.LearningDevice());
        return result;
    }
}

namespace winrt::DisplaySwitcher::Native::implementation
{
    SettingsWindow::SettingsWindow() { InitializeComponent(); }

    void SettingsWindow::Initialize(::DisplaySwitcher::Native::AppConfig const& config,
        std::function<bool(::DisplaySwitcher::Native::AppConfig const&)> saved,
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::vector<std::wstring> const&, ::DisplaySwitcher::Native::DdcCancellationToken const&)> readDdc,
        std::function<::DisplaySwitcher::Native::DdcControlBatchResult(::DisplaySwitcher::Native::AppConfig&,
            std::wstring const&, ::DisplaySwitcher::Native::DdcVcpCode, int, bool,
            ::DisplaySwitcher::Native::DdcCancellationToken const&)> writeDdc,
        std::function<bool(std::vector<::DisplaySwitcher::Native::DisplayConfig> const&)> commitDdcCache,
        std::function<void()> beginUsbLearning,
        std::function<void()> endUsbLearning,
        std::function<void()> closed)
    {
        if (initialized_) return;
        initialized_ = true;
        original_ = config; saved_ = std::move(saved); readDdc_ = std::move(readDdc);
        writeDdc_ = std::move(writeDdc); commitDdcCache_ = std::move(commitDdcCache);
        beginUsbLearning_ = std::move(beginUsbLearning); endUsbLearning_ = std::move(endUsbLearning);
        closed_ = std::move(closed);
        Title(L"常规");
        try { SystemBackdrop(MicaBackdrop()); } catch (...) {}
        auto content = BuildContent();
        Content(content);
        if (auto root = content.try_as<FrameworkElement>())
            root.ActualThemeChanged([this](auto const&, auto const&) { ApplyTitleBarTheme(); });
        LoadValues(config); ResizeAndCenter(); ApplyTitleBarTheme();
        Closed([this](auto const&, auto const&) { ddcCancellation_.Cancel(); EndUsbLearning(); if (closed_) closed_(); });
        LoadUsbDevices();
        LoadDdcMonitors();
    }

    UIElement SettingsWindow::BuildContent()
    {
        validation_ = TextBlock(); validation_.Foreground(SolidColorBrush(Windows::UI::Color{ 255, 196, 43, 28 }));
        validation_.TextWrapping(TextWrapping::Wrap); validation_.Visibility(Visibility::Collapsed);
        usbAutomation_ = ToggleSwitch(); Header(usbAutomation_, L"启用 USB 自动切换");
        usbDevices_ = ComboBox(); Header(usbDevices_, L"当前 USB 设备"); usbDevices_.HorizontalAlignment(HorizontalAlignment::Stretch);
        vendorId_ = TextBox(); Header(vendorId_, L"Vendor ID"); vendorId_.PlaceholderText(L"4 位十六进制"); vendorId_.MaxLength(4);
        productId_ = TextBox(); Header(productId_, L"Product ID"); productId_.PlaceholderText(L"4 位十六进制"); productId_.MaxLength(4);
        displayBackend_ = ComboBox(); Header(displayBackend_, L"显示器控制方式"); displayBackend_.HorizontalAlignment(HorizontalAlignment::Stretch);
        displayBackend_.PlaceholderText(L"请选择控制方式");
        displayBackend_.Items().Append(box_value(L"Windows 原生 DDC/CI（推荐）"));
        displayBackend_.Items().Append(box_value(L"ControlMyMonitor"));
        displayBackend_.SelectionChanged([this](auto const&, auto const&) { UpdateDisplayBackendVisibility(); });
        controlMyMonitor_ = TextBox(); Header(controlMyMonitor_, L"ControlMyMonitor 路径");
        linkAllDisplays_ = ToggleSwitch(); Header(linkAllDisplays_, L"联动所有显示器");
        linkAllDisplays_.OffContent(box_value(L"仅控制当前显示器"));
        linkAllDisplays_.OnContent(box_value(L"显式联动已开启"));
        autoStart_ = ToggleSwitch(); Header(autoStart_, L"登录 Windows 时自动启动");
        usbDevices_.SelectionChanged([this](auto const&, auto const&)
        {
            auto index = usbDevices_.SelectedIndex();
            if (index < 0 || static_cast<size_t>(index) >= devices_.size()) return;
            wchar_t value[5]{}; swprintf_s(value, L"%04X", devices_[index].vendorId); vendorId_.Text(value);
            swprintf_s(value, L"%04X", devices_[index].productId); productId_.Text(value);
        });

        auto root = Grid();
        auto contentRow = RowDefinition(); contentRow.Height(GridLength{ 1, GridUnitType::Star });
        auto footerRow = RowDefinition(); footerRow.Height(GridLengthHelper::Auto());
        root.RowDefinitions().Append(contentRow); root.RowDefinitions().Append(footerRow);

        tabs_ = TabView(); tabs_.IsAddTabButtonVisible(false);
        tabs_.TabWidthMode(TabViewWidthMode::Equal);
        tabs_.HorizontalAlignment(HorizontalAlignment::Stretch); tabs_.VerticalAlignment(VerticalAlignment::Stretch);
        auto tabStripHeaderInset = Grid(); tabStripHeaderInset.Width(12);
        auto tabStripFooterInset = Grid(); tabStripFooterInset.Width(12);
        tabs_.TabStripHeader(tabStripHeaderInset); tabs_.TabStripFooter(tabStripFooterInset);

        auto commonTab = TabViewItem(); commonTab.IsClosable(false); commonTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        commonTab.Header(CreateTabHeader(L"\uE713", L"常规"));
        auto commonHint = TextBlock(); commonHint.Text(L"程序启动后常驻系统托盘，可在托盘菜单中打开设置或退出。");
        commonHint.TextWrapping(TextWrapping::Wrap); commonHint.Opacity(0.72);
        auto about = Button(); about.Content(box_value(L"关于 DisplaySwitch"));
        about.Click([this](auto const&, auto const&) { ShowAbout(); });
        commonTab.Content(CreatePage({ CreateSection(L"常规", { autoStart_, commonHint, about }) }));

        auto refresh = Button(); refresh.Content(box_value(L"重新读取")); refresh.VerticalAlignment(VerticalAlignment::Bottom);
        refresh.Click([this](auto const&, auto const&) { LoadUsbDevices(); });
        auto usbTab = TabViewItem(); usbTab.IsClosable(false); usbTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        usbTab.Header(CreateTabHeader(L"\uE88E", L"USB 切换"));
        auto usbHint = TextBlock(); usbHint.Text(L"此页保留旧版单对端 USB 设置。新绑定请在对应协同配置中使用“学习 USB 设备…”，程序不会猜测候选。");
        usbHint.TextWrapping(TextWrapping::Wrap); usbHint.Opacity(0.72);
        usbTab.Content(CreatePage({ CreateSection(L"USB 触发设备", {
            usbAutomation_, CreateTwoColumn(usbDevices_, refresh), CreateTwoColumn(vendorId_, productId_), usbHint }) }));

        auto peerTab = TabViewItem(); peerTab.IsClosable(false); peerTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        peerTab.Header(CreateTabHeader(L"\uE968", L"协同"));
        auto peerStatus = StackPanel(); peerStatus.Orientation(Orientation::Horizontal); peerStatus.Spacing(8);
        connectionDot_ = TextBlock(); connectionDot_.Text(L"●"); connectionDot_.FontSize(16);
        connectionStatus_ = TextBlock(); connectionStatus_.VerticalAlignment(VerticalAlignment::Center);
        peerStatus.Children().Append(connectionDot_); peerStatus.Children().Append(connectionStatus_);
        SetConnectionStatus(L"协同未启用", false);
        auto peerHint = TextBlock(); peerHint.Text(L"可保存多个目标配置并同时开启。检测仅检查本机字段和显示器引用，不发送网络消息，也不执行硬件操作。");
        peerHint.TextWrapping(TextWrapping::Wrap); peerHint.Opacity(0.72);
        auto addProfile = Button(); addProfile.Content(box_value(L"添加配置"));
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
            RebuildProfileEditors();
        });
        profileEditorsPanel_ = StackPanel(); profileEditorsPanel_.Spacing(14);
        peerTab.Content(CreatePage({ CreateSection(L"协同配置", {
            peerStatus, peerHint, addProfile, profileEditorsPanel_ }) }));

        auto displayTab = TabViewItem(); displayTab.IsClosable(false); displayTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        displayTab.Header(CreateTabHeader(L"\uE7F4", L"显示器"));
        auto displayHint = TextBlock(); displayHint.Text(L"首次使用时请选择控制方式和显示器，并在协同配置中填写各自的对端输入源；未完成配置前不会执行切屏。");
        displayHint.TextWrapping(TextWrapping::Wrap); displayHint.Opacity(0.72);
        nativeDdcPanel_ = StackPanel(); nativeDdcPanel_.Spacing(14);
        auto nativeHint = TextBlock(); nativeHint.Text(L"直接调用 Windows DDC/CI，无需外部工具。重新连接显示器后会自动刷新句柄。");
        nativeHint.TextWrapping(TextWrapping::Wrap); nativeHint.Opacity(0.72);
        auto refreshDdc = Button(); refreshDdc.Content(box_value(L"重新检测显示器"));
        refreshDdc.Click([this](auto const&, auto const&) { LoadDdcMonitors(); });
        nativeDdcPanel_.Children().Append(nativeHint); nativeDdcPanel_.Children().Append(refreshDdc);
        controlMyMonitorPanel_ = StackPanel(); controlMyMonitorPanel_.Spacing(14);
        auto cmmHint = TextBlock(); cmmHint.Text(L"兼容模式：继续通过外部 ControlMyMonitor 执行切换。");
        cmmHint.TextWrapping(TextWrapping::Wrap); cmmHint.Opacity(0.72);
        controlMyMonitorPanel_.Children().Append(cmmHint); controlMyMonitorPanel_.Children().Append(controlMyMonitor_);
        auto addDisplay = Button(); addDisplay.Content(box_value(L"添加显示器"));
        addDisplay.Click([this](auto const&, auto const&)
        {
            CaptureProfileEditors();
            CaptureDisplayEditors();
            auto display = ::DisplaySwitcher::Native::CreateDisplayConfig(
                L"显示器 " + std::to_wstring(workingDisplays_.size() + 1));
            display.backend = displayBackend_.SelectedIndex() == 1 ? L"control_my_monitor" : L"native_ddc";
            workingDisplays_.push_back(std::move(display));
            RebuildDisplayEditors();
            RebuildProfileEditors();
        });
        displayEditorsPanel_ = StackPanel(); displayEditorsPanel_.Spacing(14);
        displayTab.Content(CreatePage({ CreateSection(L"显示器控制", { displayHint, displayBackend_, linkAllDisplays_, nativeDdcPanel_,
            controlMyMonitorPanel_, addDisplay, displayEditorsPanel_ }) }));

        tabs_.TabItems().Append(commonTab); tabs_.TabItems().Append(usbTab);
        tabs_.TabItems().Append(peerTab); tabs_.TabItems().Append(displayTab);
        tabs_.SelectedIndex(0);
        tabs_.SelectionChanged([this](auto const&, auto const&)
        {
            static constexpr wchar_t const* titles[]{ L"常规", L"USB 切换", L"协同", L"显示器" };
            auto index = tabs_.SelectedIndex();
            if (index >= 0 && index < 4) Title(titles[index]);
            validation_.Visibility(Visibility::Collapsed);
        });
        Grid::SetRow(tabs_, 0); root.Children().Append(tabs_);

        auto footer = Grid(); footer.Padding(Thickness{ 24, 12, 24, 20 }); footer.ColumnSpacing(16);
        auto messageColumn = ColumnDefinition(); messageColumn.Width(GridLength{ 1, GridUnitType::Star });
        auto buttonColumn = ColumnDefinition(); buttonColumn.Width(GridLengthHelper::Auto());
        footer.ColumnDefinitions().Append(messageColumn); footer.ColumnDefinitions().Append(buttonColumn);
        validation_.VerticalAlignment(VerticalAlignment::Center); Grid::SetColumn(validation_, 0); footer.Children().Append(validation_);
        auto cancel = Button(); cancel.Content(box_value(L"取消")); cancel.Click([this](auto const&, auto const&) { ddcCancellation_.Cancel(); EndUsbLearning(); appWindow_.Hide(); });
        auto save = Button(); save.Content(box_value(L"保存")); save.Click([this](auto const&, auto const&) { Save(); });
        try { save.Style(Application::Current().Resources().Lookup(box_value(L"AccentButtonStyle")).as<Style>()); } catch (...) {}
        auto buttons = StackPanel(); buttons.Orientation(Orientation::Horizontal); buttons.Spacing(12);
        buttons.HorizontalAlignment(HorizontalAlignment::Right); buttons.Children().Append(cancel); buttons.Children().Append(save);
        Grid::SetColumn(buttons, 1); footer.Children().Append(buttons); Grid::SetRow(footer, 1); root.Children().Append(footer);
        return root;
    }

    Border SettingsWindow::CreateSection(std::wstring const& title, std::vector<UIElement> const& children)
    {
        auto panel = StackPanel(); panel.Spacing(16); panel.Padding(Thickness{ 0, 0, 20, 0 });
        auto heading = TextBlock(); heading.Text(title); heading.FontSize(20);
        heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold()); panel.Children().Append(heading);
        for (auto const& child : children) panel.Children().Append(child); return CreateCard(panel);
    }

    Border SettingsWindow::CreateCard(UIElement const& child)
    {
        auto border = Border(); border.Child(child); border.Padding(Thickness{ 20, 20, 20, 20 });
        border.CornerRadius(CornerRadius{ 8, 8, 8, 8 });
        border.BorderThickness(Thickness{ 1, 1, 1, 1 });
        border.Background(SolidColorBrush(Windows::UI::Color{ 20, 128, 128, 128 }));
        border.BorderBrush(SolidColorBrush(Windows::UI::Color{ 28, 128, 128, 128 })); return border;
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

    void SettingsWindow::ShowWindow() { appWindow_.Show(); Activate(); }
    void SettingsWindow::CloseForExit() { ddcCancellation_.Cancel(); Close(); }

    void SettingsWindow::SetConnectionStatus(std::wstring const& status, bool connected)
    {
        if (!connectionStatus_ || !connectionDot_) return;
        connectionStatus_.Text(status);
        auto color = connected ? Windows::UI::Color{ 255, 16, 124, 16 } : Windows::UI::Color{ 255, 96, 96, 96 };
        connectionDot_.Foreground(SolidColorBrush(color));
    }

    void SettingsWindow::LoadValues(::DisplaySwitcher::Native::AppConfig const& config)
    {
        usbAutomation_.IsOn(config.usbAutomationEnabled);
        auto loadHex = [](TextBox const& box, int number)
        {
            if (number < 0 || number > 0xFFFF) { box.Text(L""); return; }
            wchar_t value[5]{}; swprintf_s(value, L"%04X", number); box.Text(value);
        };
        loadHex(vendorId_, config.usbVendorId); loadHex(productId_, config.usbProductId);
        controlMyMonitor_.Text(config.controlMyMonitorPath);
        workingDisplays_ = config.displays;
        workingProfiles_ = config.collaborationProfiles;
        RebuildDisplayEditors();
        RebuildProfileEditors();
        autoStart_.IsOn(config.startWithWindows);
        if (config.displayControlBackend == L"native_ddc") displayBackend_.SelectedIndex(0);
        else if (config.displayControlBackend == L"control_my_monitor") displayBackend_.SelectedIndex(1);
        else displayBackend_.SelectedIndex(-1);
        UpdateDisplayBackendVisibility();
    }

    void SettingsWindow::LoadUsbDevices()
    {
        try
        {
            devices_ = ::DisplaySwitcher::Native::UsbWatcher::EnumerateDevices(); usbDevices_.Items().Clear(); int selected = -1;
            for (size_t index = 0; index < devices_.size(); ++index)
            {
                auto item = ComboBoxItem(); item.Content(box_value(devices_[index].DisplayName())); usbDevices_.Items().Append(item);
                if (devices_[index].vendorId == original_.usbVendorId && devices_[index].productId == original_.usbProductId) selected = static_cast<int>(index);
            }
            if (selected >= 0) usbDevices_.SelectedIndex(selected); validation_.Visibility(Visibility::Collapsed);
        }
        catch (hresult_error const& error) { ShowValidationError(L"读取 USB 失败：" + std::wstring(error.message())); }
        catch (...) { ShowValidationError(L"读取 USB 失败。"); }
    }

    void SettingsWindow::StartUsbLearning(std::wstring const& profileId)
    {
        EndUsbLearning();
        CaptureProfileEditors();
        auto profile = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
            { return _wcsicmp(item.id.c_str(), profileId.c_str()) == 0; });
        if (profile == workingProfiles_.end())
        {
            ShowValidationError(L"目标协同配置已不存在，未改变 USB 绑定。");
            return;
        }

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
            validation_.Text(L"正在为“" + profile->name + L"”学习 USB 设备：请在 30 秒内接入目标设备。学习完成前自动协同和硬件操作保持暂停。");
            validation_.Visibility(Visibility::Visible);
        }
        catch (...)
        {
            EndUsbLearning();
            ShowValidationError(L"无法开始 USB 学习；原绑定保持不变。");
        }
    }

    void SettingsWindow::PollUsbLearning()
    {
        if (!usbLearning_.Active() || usbLearningDialogOpen_) return;
        auto generation = usbLearningGeneration_;
        auto profileExists = std::any_of(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& profile)
            { return _wcsicmp(profile.id.c_str(), usbLearning_.ProfileId().c_str()) == 0; });
        try
        {
            auto devices = ::DisplaySwitcher::Native::UsbWatcher::EnumerateDevices();
            usbLearning_.Observe(generation, LearningDevices(devices), SteadyMilliseconds(), profileExists);
        }
        catch (...)
        {
            EndUsbLearning(L"读取 USB 设备失败；原绑定保持不变。");
            return;
        }
        if (!usbLearning_.Active())
        {
            EndUsbLearning(profileExists ? L"USB 学习已在 30 秒后超时；原绑定保持不变。" :
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
                EndUsbLearning(L"USB 学习已取消；原绑定保持不变。");
                return;
            }
            auto index = picker.SelectedIndex();
            auto profile = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item)
                { return _wcsicmp(item.id.c_str(), profileId.c_str()) == 0; });
            if (index < 0 || static_cast<size_t>(index) >= candidates.size() || profile == workingProfiles_.end())
            {
                usbLearning_.Cancel(generation);
                EndUsbLearning(L"目标配置或候选已失效；原 USB 绑定保持不变。");
                return;
            }
            auto selected = usbLearning_.Confirm(generation, candidates[static_cast<size_t>(index)].localReference,
                SteadyMilliseconds(), true);
            if (!selected)
            {
                EndUsbLearning(L"USB 学习已超时或结果已失效；原绑定保持不变。");
                return;
            }
            profile->triggerDevices.erase(std::remove_if(profile->triggerDevices.begin(), profile->triggerDevices.end(),
                [](auto const& item) { return item.kind == L"usb"; }), profile->triggerDevices.end());
            profile->triggerDevices.push_back({ L"usb", selected->localReference, selected->displayName });
            wchar_t value[5]{}; swprintf_s(value, L"%04X", selected->vendorId); vendorId_.Text(value);
            swprintf_s(value, L"%04X", selected->productId); productId_.Text(value);
            usbDevices_.SelectedIndex(-1); learnedUsbName_ = selected->displayName;
            auto profileName = profile->name;
            EndUsbLearning(L"已为“" + profileName + L"”选择 USB 设备；保存设置后生效。");
            RebuildProfileEditors();
        });
    }

    void SettingsWindow::EndUsbLearning(std::wstring const& message)
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
            validation_.Text(message);
            validation_.Visibility(Visibility::Visible);
        }
    }

    void SettingsWindow::ShowAbout()
    {
        auto info = ::DisplaySwitcher::Native::PublicAboutInfo();
        auto icon = Image();
        icon.Width(64); icon.Height(64); icon.HorizontalAlignment(HorizontalAlignment::Center);
        icon.Source(Microsoft::UI::Xaml::Media::Imaging::BitmapImage(Windows::Foundation::Uri(L"ms-appx:///AppIcon.ico")));
        auto title = TextBlock(); title.Text(info.applicationName); title.FontSize(22);
        title.FontWeight(Windows::UI::Text::FontWeights::SemiBold()); title.HorizontalAlignment(HorizontalAlignment::Center);
        auto details = TextBlock();
        details.Text(L"版本 " + info.publicVersion + L"\n" + info.architecture + L"\n" + info.protocol);
        details.TextAlignment(TextAlignment::Center); details.HorizontalAlignment(HorizontalAlignment::Center);
        auto notice = TextBlock(); notice.Text(info.buildNotice); notice.TextWrapping(TextWrapping::Wrap);
        notice.TextAlignment(TextAlignment::Center); notice.Opacity(0.72);
        auto project = HyperlinkButton(); project.Content(box_value(L"项目主页"));
        project.NavigateUri(Windows::Foundation::Uri(info.projectUrl)); project.HorizontalAlignment(HorizontalAlignment::Center);
        auto license = HyperlinkButton(); license.Content(box_value(L"MIT 许可证"));
        license.NavigateUri(Windows::Foundation::Uri(info.licenseUrl)); license.HorizontalAlignment(HorizontalAlignment::Center);
        auto notices = HyperlinkButton(); notices.Content(box_value(L"Windows 第三方说明"));
        notices.NavigateUri(Windows::Foundation::Uri(info.thirdPartyNoticesUrl)); notices.HorizontalAlignment(HorizontalAlignment::Center);
        auto links = StackPanel(); links.Orientation(Orientation::Horizontal); links.HorizontalAlignment(HorizontalAlignment::Center);
        links.Children().Append(project); links.Children().Append(license); links.Children().Append(notices);
        auto content = StackPanel(); content.Spacing(10);
        content.Children().Append(icon); content.Children().Append(title); content.Children().Append(details);
        content.Children().Append(links); content.Children().Append(notice);
        auto dialog = ContentDialog(); dialog.Title(box_value(L"关于")); dialog.Content(content);
        dialog.CloseButtonText(L"关闭"); dialog.XamlRoot(Content().XamlRoot()); dialog.ShowAsync();
    }

    void SettingsWindow::LoadDdcMonitors()
    {
        CaptureDisplayEditors();
        try
        {
            ddcMonitors_ = ::DisplaySwitcher::Native::EnumerateDdcMonitors();
            // Old ControlMyMonitor paths often start with the GDI device name. Use that only once
            // when no stable native ID has been saved; later matching is always by native ID.
            for (auto& display : workingDisplays_)
            {
                if (!display.nativeMonitorId.empty() || display.controlMonitorPath.empty()) continue;
                auto found = std::find_if(ddcMonitors_.begin(), ddcMonitors_.end(), [&](auto const& monitor)
                {
                    return display.controlMonitorPath.starts_with(monitor.gdiName);
                });
                if (found != ddcMonitors_.end()) display.nativeMonitorId = found->id;
            }
            RebuildDisplayEditors();
            if (ddcMonitors_.empty() && displayBackend_.SelectedIndex() == 0)
                ShowValidationError(L"没有检测到支持 Windows 物理显示器接口的显示器。");
            else validation_.Visibility(Visibility::Collapsed);
        }
        catch (...) { ShowValidationError(L"读取原生 DDC/CI 显示器失败。"); }
    }

    void SettingsWindow::CaptureDisplayEditors()
    {
        if (displayEditors_.size() != workingDisplays_.size()) return;
        for (size_t index = 0; index < displayEditors_.size(); ++index)
        {
            auto& display = workingDisplays_[index];
            auto const& controls = displayEditors_[index];
            display.name = Trim(controls.name.Text().c_str());
            display.backend = controls.backend.SelectedIndex() == 0 ? L"native_ddc" :
                controls.backend.SelectedIndex() == 1 ? L"control_my_monitor" : L"";
            display.controlMonitorPath = Trim(controls.controlMonitorPath.Text().c_str());
            display.macInput = ParseInteger(controls.macInput.Text().c_str(), 10, 0, 65535).value_or(-1);
            display.readEnabled = controls.readEnabled.IsOn();
            display.brightnessEnabled = controls.brightnessEnabled.IsOn();
            display.contrastEnabled = controls.contrastEnabled.IsOn();
            display.volumeEnabled = controls.volumeEnabled.IsOn();
            auto selected = controls.nativeMonitor.SelectedIndex();
            if (selected >= 0 && static_cast<size_t>(selected) < controls.nativeMonitorIds.size())
                display.nativeMonitorId = controls.nativeMonitorIds[static_cast<size_t>(selected)];
            else display.nativeMonitorId.clear();
        }
    }

    void SettingsWindow::RebuildDisplayEditors()
    {
        if (!displayEditorsPanel_) return;
        displayEditorsPanel_.Children().Clear();
        displayEditors_.clear();

        for (size_t index = 0; index < workingDisplays_.size(); ++index)
        {
            auto const display = workingDisplays_[index];
            DisplayEditorControls controls;
            controls.id = display.id;
            controls.name = TextBox(); Header(controls.name, L"名称"); controls.name.Text(display.name);
            controls.backend = ComboBox(); Header(controls.backend, L"硬件 DDC 后端");
            controls.backend.Items().Append(box_value(L"Windows 原生 Dxva2"));
            controls.backend.Items().Append(box_value(L"ControlMyMonitor 回退"));
            controls.backend.SelectedIndex(display.backend == L"control_my_monitor" ? 1 : 0);
            controls.nativeMonitor = ComboBox(); Header(controls.nativeMonitor, L"Windows DDC/CI 显示器");
            controls.nativeMonitor.PlaceholderText(L"请选择显示器");
            controls.nativeMonitor.HorizontalAlignment(HorizontalAlignment::Stretch);

            int selectedMonitor = -1;
            auto connected = ::DisplaySwitcher::Native::FindDdcMonitorById(ddcMonitors_, display.nativeMonitorId);
            if (!display.nativeMonitorId.empty() && !connected)
            {
                controls.nativeMonitor.Items().Append(box_value(L"当前未连接（保留原配置）"));
                controls.nativeMonitorIds.push_back(display.nativeMonitorId);
                selectedMonitor = 0;
            }
            for (auto const& monitor : ddcMonitors_)
            {
                controls.nativeMonitor.Items().Append(box_value(monitor.displayName));
                controls.nativeMonitorIds.push_back(monitor.id);
                if (_wcsicmp(monitor.id.c_str(), display.nativeMonitorId.c_str()) == 0)
                    selectedMonitor = static_cast<int>(controls.nativeMonitorIds.size() - 1);
            }
            controls.nativeMonitor.SelectedIndex(selectedMonitor);
            controls.nativeFields = controls.nativeMonitor;

            controls.controlMonitorPath = TextBox(); Header(controls.controlMonitorPath, L"ControlMyMonitor 设备路径");
            controls.controlMonitorPath.Text(display.controlMonitorPath);
            controls.controlMyMonitorFields = controls.controlMonitorPath;
            controls.macInput = TextBox(); Header(controls.macInput, L"旧版单对端输入源编号（兼容）"); controls.macInput.MaxLength(5);
            controls.macInput.Text(display.macInput >= 0 ? std::to_wstring(display.macInput) : L"");
            controls.readEnabled = ToggleSwitch(); Header(controls.readEnabled, L"允许读取硬件 DDC 状态");
            controls.readEnabled.IsOn(display.readEnabled);
            controls.brightnessEnabled = ToggleSwitch(); Header(controls.brightnessEnabled, L"启用亮度（VCP 0x10）");
            controls.brightnessEnabled.IsOn(display.brightnessEnabled);
            controls.contrastEnabled = ToggleSwitch(); Header(controls.contrastEnabled, L"启用对比度（VCP 0x12）");
            controls.contrastEnabled.IsOn(display.contrastEnabled);
            controls.volumeEnabled = ToggleSwitch(); Header(controls.volumeEnabled, L"启用音量（VCP 0x62）");
            controls.volumeEnabled.IsOn(display.volumeEnabled);
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
            controls.status = TextBlock(); controls.status.Text(L"状态尚未读取"); controls.status.Opacity(0.72);
            controls.status.TextWrapping(TextWrapping::Wrap);

            auto read = Button(); read.Content(box_value(L"读取三项"));
            read.Click([this, id = display.id](auto const&, auto const&) { ReadDdc(id); });
            auto controlRow = [&](wchar_t const* name, ::DisplaySwitcher::Native::DdcVcpCode code, Slider const& slider,
                ToggleSwitch const& enabled)
            {
                auto apply = Button(); apply.Content(box_value(L"应用")); apply.VerticalAlignment(VerticalAlignment::Center);
                apply.Click([this, id = display.id, code, slider](auto const&, auto const&)
                { WriteDdc(id, code, static_cast<int>(std::lround(slider.Value()))); });
                auto panel = StackPanel(); panel.Spacing(6);
                auto label = TextBlock(); label.Text(name); label.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
                panel.Children().Append(label); panel.Children().Append(CreateTwoColumn(slider, apply));
                enabled.Toggled([slider, apply](auto const& sender, auto const&)
                {
                    auto on = sender.template as<ToggleSwitch>().IsOn(); slider.IsEnabled(on); apply.IsEnabled(on);
                });
                slider.IsEnabled(enabled.IsOn()); apply.IsEnabled(enabled.IsOn());
                return panel;
            };
            auto brightnessRow = controlRow(L"亮度", ::DisplaySwitcher::Native::DdcVcpCode::Brightness,
                controls.brightness, controls.brightnessEnabled);
            auto contrastRow = controlRow(L"对比度", ::DisplaySwitcher::Native::DdcVcpCode::Contrast,
                controls.contrast, controls.contrastEnabled);
            auto volumeRow = controlRow(L"音量", ::DisplaySwitcher::Native::DdcVcpCode::Volume,
                controls.volume, controls.volumeEnabled);

            auto up = Button(); up.Content(box_value(L"上移")); up.IsEnabled(index > 0);
            up.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found && *found > 0) std::swap(workingDisplays_[*found], workingDisplays_[*found - 1]);
                RebuildDisplayEditors();
                RebuildProfileEditors();
            });
            auto down = Button(); down.Content(box_value(L"下移")); down.IsEnabled(index + 1 < workingDisplays_.size());
            down.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found && *found + 1 < workingDisplays_.size()) std::swap(workingDisplays_[*found], workingDisplays_[*found + 1]);
                RebuildDisplayEditors();
                RebuildProfileEditors();
            });
            auto remove = Button(); remove.Content(box_value(L"移除"));
            remove.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found) workingDisplays_.erase(workingDisplays_.begin() + static_cast<ptrdiff_t>(*found));
                RebuildDisplayEditors();
                RebuildProfileEditors();
            });
            auto buttons = StackPanel(); buttons.Orientation(Orientation::Horizontal); buttons.Spacing(8);
            buttons.Children().Append(up); buttons.Children().Append(down); buttons.Children().Append(remove);

            auto fields = StackPanel(); fields.Spacing(12);
            fields.Children().Append(controls.name); fields.Children().Append(controls.backend);
            fields.Children().Append(controls.nativeMonitor);
            fields.Children().Append(controls.controlMonitorPath); fields.Children().Append(controls.macInput);
            fields.Children().Append(controls.readEnabled);
            fields.Children().Append(CreateTwoColumn(controls.brightnessEnabled, controls.contrastEnabled, 0));
            fields.Children().Append(controls.volumeEnabled);
            fields.Children().Append(brightnessRow); fields.Children().Append(contrastRow); fields.Children().Append(volumeRow);
            fields.Children().Append(CreateTwoColumn(controls.status, read));
            fields.Children().Append(buttons);
            displayEditorsPanel_.Children().Append(CreateCard(fields));
            displayEditors_.push_back(std::move(controls));
            displayEditors_.back().backend.SelectionChanged([this](auto const&, auto const&) { UpdateDisplayBackendVisibility(); });
        }
        UpdateDisplayBackendVisibility();
    }

    void SettingsWindow::CaptureProfileEditors()
    {
        if (profileEditors_.size() != workingProfiles_.size()) return;
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
            profile->displayInputs.clear();
            for (auto const& mapping : controls.mappings)
            {
                auto text = Trim(mapping.peerInput.Text().c_str());
                if (text.empty()) continue;
                profile->displayInputs.push_back({ mapping.displayId, ParseInteger(text, 10, 0, 65535).value_or(-1) });
            }
        }
    }

    void SettingsWindow::RebuildProfileEditors()
    {
        if (!profileEditorsPanel_) return;
        profileEditorsPanel_.Children().Clear(); profileEditors_.clear();
        for (size_t index = 0; index < workingProfiles_.size(); ++index)
        {
            auto const profile = workingProfiles_[index];
            ProfileEditorControls controls; controls.id = profile.id;
            controls.name = TextBox(); Header(controls.name, L"配置名称"); controls.name.Text(profile.name); controls.name.MaxLength(32);
            controls.enabled = ToggleSwitch(); Header(controls.enabled, L"启用此协同配置"); controls.enabled.IsOn(profile.coordinationEnabled);
            controls.peerHost = TextBox(); Header(controls.peerHost, L"对端 IP 或主机名"); controls.peerHost.Text(profile.peerHost); controls.peerHost.MaxLength(253);
            controls.peerPort = TextBox(); Header(controls.peerPort, L"对端端口"); controls.peerPort.Text(std::to_wstring(profile.peerPort)); controls.peerPort.MaxLength(5);
            controls.pairingCode = PasswordBox(); Header(controls.pairingCode, L"配对码"); controls.pairingCode.Password(profile.pairingCode);
            controls.pairingCode.PlaceholderText(L"NFC 后 8–128 个 UTF-8 字节");

            auto fields = StackPanel(); fields.Spacing(12);
            fields.Children().Append(controls.name); fields.Children().Append(controls.enabled);
            fields.Children().Append(CreateTwoColumn(controls.peerHost, controls.peerPort, 160));
            fields.Children().Append(controls.pairingCode);
            fields.Children().Append(CreateSubheading(L"显示器输入映射"));

            auto addMapping = [&](std::wstring const& displayId, std::wstring const& label, bool unavailable)
            {
                ProfileMappingControls mapping; mapping.displayId = displayId; mapping.peerInput = TextBox();
                Header(mapping.peerInput, label.c_str()); mapping.peerInput.MaxLength(5);
                auto existing = std::find_if(profile.displayInputs.begin(), profile.displayInputs.end(), [&](auto const& item)
                { return _wcsicmp(item.displayId.c_str(), displayId.c_str()) == 0; });
                if (existing != profile.displayInputs.end()) mapping.peerInput.Text(std::to_wstring(existing->peerInput));
                if (unavailable) mapping.peerInput.Description(box_value(L"该显示器已移除；映射保留但不会自动绑定到其他显示器。"));
                fields.Children().Append(mapping.peerInput); controls.mappings.push_back(std::move(mapping));
            };
            for (auto const& display : workingDisplays_) addMapping(display.id, display.name + L" · 对端输入源", false);
            for (auto const& mapping : profile.displayInputs)
                if (std::none_of(workingDisplays_.begin(), workingDisplays_.end(), [&](auto const& display)
                { return _wcsicmp(display.id.c_str(), mapping.displayId.c_str()) == 0; }))
                    addMapping(mapping.displayId, L"已移除显示器 · 对端输入源", true);
            if (workingDisplays_.empty() && profile.displayInputs.empty())
            {
                auto empty = TextBlock(); empty.Text(L"尚未添加显示器。此配置不会执行显示器写入。"); empty.Opacity(0.72);
                fields.Children().Append(empty);
            }

            auto triggerSummary = TextBlock();
            triggerSummary.Text(profile.triggerDevices.empty() ? L"未引用本机触发设备" : L"已引用 " + std::to_wstring(profile.triggerDevices.size()) + L" 个本机触发设备");
            triggerSummary.Opacity(0.72); fields.Children().Append(triggerSummary);
            auto learnUsb = Button(); learnUsb.Content(box_value(L"学习 USB 设备…"));
            learnUsb.Click([this, id = profile.id](auto const&, auto const&) { StartUsbLearning(id); });
            auto clearTriggers = Button(); clearTriggers.Content(box_value(L"清除触发引用"));
            clearTriggers.Click([this, id = profile.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                auto target = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item) { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
                if (target != workingProfiles_.end()) target->triggerDevices.clear(); RebuildProfileEditors();
            });
            auto detect = Button(); detect.Content(box_value(L"检测")); detect.Click([this, id = profile.id](auto const&, auto const&) { DetectProfile(id); });
            auto up = Button(); up.Content(box_value(L"上移")); up.IsEnabled(index > 0);
            up.Click([this, id = profile.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                auto found = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item) { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
                if (found != workingProfiles_.end() && found != workingProfiles_.begin()) std::iter_swap(found, found - 1); RebuildProfileEditors();
            });
            auto down = Button(); down.Content(box_value(L"下移")); down.IsEnabled(index + 1 < workingProfiles_.size());
            down.Click([this, id = profile.id](auto const&, auto const&)
            {
                CaptureProfileEditors();
                auto found = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item) { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
                if (found != workingProfiles_.end() && found + 1 != workingProfiles_.end()) std::iter_swap(found, found + 1); RebuildProfileEditors();
            });
            auto remove = Button(); remove.Content(box_value(L"删除")); remove.IsEnabled(workingProfiles_.size() > 1);
            remove.Click([this, id = profile.id](auto const&, auto const&) { RemoveProfile(id); });
            auto buttons = StackPanel(); buttons.Orientation(Orientation::Horizontal); buttons.Spacing(8);
            buttons.Children().Append(detect); buttons.Children().Append(learnUsb); buttons.Children().Append(clearTriggers);
            buttons.Children().Append(up); buttons.Children().Append(down); buttons.Children().Append(remove);
            fields.Children().Append(buttons); profileEditorsPanel_.Children().Append(CreateCard(fields));
            profileEditors_.push_back(std::move(controls));
        }
    }

    void SettingsWindow::RemoveProfile(std::wstring const& id)
    {
        CaptureProfileEditors();
        if (usbLearning_.Active() && _wcsicmp(usbLearning_.ProfileId().c_str(), id.c_str()) == 0)
            EndUsbLearning(L"目标配置已删除；原 USB 绑定保持不变。");
        if (workingProfiles_.size() <= 1) { ShowValidationError(L"至少保留一个协同配置。"); return; }
        auto found = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& item) { return _wcsicmp(item.id.c_str(), id.c_str()) == 0; });
        if (found == workingProfiles_.end()) return;
        if (!found->coordinationEnabled)
        {
            workingProfiles_.erase(found); RebuildProfileEditors(); return;
        }
        auto dialog = ContentDialog(); dialog.Title(box_value(L"删除已启用配置？"));
        dialog.Content(box_value(L"删除后会取消该配置尚未完成的本机操作。"));
        dialog.PrimaryButtonText(L"删除"); dialog.CloseButtonText(L"取消"); dialog.DefaultButton(ContentDialogButton::Close);
        dialog.XamlRoot(Content().XamlRoot());
        dialog.ShowAsync().Completed([this, id, dialog](auto const& operation, auto const& status)
        {
            if (status != Windows::Foundation::AsyncStatus::Completed || operation.GetResults() != ContentDialogResult::Primary) return;
            auto item = std::find_if(workingProfiles_.begin(), workingProfiles_.end(), [&](auto const& value) { return _wcsicmp(value.id.c_str(), id.c_str()) == 0; });
            if (item != workingProfiles_.end() && workingProfiles_.size() > 1) workingProfiles_.erase(item);
            RebuildProfileEditors();
        });
    }

    void SettingsWindow::DetectProfile(std::wstring const& id)
    {
        CaptureDisplayEditors(); CaptureProfileEditors();
        auto config = original_; config.displays = workingDisplays_; config.collaborationProfiles = workingProfiles_;
        auto result = config.InspectProfile(id);
        if (config.displayConfigurationSafeMode) result.problems.push_back(L"配置处于安全状态，需成功保存后解除");
        auto selection = config.SelectProfileDisplays(id);
        for (auto const& display : selection.mappedDisplays)
        {
            auto backend = display.backend.empty() ? config.displayControlBackend : display.backend;
            if (backend == L"native_ddc")
            {
                if (display.nativeMonitorId.empty() || !::DisplaySwitcher::Native::FindDdcMonitorById(ddcMonitors_, display.nativeMonitorId))
                    result.problems.push_back(display.name + L"的原生硬件 DDC/CI 后端当前不可用");
            }
            else if (backend == L"control_my_monitor")
            {
                if (config.controlMyMonitorPath.empty()) result.problems.push_back(L"未配置 ControlMyMonitor 程序路径");
                if (display.controlMonitorPath.empty()) result.problems.push_back(display.name + L"缺少 ControlMyMonitor 设备路径");
            }
            else result.problems.push_back(display.name + L"未选择显示器控制后端");
        }
        result.complete = result.problems.empty() && !result.endpointConfirmationRequired;
        if (result.complete) { validation_.Text(L"本机检查通过；未发送网络消息，未执行 DDC、USB、蓝牙或唤醒操作。"); validation_.Visibility(Visibility::Visible); return; }
        std::wstring message = L"本机检查未通过：";
        for (size_t index = 0; index < result.problems.size(); ++index) { if (index) message += L"；"; message += result.problems[index]; }
        ShowValidationError(message);
    }

    void SettingsWindow::UpdateDisplayBackendVisibility()
    {
        if (!nativeDdcPanel_ || !controlMyMonitorPanel_) return;
        auto selected = displayBackend_.SelectedIndex();
        auto hasNative = selected == 0;
        auto hasControlMyMonitor = selected == 1;
        for (auto const& editor : displayEditors_)
        {
            auto backend = editor.backend.SelectedIndex();
            editor.nativeFields.Visibility(backend == 0 ? Visibility::Visible : Visibility::Collapsed);
            editor.controlMyMonitorFields.Visibility(backend == 1 ? Visibility::Visible : Visibility::Collapsed);
            hasNative = hasNative || backend == 0;
            hasControlMyMonitor = hasControlMyMonitor || backend == 1;
        }
        nativeDdcPanel_.Visibility(hasNative ? Visibility::Visible : Visibility::Collapsed);
        controlMyMonitorPanel_.Visibility(hasControlMyMonitor ? Visibility::Visible : Visibility::Collapsed);
    }

    ::DisplaySwitcher::Native::AppConfig SettingsWindow::WorkingDdcConfig()
    {
        CaptureDisplayEditors();
        auto config = original_;
        config.displayControlBackend = displayBackend_.SelectedIndex() == 1 ? L"control_my_monitor" : L"native_ddc";
        config.controlMyMonitorPath = Trim(controlMyMonitor_.Text().c_str());
        config.displays = workingDisplays_;
        return config;
    }

    void SettingsWindow::ReadDdc(std::wstring const& displayId)
    {
        if (!readDdc_) { ShowValidationError(L"硬件 DDC 读取服务不可用。"); return; }
        auto config = WorkingDdcConfig();
        auto token = ddcCancellation_.Begin();
        auto operation = readDdc_;
        auto dispatcher = DispatcherQueue();
        auto strong = get_strong();
        validation_.Text(L"正在读取硬件 DDC 状态…"); validation_.Visibility(Visibility::Visible);
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
        if (!writeDdc_) { ShowValidationError(L"硬件 DDC 写入服务不可用。"); return; }
        auto config = WorkingDdcConfig();
        auto token = ddcCancellation_.Begin();
        auto operation = writeDdc_;
        auto linkAll = linkAllDisplays_.IsOn();
        auto dispatcher = DispatcherQueue();
        auto strong = get_strong();
        validation_.Text(L"正在提交硬件 DDC 设置…"); validation_.Visibility(Visibility::Visible);
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
                ShowValidationError(L"无法保存 DDC 估计缓存；当前进程已进入安全状态。");
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
            if (failed != result.items.end())
                editor.status.Text(failed->message.empty() ? L"硬件 DDC 暂时不可用或不支持" : failed->message);
            else editor.status.Text(write ? L"硬件 DDC 写入成功" : L"硬件 DDC 回读成功");
        }
        auto failures = std::count_if(result.items.begin(), result.items.end(), [](auto const& item) { return !item.success || !item.trusted; });
        if (result.items.empty()) ShowValidationError(L"未执行 DDC 操作：功能可能已关闭或显示器配置不完整。");
        else if (failures)
        {
            auto first = std::find_if(result.items.begin(), result.items.end(), [](auto const& item) { return !item.success || !item.trusted; });
            ShowValidationError((write ? L"部分硬件 DDC 写入失败：" : L"部分硬件 DDC 读取失败：")
                + (first->message.empty() ? L"后端暂时不可用或不支持该功能" : first->message));
        }
        else
        {
            validation_.Text(write ? L"硬件 DDC 设置已提交。" : L"硬件 DDC 状态已读取。");
            validation_.Visibility(Visibility::Visible);
        }
    }

    void SettingsWindow::Save()
    {
        ddcCancellation_.Cancel();
        EndUsbLearning();
        auto vendorText = Trim(vendorId_.Text().c_str()); auto productText = Trim(productId_.Text().c_str());
        auto vendor = ParseInteger(vendorText, 16, 0, 0xFFFF); auto product = ParseInteger(productText, 16, 0, 0xFFFF);
        if ((usbAutomation_.IsOn() || !vendorText.empty() || !productText.empty()) && (!vendor || !product))
        { tabs_.SelectedIndex(1); ShowValidationError(L"USB Vendor ID 和 Product ID 必须同时填写为 4 位十六进制。"); return; }
        CaptureProfileEditors();
        std::set<std::wstring> profileNames;
        for (auto& profile : workingProfiles_)
        {
            auto normalizedName = profile.name; std::transform(normalizedName.begin(), normalizedName.end(), normalizedName.begin(), towlower);
            if (profile.name.empty() || !profileNames.insert(normalizedName).second)
            { tabs_.SelectedIndex(2); ShowValidationError(L"协同配置名称不能为空，且忽略大小写后必须唯一。"); return; }
            if (profile.peerPort < 1 || profile.peerPort > 65535)
            { tabs_.SelectedIndex(2); ShowValidationError(profile.name + L"的对端端口必须为 1–65535。"); return; }
            if (!profile.pairingCode.empty() && !::DisplaySwitcher::Native::AppConfig::IsValidPairingCode(profile.pairingCode))
            { tabs_.SelectedIndex(2); ShowValidationError(profile.name + L"的配对码在 NFC 规范化后必须为 8–128 个 UTF-8 字节。"); return; }
            profile.pairingCode = ::DisplaySwitcher::Native::AppConfig::NormalizeNfc(profile.pairingCode);
            for (auto const& mapping : profile.displayInputs)
                if (mapping.peerInput < 0 || mapping.peerInput > 65535)
                { tabs_.SelectedIndex(2); ShowValidationError(profile.name + L"包含无效的显示器输入源编号。"); return; }
        }
        CaptureDisplayEditors();
        auto backendIndex = displayBackend_.SelectedIndex();
        if (usbAutomation_.IsOn() && workingDisplays_.empty())
        { tabs_.SelectedIndex(3); ShowValidationError(L"启用 USB 自动切换前，请先完成显示器配置。"); return; }
        auto controlMyMonitorPath = Trim(controlMyMonitor_.Text().c_str());
        auto anyControlMyMonitor = std::any_of(workingDisplays_.begin(), workingDisplays_.end(), [](auto const& display)
        { return display.backend == L"control_my_monitor"; });
        if (anyControlMyMonitor && controlMyMonitorPath.empty())
        { tabs_.SelectedIndex(3); ShowValidationError(L"使用 ControlMyMonitor 时，请填写程序路径。"); return; }
        std::set<std::wstring> hardwareIds;
        for (auto const& display : workingDisplays_)
        {
            if (display.name.empty())
            { tabs_.SelectedIndex(3); ShowValidationError(L"每台显示器都需要填写名称。"); return; }
            if (display.macInput < 0 || display.macInput > 65535)
            { tabs_.SelectedIndex(3); ShowValidationError(display.name + L"的旧版单对端输入源必须为 0–65535 的整数。"); return; }
            if (display.backend != L"native_ddc" && display.backend != L"control_my_monitor")
            { tabs_.SelectedIndex(3); ShowValidationError(display.name + L"尚未选择硬件 DDC 后端。"); return; }
            auto hardwareId = display.backend == L"native_ddc" ? display.nativeMonitorId : display.controlMonitorPath;
            if (hardwareId.empty())
            {
                tabs_.SelectedIndex(3);
                ShowValidationError(display.name + (display.backend == L"native_ddc" ? L"尚未选择 DDC/CI 显示器。" : L"尚未填写设备路径。"));
                return;
            }
            hardwareId = display.backend + L":" + hardwareId;
            std::transform(hardwareId.begin(), hardwareId.end(), hardwareId.begin(), towlower);
            if (!hardwareIds.insert(hardwareId).second)
            { tabs_.SelectedIndex(3); ShowValidationError(L"不能让多项配置指向同一台物理显示器。"); return; }
        }
        auto result = original_; result.usbAutomationEnabled = usbAutomation_.IsOn();
        result.usbVendorId = vendor.value_or(-1); result.usbProductId = product.value_or(-1); auto selected = usbDevices_.SelectedIndex();
        if (learnedUsbName_) result.usbName = *learnedUsbName_;
        else if (selected >= 0 && static_cast<size_t>(selected) < devices_.size()) result.usbName = devices_[selected].name;
        else if (!vendor || !product) result.usbName.clear();
        result.displayControlBackend = backendIndex == 0 ? L"native_ddc" : backendIndex == 1 ? L"control_my_monitor" : L"";
        result.controlMyMonitorPath = controlMyMonitorPath; result.displays = workingDisplays_;
        result.collaborationProfiles = workingProfiles_;
        result.coordinationEnabled = false; result.peerHost.clear(); result.pairingCode.clear(); result.port = result.peerPort = 49731;
        if (result.collaborationProfiles.size() == 1)
        {
            auto const& profile = result.collaborationProfiles.front();
            result.coordinationEnabled = profile.coordinationEnabled; result.peerHost = profile.peerHost;
            result.pairingCode = profile.pairingCode; result.port = result.peerPort = profile.peerPort;
            for (auto& display : result.displays)
            {
                display.macInput = -1;
                auto mapping = std::find_if(profile.displayInputs.begin(), profile.displayInputs.end(), [&](auto const& item)
                { return _wcsicmp(item.displayId.c_str(), display.id.c_str()) == 0; });
                if (mapping != profile.displayInputs.end()) display.macInput = mapping->peerInput;
            }
        }
        else for (auto& display : result.displays) display.macInput = -1;
        result.displayConfigurationSafeMode = false; result.startWithWindows = autoStart_.IsOn();
        if (!saved_ || !saved_(result))
        {
            ShowValidationError(L"设置未保存；旧配置已保留，自动协同和硬件操作已安全停用。");
            return;
        }
        original_ = result; appWindow_.Hide();
    }

    void SettingsWindow::ShowValidationError(std::wstring const& message)
    {
        validation_.Text(message); validation_.Visibility(Visibility::Visible);
    }
}
