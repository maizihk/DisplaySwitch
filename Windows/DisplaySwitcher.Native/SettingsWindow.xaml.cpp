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
}

namespace winrt::DisplaySwitcher::Native::implementation
{
    SettingsWindow::SettingsWindow() { InitializeComponent(); }

    void SettingsWindow::Initialize(::DisplaySwitcher::Native::AppConfig const& config,
        std::function<void(::DisplaySwitcher::Native::AppConfig const&)> saved,
        std::function<void()> closed)
    {
        if (initialized_) return;
        initialized_ = true;
        original_ = config; saved_ = std::move(saved); closed_ = std::move(closed);
        Title(L"常规");
        try { SystemBackdrop(MicaBackdrop()); } catch (...) {}
        auto content = BuildContent();
        Content(content);
        if (auto root = content.try_as<FrameworkElement>())
            root.ActualThemeChanged([this](auto const&, auto const&) { ApplyTitleBarTheme(); });
        LoadValues(config); ResizeAndCenter(); ApplyTitleBarTheme();
        Closed([this](auto const&, auto const&) { if (closed_) closed_(); });
        LoadUsbDevices();
        LoadDdcMonitors();
    }

    UIElement SettingsWindow::BuildContent()
    {
        validation_ = TextBlock(); validation_.Foreground(SolidColorBrush(Windows::UI::Color{ 255, 196, 43, 28 }));
        validation_.TextWrapping(TextWrapping::Wrap); validation_.Visibility(Visibility::Collapsed);
        usbAutomation_ = ToggleSwitch(); Header(usbAutomation_, L"启用 USB 自动切换");
        coordination_ = ToggleSwitch(); Header(coordination_, L"启用 Mac / Windows 网络协同");
        peerHost_ = TextBox(); Header(peerHost_, L"Mac IP 或主机名"); peerHost_.PlaceholderText(L"请输入目标 Mac 地址");
        port_ = TextBox(); Header(port_, L"UDP 端口"); port_.PlaceholderText(L"49731");
        pairingCode_ = PasswordBox(); Header(pairingCode_, L"配对码"); pairingCode_.PlaceholderText(L"至少 8 位，两端保持一致");
        usbDevices_ = ComboBox(); Header(usbDevices_, L"当前 USB 设备"); usbDevices_.HorizontalAlignment(HorizontalAlignment::Stretch);
        vendorId_ = TextBox(); Header(vendorId_, L"Vendor ID"); vendorId_.PlaceholderText(L"4 位十六进制"); vendorId_.MaxLength(4);
        productId_ = TextBox(); Header(productId_, L"Product ID"); productId_.PlaceholderText(L"4 位十六进制"); productId_.MaxLength(4);
        displayBackend_ = ComboBox(); Header(displayBackend_, L"显示器控制方式"); displayBackend_.HorizontalAlignment(HorizontalAlignment::Stretch);
        displayBackend_.PlaceholderText(L"请选择控制方式");
        displayBackend_.Items().Append(box_value(L"Windows 原生 DDC/CI（推荐）"));
        displayBackend_.Items().Append(box_value(L"ControlMyMonitor"));
        displayBackend_.SelectionChanged([this](auto const&, auto const&) { UpdateDisplayBackendVisibility(); });
        controlMyMonitor_ = TextBox(); Header(controlMyMonitor_, L"ControlMyMonitor 路径");
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
        commonTab.Content(CreatePage({ CreateSection(L"常规", { autoStart_, commonHint }) }));

        auto refresh = Button(); refresh.Content(box_value(L"重新读取")); refresh.VerticalAlignment(VerticalAlignment::Bottom);
        refresh.Click([this](auto const&, auto const&) { LoadUsbDevices(); });
        auto usbTab = TabViewItem(); usbTab.IsClosable(false); usbTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        usbTab.Header(CreateTabHeader(L"\uE88E", L"USB 切换"));
        auto usbHint = TextBlock(); usbHint.Text(L"选择用于判断键鼠归属的 USB Hub。协同关闭时，USB 离开 Windows 后将直接切换到 Mac。");
        usbHint.TextWrapping(TextWrapping::Wrap); usbHint.Opacity(0.72);
        usbTab.Content(CreatePage({ CreateSection(L"USB 触发设备", {
            usbAutomation_, CreateTwoColumn(usbDevices_, refresh), CreateTwoColumn(vendorId_, productId_), usbHint }) }));

        auto peerTab = TabViewItem(); peerTab.IsClosable(false); peerTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        peerTab.Header(CreateTabHeader(L"\uE968", L"双端协同"));
        auto peerStatus = StackPanel(); peerStatus.Orientation(Orientation::Horizontal); peerStatus.Spacing(8);
        connectionDot_ = TextBlock(); connectionDot_.Text(L"●"); connectionDot_.FontSize(16);
        connectionStatus_ = TextBlock(); connectionStatus_.VerticalAlignment(VerticalAlignment::Center);
        peerStatus.Children().Append(connectionDot_); peerStatus.Children().Append(connectionStatus_);
        SetConnectionStatus(L"协同未启用", false);
        auto peerHint = TextBlock(); peerHint.Text(L"两端使用相同端口和配对码；确认 USB 已接入目标电脑后再切换显示器。");
        peerHint.TextWrapping(TextWrapping::Wrap); peerHint.Opacity(0.72);
        peerTab.Content(CreatePage({ CreateSection(L"双端协同", {
            peerStatus, coordination_, CreateTwoColumn(peerHost_, port_, 160), pairingCode_, peerHint }) }));

        auto displayTab = TabViewItem(); displayTab.IsClosable(false); displayTab.HorizontalContentAlignment(HorizontalAlignment::Center);
        displayTab.Header(CreateTabHeader(L"\uE7F4", L"显示器"));
        auto displayHint = TextBlock(); displayHint.Text(L"首次使用时请选择控制方式、显示器和 Mac 输入源；未完成配置前不会执行切屏。");
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
            CaptureDisplayEditors();
            workingDisplays_.push_back(::DisplaySwitcher::Native::CreateDisplayConfig(
                L"显示器 " + std::to_wstring(workingDisplays_.size() + 1)));
            RebuildDisplayEditors();
        });
        displayEditorsPanel_ = StackPanel(); displayEditorsPanel_.Spacing(14);
        displayTab.Content(CreatePage({ CreateSection(L"显示器控制", { displayHint, displayBackend_, nativeDdcPanel_,
            controlMyMonitorPanel_, addDisplay, displayEditorsPanel_ }) }));

        tabs_.TabItems().Append(commonTab); tabs_.TabItems().Append(usbTab);
        tabs_.TabItems().Append(peerTab); tabs_.TabItems().Append(displayTab);
        tabs_.SelectedIndex(0);
        tabs_.SelectionChanged([this](auto const&, auto const&)
        {
            static constexpr wchar_t const* titles[]{ L"常规", L"USB 切换", L"双端协同", L"显示器" };
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
        auto cancel = Button(); cancel.Content(box_value(L"取消")); cancel.Click([this](auto const&, auto const&) { appWindow_.Hide(); });
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
    void SettingsWindow::CloseForExit() { Close(); }

    void SettingsWindow::SetConnectionStatus(std::wstring const& status, bool connected)
    {
        if (!connectionStatus_ || !connectionDot_) return;
        connectionStatus_.Text(status);
        auto color = connected ? Windows::UI::Color{ 255, 16, 124, 16 } : Windows::UI::Color{ 255, 96, 96, 96 };
        connectionDot_.Foreground(SolidColorBrush(color));
    }

    void SettingsWindow::LoadValues(::DisplaySwitcher::Native::AppConfig const& config)
    {
        usbAutomation_.IsOn(config.usbAutomationEnabled); coordination_.IsOn(config.coordinationEnabled);
        peerHost_.Text(config.peerHost); port_.Text(std::to_wstring(config.port)); pairingCode_.Password(config.pairingCode);
        auto loadHex = [](TextBox const& box, int number)
        {
            if (number < 0 || number > 0xFFFF) { box.Text(L""); return; }
            wchar_t value[5]{}; swprintf_s(value, L"%04X", number); box.Text(value);
        };
        loadHex(vendorId_, config.usbVendorId); loadHex(productId_, config.usbProductId);
        controlMyMonitor_.Text(config.controlMyMonitorPath);
        workingDisplays_ = config.displays;
        RebuildDisplayEditors();
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
            display.controlMonitorPath = Trim(controls.controlMonitorPath.Text().c_str());
            display.macInput = ParseInteger(controls.macInput.Text().c_str(), 10, 0, 65535).value_or(-1);
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
            controls.macInput = TextBox(); Header(controls.macInput, L"Mac 输入源编号"); controls.macInput.MaxLength(5);
            controls.macInput.Text(display.macInput >= 0 ? std::to_wstring(display.macInput) : L"");

            auto up = Button(); up.Content(box_value(L"上移")); up.IsEnabled(index > 0);
            up.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found && *found > 0) std::swap(workingDisplays_[*found], workingDisplays_[*found - 1]);
                RebuildDisplayEditors();
            });
            auto down = Button(); down.Content(box_value(L"下移")); down.IsEnabled(index + 1 < workingDisplays_.size());
            down.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found && *found + 1 < workingDisplays_.size()) std::swap(workingDisplays_[*found], workingDisplays_[*found + 1]);
                RebuildDisplayEditors();
            });
            auto remove = Button(); remove.Content(box_value(L"移除"));
            remove.Click([this, id = display.id](auto const&, auto const&)
            {
                CaptureDisplayEditors();
                auto found = ::DisplaySwitcher::Native::FindDisplayById(workingDisplays_, id);
                if (found) workingDisplays_.erase(workingDisplays_.begin() + static_cast<ptrdiff_t>(*found));
                RebuildDisplayEditors();
            });
            auto buttons = StackPanel(); buttons.Orientation(Orientation::Horizontal); buttons.Spacing(8);
            buttons.Children().Append(up); buttons.Children().Append(down); buttons.Children().Append(remove);

            auto fields = StackPanel(); fields.Spacing(12);
            fields.Children().Append(controls.name); fields.Children().Append(controls.nativeMonitor);
            fields.Children().Append(controls.controlMonitorPath); fields.Children().Append(controls.macInput);
            fields.Children().Append(buttons);
            displayEditorsPanel_.Children().Append(CreateCard(fields));
            displayEditors_.push_back(std::move(controls));
        }
        UpdateDisplayBackendVisibility();
    }

    void SettingsWindow::UpdateDisplayBackendVisibility()
    {
        if (!nativeDdcPanel_ || !controlMyMonitorPanel_) return;
        auto selected = displayBackend_.SelectedIndex();
        nativeDdcPanel_.Visibility(selected == 0 ? Visibility::Visible : Visibility::Collapsed);
        controlMyMonitorPanel_.Visibility(selected == 1 ? Visibility::Visible : Visibility::Collapsed);
        for (auto const& editor : displayEditors_)
        {
            editor.nativeFields.Visibility(selected == 0 ? Visibility::Visible : Visibility::Collapsed);
            editor.controlMyMonitorFields.Visibility(selected == 1 ? Visibility::Visible : Visibility::Collapsed);
        }
    }

    void SettingsWindow::Save()
    {
        auto vendorText = Trim(vendorId_.Text().c_str()); auto productText = Trim(productId_.Text().c_str());
        auto vendor = ParseInteger(vendorText, 16, 0, 0xFFFF); auto product = ParseInteger(productText, 16, 0, 0xFFFF);
        if ((usbAutomation_.IsOn() || !vendorText.empty() || !productText.empty()) && (!vendor || !product))
        { tabs_.SelectedIndex(1); ShowValidationError(L"USB Vendor ID 和 Product ID 必须同时填写为 4 位十六进制。"); return; }
        auto host = Trim(peerHost_.Text().c_str()); auto code = Trim(pairingCode_.Password().c_str());
        if (coordination_.IsOn() && !usbAutomation_.IsOn()) { tabs_.SelectedIndex(1); ShowValidationError(L"双端协同依赖 USB 自动切换，请先启用 USB 自动切换。"); return; }
        if (coordination_.IsOn() && (host.empty() || code.size() < 8)) { tabs_.SelectedIndex(2); ShowValidationError(L"启用协同时，请填写 Mac IP 和至少 8 位配对码。"); return; }
        auto port = ParseInteger(port_.Text().c_str(), 10, 1, 65535);
        if (!port) { tabs_.SelectedIndex(2); ShowValidationError(L"UDP 端口必须为 1–65535。"); return; }
        auto backendIndex = displayBackend_.SelectedIndex();
        if (usbAutomation_.IsOn() && backendIndex < 0)
        { tabs_.SelectedIndex(3); ShowValidationError(L"启用 USB 自动切换前，请先完成显示器配置。"); return; }
        CaptureDisplayEditors();
        if (backendIndex >= 0 && workingDisplays_.empty())
        { tabs_.SelectedIndex(3); ShowValidationError(L"请至少添加一台显示器，或清除显示器控制方式。"); return; }
        auto controlMyMonitorPath = Trim(controlMyMonitor_.Text().c_str());
        if (backendIndex == 1 && controlMyMonitorPath.empty())
        { tabs_.SelectedIndex(3); ShowValidationError(L"使用 ControlMyMonitor 时，请填写程序路径。"); return; }
        std::set<std::wstring> hardwareIds;
        for (auto const& display : workingDisplays_)
        {
            if (backendIndex < 0) break;
            if (display.name.empty())
            { tabs_.SelectedIndex(3); ShowValidationError(L"每台显示器都需要填写名称。"); return; }
            if (display.macInput < 0 || display.macInput > 65535)
            { tabs_.SelectedIndex(3); ShowValidationError(display.name + L"的 Mac 输入源必须为 0–65535 的整数。"); return; }
            auto hardwareId = backendIndex == 0 ? display.nativeMonitorId : display.controlMonitorPath;
            if (hardwareId.empty())
            {
                tabs_.SelectedIndex(3);
                ShowValidationError(display.name + (backendIndex == 0 ? L"尚未选择 DDC/CI 显示器。" : L"尚未填写设备路径。"));
                return;
            }
            std::transform(hardwareId.begin(), hardwareId.end(), hardwareId.begin(), towlower);
            if (!hardwareIds.insert(hardwareId).second)
            { tabs_.SelectedIndex(3); ShowValidationError(L"不能让多项配置指向同一台物理显示器。"); return; }
        }
        auto result = original_; result.usbAutomationEnabled = usbAutomation_.IsOn(); result.coordinationEnabled = coordination_.IsOn();
        result.peerHost = host; result.port = *port; result.pairingCode = code;
        result.usbVendorId = vendor.value_or(-1); result.usbProductId = product.value_or(-1); auto selected = usbDevices_.SelectedIndex();
        if (selected >= 0 && static_cast<size_t>(selected) < devices_.size()) result.usbName = devices_[selected].name;
        else if (!vendor || !product) result.usbName.clear();
        result.displayControlBackend = backendIndex == 0 ? L"native_ddc" : backendIndex == 1 ? L"control_my_monitor" : L"";
        result.controlMyMonitorPath = controlMyMonitorPath; result.displays = workingDisplays_;
        result.displayConfigurationSafeMode = false; result.startWithWindows = autoStart_.IsOn();
        if (saved_) saved_(result); original_ = result; appWindow_.Hide();
    }

    void SettingsWindow::ShowValidationError(std::wstring const& message)
    {
        validation_.Text(message); validation_.Visibility(Visibility::Visible);
    }
}
