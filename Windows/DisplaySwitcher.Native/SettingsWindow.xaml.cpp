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
        Content(BuildContent()); LoadValues(config); ResizeAndCenter();
        Closed([this](auto const&, auto const&) { if (closed_) closed_(); });
        LoadUsbDevices();
    }

    UIElement SettingsWindow::BuildContent()
    {
        validation_ = TextBlock(); validation_.Foreground(SolidColorBrush(Windows::UI::Color{ 255, 196, 43, 28 }));
        validation_.TextWrapping(TextWrapping::Wrap); validation_.Visibility(Visibility::Collapsed);
        usbAutomation_ = ToggleSwitch(); Header(usbAutomation_, L"启用 USB 自动切换");
        coordination_ = ToggleSwitch(); Header(coordination_, L"启用 Mac / Windows 网络协同");
        peerHost_ = TextBox(); Header(peerHost_, L"Mac IP 或主机名"); peerHost_.PlaceholderText(L"例如 192.168.1.20");
        port_ = TextBox(); Header(port_, L"UDP 端口"); port_.PlaceholderText(L"49731");
        pairingCode_ = PasswordBox(); Header(pairingCode_, L"配对码"); pairingCode_.PlaceholderText(L"至少 8 位，两端保持一致");
        usbDevices_ = ComboBox(); Header(usbDevices_, L"当前 USB 设备"); usbDevices_.HorizontalAlignment(HorizontalAlignment::Stretch);
        vendorId_ = TextBox(); Header(vendorId_, L"Vendor ID"); vendorId_.PlaceholderText(L"0BDA"); vendorId_.MaxLength(4);
        productId_ = TextBox(); Header(productId_, L"Product ID"); productId_.PlaceholderText(L"5409"); productId_.MaxLength(4);
        controlMyMonitor_ = TextBox(); Header(controlMyMonitor_, L"ControlMyMonitor 路径");
        redmiPath_ = TextBox(); Header(redmiPath_, L"设备路径"); redmiInput_ = TextBox(); Header(redmiInput_, L"Mac 输入源");
        dellPath_ = TextBox(); Header(dellPath_, L"设备路径"); dellInput_ = TextBox(); Header(dellInput_, L"Mac 输入源");
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
        tabs_.HorizontalAlignment(HorizontalAlignment::Stretch); tabs_.VerticalAlignment(VerticalAlignment::Stretch);
        tabs_.TabStripHeader(Grid()); tabs_.TabStripFooter(Grid());

        auto commonTab = TabViewItem(); commonTab.IsClosable(false); commonTab.Header(CreateTabHeader(L"\uE713", L"常规"));
        auto commonHint = TextBlock(); commonHint.Text(L"程序启动后常驻系统托盘，可在托盘菜单中打开设置或退出。");
        commonHint.TextWrapping(TextWrapping::Wrap); commonHint.Opacity(0.72);
        commonTab.Content(CreatePage({ CreateSection(L"常规", { autoStart_, commonHint }) }));

        auto refresh = Button(); refresh.Content(box_value(L"重新读取")); refresh.VerticalAlignment(VerticalAlignment::Bottom);
        refresh.Click([this](auto const&, auto const&) { LoadUsbDevices(); });
        auto usbTab = TabViewItem(); usbTab.IsClosable(false); usbTab.Header(CreateTabHeader(L"\uE88E", L"USB 切换"));
        auto usbHint = TextBlock(); usbHint.Text(L"选择用于判断键鼠归属的 USB Hub。协同关闭时，USB 离开 Windows 后将直接切换到 Mac。");
        usbHint.TextWrapping(TextWrapping::Wrap); usbHint.Opacity(0.72);
        usbTab.Content(CreatePage({ CreateSection(L"USB 触发设备", {
            usbAutomation_, CreateTwoColumn(usbDevices_, refresh), CreateTwoColumn(vendorId_, productId_), usbHint }) }));

        auto peerTab = TabViewItem(); peerTab.IsClosable(false); peerTab.Header(CreateTabHeader(L"\uE968", L"双端协同"));
        auto peerHint = TextBlock(); peerHint.Text(L"两端使用相同端口和配对码；确认 USB 已接入目标电脑后再切换显示器。");
        peerHint.TextWrapping(TextWrapping::Wrap); peerHint.Opacity(0.72);
        peerTab.Content(CreatePage({ CreateSection(L"双端协同", {
            coordination_, CreateTwoColumn(peerHost_, port_, 160), pairingCode_, peerHint }) }));

        auto displayTab = TabViewItem(); displayTab.IsClosable(false); displayTab.Header(CreateTabHeader(L"\uE7F4", L"显示器"));
        displayTab.Content(CreatePage({ CreateSection(L"显示器控制", { controlMyMonitor_, CreateSubheading(L"小米显示器"),
            CreateTwoColumn(redmiPath_, redmiInput_, 150), CreateSubheading(L"Dell 显示器"), CreateTwoColumn(dellPath_, dellInput_, 150) }) }));

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
        auto panel = StackPanel(); panel.Spacing(16); auto heading = TextBlock(); heading.Text(title); heading.FontSize(20);
        heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold()); panel.Children().Append(heading);
        for (auto const& child : children) panel.Children().Append(child); return CreateCard(panel);
    }

    Border SettingsWindow::CreateCard(UIElement const& child)
    {
        auto border = Border(); border.Child(child); border.Padding(Thickness{ 20 }); border.CornerRadius(CornerRadius{ 8 });
        border.BorderThickness(Thickness{ 1 }); border.Background(SolidColorBrush(Windows::UI::Color{ 20, 128, 128, 128 }));
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
        auto rightColumn = ColumnDefinition(); rightColumn.Width(rightWidth < 0 ? GridLengthHelper::Auto() : GridLength{ rightWidth });
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

    void SettingsWindow::ShowWindow() { appWindow_.Show(); Activate(); }
    void SettingsWindow::CloseForExit() { Close(); }

    void SettingsWindow::LoadValues(::DisplaySwitcher::Native::AppConfig const& config)
    {
        usbAutomation_.IsOn(config.usbAutomationEnabled); coordination_.IsOn(config.coordinationEnabled);
        peerHost_.Text(config.peerHost); port_.Text(std::to_wstring(config.port)); pairingCode_.Password(config.pairingCode);
        wchar_t value[5]{}; swprintf_s(value, L"%04X", config.usbVendorId); vendorId_.Text(value); swprintf_s(value, L"%04X", config.usbProductId); productId_.Text(value);
        controlMyMonitor_.Text(config.controlMyMonitorPath); redmiPath_.Text(config.redmiMonitorPath); redmiInput_.Text(std::to_wstring(config.redmiMacInput));
        dellPath_.Text(config.dellMonitorPath); dellInput_.Text(std::to_wstring(config.dellMacInput)); autoStart_.IsOn(config.startWithWindows);
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

    void SettingsWindow::Save()
    {
        auto vendor = ParseInteger(vendorId_.Text().c_str(), 16, 0, 0xFFFF); auto product = ParseInteger(productId_.Text().c_str(), 16, 0, 0xFFFF);
        if (!vendor || !product) { tabs_.SelectedIndex(1); ShowValidationError(L"USB Vendor ID 和 Product ID 必须是十六进制，例如 0BDA、5409。"); return; }
        auto host = Trim(peerHost_.Text().c_str()); auto code = Trim(pairingCode_.Password().c_str());
        if (coordination_.IsOn() && !usbAutomation_.IsOn()) { tabs_.SelectedIndex(1); ShowValidationError(L"双端协同依赖 USB 自动切换，请先启用 USB 自动切换。"); return; }
        if (coordination_.IsOn() && (host.empty() || code.size() < 8)) { tabs_.SelectedIndex(2); ShowValidationError(L"启用协同时，请填写 Mac IP 和至少 8 位配对码。"); return; }
        auto port = ParseInteger(port_.Text().c_str(), 10, 1, 65535); auto redmiInput = ParseInteger(redmiInput_.Text().c_str(), 10, 0, 65535);
        auto dellInput = ParseInteger(dellInput_.Text().c_str(), 10, 0, 65535);
        if (!port) { tabs_.SelectedIndex(2); ShowValidationError(L"UDP 端口必须为 1–65535。"); return; }
        if (!redmiInput || !dellInput) { tabs_.SelectedIndex(3); ShowValidationError(L"显示器输入源必须为 0–65535 的整数。"); return; }
        auto result = original_; result.usbAutomationEnabled = usbAutomation_.IsOn(); result.coordinationEnabled = coordination_.IsOn();
        result.peerHost = host; result.port = *port; result.pairingCode = code;
        result.usbVendorId = *vendor; result.usbProductId = *product; auto selected = usbDevices_.SelectedIndex();
        if (selected >= 0 && static_cast<size_t>(selected) < devices_.size()) result.usbName = devices_[selected].name;
        result.controlMyMonitorPath = Trim(controlMyMonitor_.Text().c_str()); result.redmiMonitorPath = Trim(redmiPath_.Text().c_str()); result.redmiMacInput = *redmiInput;
        result.dellMonitorPath = Trim(dellPath_.Text().c_str()); result.dellMacInput = *dellInput; result.startWithWindows = autoStart_.IsOn();
        if (saved_) saved_(result); original_ = result; appWindow_.Hide();
    }

    void SettingsWindow::ShowValidationError(std::wstring const& message)
    {
        validation_.Text(message); validation_.Visibility(Visibility::Visible);
    }
}
