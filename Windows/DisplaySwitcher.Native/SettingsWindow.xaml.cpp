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
        redmiNativeMonitor_ = ComboBox(); Header(redmiNativeMonitor_, L"显示器 1"); redmiNativeMonitor_.PlaceholderText(L"请选择显示器"); redmiNativeMonitor_.HorizontalAlignment(HorizontalAlignment::Stretch);
        dellNativeMonitor_ = ComboBox(); Header(dellNativeMonitor_, L"显示器 2"); dellNativeMonitor_.PlaceholderText(L"请选择显示器"); dellNativeMonitor_.HorizontalAlignment(HorizontalAlignment::Stretch);
        controlMyMonitor_ = TextBox(); Header(controlMyMonitor_, L"ControlMyMonitor 路径");
        redmiPath_ = TextBox(); Header(redmiPath_, L"显示器 1 设备路径"); redmiInput_ = TextBox(); Header(redmiInput_, L"显示器 1 Mac 输入源");
        dellPath_ = TextBox(); Header(dellPath_, L"显示器 2 设备路径"); dellInput_ = TextBox(); Header(dellInput_, L"显示器 2 Mac 输入源");
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
        nativeDdcPanel_.Children().Append(nativeHint); nativeDdcPanel_.Children().Append(redmiNativeMonitor_);
        nativeDdcPanel_.Children().Append(dellNativeMonitor_); nativeDdcPanel_.Children().Append(refreshDdc);
        controlMyMonitorPanel_ = StackPanel(); controlMyMonitorPanel_.Spacing(14);
        auto cmmHint = TextBlock(); cmmHint.Text(L"兼容模式：继续通过外部 ControlMyMonitor 执行切换。");
        cmmHint.TextWrapping(TextWrapping::Wrap); cmmHint.Opacity(0.72);
        controlMyMonitorPanel_.Children().Append(cmmHint); controlMyMonitorPanel_.Children().Append(controlMyMonitor_);
        controlMyMonitorPanel_.Children().Append(redmiPath_); controlMyMonitorPanel_.Children().Append(dellPath_);
        displayTab.Content(CreatePage({ CreateSection(L"显示器控制", { displayHint, displayBackend_, nativeDdcPanel_, controlMyMonitorPanel_,
            CreateSubheading(L"Mac 输入源编号"), CreateTwoColumn(redmiInput_, dellInput_, 0) }) }));

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
        controlMyMonitor_.Text(config.controlMyMonitorPath); redmiPath_.Text(config.redmiMonitorPath);
        redmiInput_.Text(config.redmiMacInput >= 0 ? std::to_wstring(config.redmiMacInput) : L"");
        dellPath_.Text(config.dellMonitorPath); dellInput_.Text(config.dellMacInput >= 0 ? std::to_wstring(config.dellMacInput) : L"");
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
        std::wstring redmiWanted = original_.redmiNativeMonitorId;
        std::wstring dellWanted = original_.dellNativeMonitorId;
        auto redmiIndex = redmiNativeMonitor_.SelectedIndex();
        auto dellIndex = dellNativeMonitor_.SelectedIndex();
        if (redmiIndex >= 0 && static_cast<size_t>(redmiIndex) < ddcMonitors_.size()) redmiWanted = ddcMonitors_[redmiIndex].id;
        if (dellIndex >= 0 && static_cast<size_t>(dellIndex) < ddcMonitors_.size()) dellWanted = ddcMonitors_[dellIndex].id;

        try
        {
            ddcMonitors_ = ::DisplaySwitcher::Native::EnumerateDdcMonitors();
            redmiNativeMonitor_.Items().Clear(); dellNativeMonitor_.Items().Clear();
            int selectedRedmi = -1, selectedDell = -1;
            for (size_t index = 0; index < ddcMonitors_.size(); ++index)
            {
                redmiNativeMonitor_.Items().Append(box_value(ddcMonitors_[index].displayName));
                dellNativeMonitor_.Items().Append(box_value(ddcMonitors_[index].displayName));
                if (!redmiWanted.empty() && _wcsicmp(ddcMonitors_[index].id.c_str(), redmiWanted.c_str()) == 0) selectedRedmi = static_cast<int>(index);
                if (!dellWanted.empty() && _wcsicmp(ddcMonitors_[index].id.c_str(), dellWanted.c_str()) == 0) selectedDell = static_cast<int>(index);
                if (redmiWanted.empty() && original_.redmiMonitorPath.starts_with(ddcMonitors_[index].gdiName)) selectedRedmi = static_cast<int>(index);
                if (dellWanted.empty() && original_.dellMonitorPath.starts_with(ddcMonitors_[index].gdiName)) selectedDell = static_cast<int>(index);
            }
            redmiNativeMonitor_.SelectedIndex(selectedRedmi); dellNativeMonitor_.SelectedIndex(selectedDell);
            if (ddcMonitors_.empty() && displayBackend_.SelectedIndex() == 0)
                ShowValidationError(L"没有检测到支持 Windows 物理显示器接口的显示器。");
            else validation_.Visibility(Visibility::Collapsed);
        }
        catch (...) { ShowValidationError(L"读取原生 DDC/CI 显示器失败。"); }
    }

    void SettingsWindow::UpdateDisplayBackendVisibility()
    {
        if (!nativeDdcPanel_ || !controlMyMonitorPanel_) return;
        auto selected = displayBackend_.SelectedIndex();
        nativeDdcPanel_.Visibility(selected == 0 ? Visibility::Visible : Visibility::Collapsed);
        controlMyMonitorPanel_.Visibility(selected == 1 ? Visibility::Visible : Visibility::Collapsed);
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
        auto redmiInput = ParseInteger(redmiInput_.Text().c_str(), 10, 0, 65535);
        auto dellInput = ParseInteger(dellInput_.Text().c_str(), 10, 0, 65535);
        if (backendIndex >= 0 && (!redmiInput || !dellInput))
        { tabs_.SelectedIndex(3); ShowValidationError(L"两台显示器的输入源必须填写为 0–65535 的整数。"); return; }
        auto nativeBackend = backendIndex == 0;
        auto redmiNativeIndex = redmiNativeMonitor_.SelectedIndex(); auto dellNativeIndex = dellNativeMonitor_.SelectedIndex();
        if (nativeBackend && (redmiNativeIndex < 0 || dellNativeIndex < 0))
        { tabs_.SelectedIndex(3); ShowValidationError(L"使用原生 DDC/CI 时，请选择显示器 1 和显示器 2。"); return; }
        if (nativeBackend && redmiNativeIndex == dellNativeIndex)
        { tabs_.SelectedIndex(3); ShowValidationError(L"显示器 1 和显示器 2 不能选择同一台物理显示器。"); return; }
        auto controlMyMonitorPath = Trim(controlMyMonitor_.Text().c_str());
        auto redmiPath = Trim(redmiPath_.Text().c_str()); auto dellPath = Trim(dellPath_.Text().c_str());
        if (backendIndex == 1 && (controlMyMonitorPath.empty() || redmiPath.empty() || dellPath.empty()))
        { tabs_.SelectedIndex(3); ShowValidationError(L"使用 ControlMyMonitor 时，请填写程序路径和两台显示器的设备路径。"); return; }
        auto result = original_; result.usbAutomationEnabled = usbAutomation_.IsOn(); result.coordinationEnabled = coordination_.IsOn();
        result.peerHost = host; result.port = *port; result.pairingCode = code;
        result.usbVendorId = vendor.value_or(-1); result.usbProductId = product.value_or(-1); auto selected = usbDevices_.SelectedIndex();
        if (selected >= 0 && static_cast<size_t>(selected) < devices_.size()) result.usbName = devices_[selected].name;
        else if (!vendor || !product) result.usbName.clear();
        result.displayControlBackend = backendIndex == 0 ? L"native_ddc" : backendIndex == 1 ? L"control_my_monitor" : L"";
        if (redmiNativeIndex >= 0 && static_cast<size_t>(redmiNativeIndex) < ddcMonitors_.size()) result.redmiNativeMonitorId = ddcMonitors_[redmiNativeIndex].id;
        if (dellNativeIndex >= 0 && static_cast<size_t>(dellNativeIndex) < ddcMonitors_.size()) result.dellNativeMonitorId = ddcMonitors_[dellNativeIndex].id;
        result.controlMyMonitorPath = controlMyMonitorPath; result.redmiMonitorPath = redmiPath; result.redmiMacInput = redmiInput.value_or(-1);
        result.dellMonitorPath = dellPath; result.dellMacInput = dellInput.value_or(-1); result.startWithWindows = autoStart_.IsOn();
        if (saved_) saved_(result); original_ = result; appWindow_.Hide();
    }

    void SettingsWindow::ShowValidationError(std::wstring const& message)
    {
        validation_.Text(message); validation_.Visibility(Visibility::Visible);
    }
}
