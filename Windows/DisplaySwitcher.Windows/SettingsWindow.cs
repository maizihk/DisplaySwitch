using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.UI;
using Windows.UI.Text;

namespace DisplaySwitcher.Windows;

internal sealed class SettingsWindow : Window
{
    public event Action<AppConfig>? Saved;

    private readonly AppConfig _original;
    private readonly TextBlock _validationTextBlock = new()
    {
        Foreground = new SolidColorBrush(Color.FromArgb(255, 196, 43, 28)),
        TextWrapping = TextWrapping.Wrap,
        Visibility = Visibility.Collapsed
    };
    private readonly ToggleSwitch _coordinationToggle = new() { Header = "启用 Mac / Windows 网络协同" };
    private readonly TextBox _peerHostTextBox = new() { Header = "Mac IP 或主机名", PlaceholderText = "请输入目标 Mac 地址" };
    private readonly TextBox _portTextBox = new() { Header = "UDP 端口", PlaceholderText = "49731" };
    private readonly PasswordBox _pairingCodeBox = new() { Header = "配对码", PlaceholderText = "至少 8 位，两端保持一致" };
    private readonly ComboBox _usbDevicesComboBox = new() { Header = "当前 USB 设备", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _vendorIdTextBox = new() { Header = "Vendor ID", PlaceholderText = "4 位十六进制", MaxLength = 4 };
    private readonly TextBox _productIdTextBox = new() { Header = "Product ID", PlaceholderText = "4 位十六进制", MaxLength = 4 };
    private readonly TextBox _controlMyMonitorTextBox = new() { Header = "ControlMyMonitor 路径" };
    private readonly TextBox _redmiPathTextBox = new() { Header = "设备路径" };
    private readonly TextBox _redmiInputTextBox = new() { Header = "Mac 输入源" };
    private readonly TextBox _dellPathTextBox = new() { Header = "设备路径" };
    private readonly TextBox _dellInputTextBox = new() { Header = "Mac 输入源" };
    private readonly ToggleSwitch _autoStartToggle = new() { Header = "登录 Windows 时自动启动" };
    private AppWindow _appWindow = null!;
    private OverlappedPresenter? _presenter;
    private bool _usbLoaded;

    public SettingsWindow(AppConfig config)
    {
        _original = config;

        Title = "显示器切换设置";
        try { SystemBackdrop = new MicaBackdrop(); } catch { }
        ResizeAndCenter();
        Content = BuildContent();
        LoadValues(config);
    }

    private UIElement BuildContent()
    {
        var root = new Grid { Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)) };
        var scrollViewer = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        var page = new Grid
        {
            Padding = new Thickness(32),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var content = new StackPanel
        {
            MaxWidth = 720,
            Spacing = 20,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };

        UIElement Finish()
        {
            page.Children.Add(content);
            scrollViewer.Content = page;
            root.Children.Add(scrollViewer);
            return root;
        }

        content.Children.Add(new TextBlock
        {
            Text = "显示器切换设置",
            FontSize = 28,
            FontWeight = new FontWeight { Weight = 600 }
        });
        content.Children.Add(new TextBlock
        {
            Text = "配置 Mac / Windows 协同、USB 触发设备和显示器输入源。",
            Opacity = 0.72,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, -12, 0, 0)
        });
        content.Children.Add(_validationTextBlock);

        content.Children.Add(CreateSection("网络协同",
            _coordinationToggle,
            CreateTwoColumn(_peerHostTextBox, _portTextBox, 180),
            _pairingCodeBox));

        var refreshUsbButton = new Button
        {
            Content = "重新读取",
            VerticalAlignment = VerticalAlignment.Bottom
        };
        refreshUsbButton.Click += (_, _) => LoadUsbDevices();
        _usbDevicesComboBox.SelectionChanged += UsbDevicesComboBox_SelectionChanged;
        content.Children.Add(CreateSection("USB 触发设备",
            CreateTwoColumn(_usbDevicesComboBox, refreshUsbButton, double.NaN),
            CreateTwoColumn(_vendorIdTextBox, _productIdTextBox)));

        var redmiTitle = CreateSubheading("显示器 1");
        var dellTitle = CreateSubheading("显示器 2");
        content.Children.Add(CreateSection("显示器控制",
            _controlMyMonitorTextBox,
            redmiTitle,
            CreateTwoColumn(_redmiPathTextBox, _redmiInputTextBox, 180),
            dellTitle,
            CreateTwoColumn(_dellPathTextBox, _dellInputTextBox, 180)));

        content.Children.Add(CreateCard(_autoStartToggle));

        var cancelButton = new Button { Content = "取消" };
        cancelButton.Click += (_, _) => HideWindow();
        var saveButton = new Button { Content = "保存" };
        saveButton.Click += Save_Click;
        try { saveButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"]; } catch { }

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 0, 24)
        };
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(saveButton);
        content.Children.Add(buttons);

        root.Loaded += (_, _) =>
        {
            if (_usbLoaded) return;
            _usbLoaded = true;
            LoadUsbDevices();
        };
        return Finish();
    }

    private static Border CreateSection(string title, params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 16 };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 20,
            FontWeight = new FontWeight { Weight = 600 }
        });
        foreach (var child in children) panel.Children.Add(child);
        return CreateCard(panel);
    }

    private static Border CreateCard(UIElement child)
    {
        return new Border
        {
            Child = child,
            Padding = new Thickness(20),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(20, 128, 128, 128)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(28, 128, 128, 128))
        };
    }

    private static Grid CreateTwoColumn(FrameworkElement left, FrameworkElement right, double rightWidth = double.NaN)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = double.IsNaN(rightWidth) ? GridLength.Auto : new GridLength(rightWidth)
        });
        Grid.SetColumn(left, 0);
        Grid.SetColumn(right, 1);
        grid.Children.Add(left);
        grid.Children.Add(right);
        return grid;
    }

    private static TextBlock CreateSubheading(string text) => new()
    {
        Text = text,
        FontWeight = new FontWeight { Weight = 600 },
        Margin = new Thickness(0, 2, 0, -6)
    };

    private void ResizeAndCenter()
    {
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(
            WinRT.Interop.WindowNative.GetWindowHandle(this));
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _presenter = _appWindow.Presenter as OverlappedPresenter;
        if (_presenter is not null)
        {
            _presenter.IsMaximizable = false;
            _presenter.IsMinimizable = false;
        }
        var displayArea = DisplayArea.GetFromWindowId(windowId, DisplayAreaFallback.Primary);
        var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        var scale = dpi == 0 ? 1.0 : dpi / 96.0;
        var width = Math.Min((int)Math.Round(800 * scale), displayArea.WorkArea.Width);
        var height = Math.Min((int)Math.Round(860 * scale), displayArea.WorkArea.Height);
        var x = displayArea.WorkArea.X + Math.Max(0, (displayArea.WorkArea.Width - width) / 2);
        var y = displayArea.WorkArea.Y + Math.Max(0, (displayArea.WorkArea.Height - height) / 2);
        _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    public void ShowWindow()
    {
        _appWindow.Show();
        Activate();
    }

    public void CloseForExit()
    {
        Close();
    }

    private void HideWindow() => _appWindow.Hide();

    private void LoadValues(AppConfig config)
    {
        _coordinationToggle.IsOn = config.CoordinationEnabled;
        _peerHostTextBox.Text = config.PeerHost;
        _portTextBox.Text = config.Port.ToString(CultureInfo.InvariantCulture);
        _pairingCodeBox.Password = config.PairingCode;
        _vendorIdTextBox.Text = config.UsbVendorId >= 0 ? config.UsbVendorId.ToString("X4") : "";
        _productIdTextBox.Text = config.UsbProductId >= 0 ? config.UsbProductId.ToString("X4") : "";
        _controlMyMonitorTextBox.Text = config.ControlMyMonitorPath;
        _redmiPathTextBox.Text = config.RedmiMonitorPath;
        _redmiInputTextBox.Text = config.RedmiMacInput >= 0 ? config.RedmiMacInput.ToString(CultureInfo.InvariantCulture) : "";
        _dellPathTextBox.Text = config.DellMonitorPath;
        _dellInputTextBox.Text = config.DellMacInput >= 0 ? config.DellMacInput.ToString(CultureInfo.InvariantCulture) : "";
        _autoStartToggle.IsOn = config.StartWithWindows;
    }

    private void LoadUsbDevices()
    {
        try
        {
            var devices = UsbWatcher.EnumerateDevices();
            _usbDevicesComboBox.Items.Clear();
            foreach (var device in devices)
            {
                _usbDevicesComboBox.Items.Add(new ComboBoxItem
                {
                    Content = device.DisplayName,
                    Tag = device
                });
            }
            var current = devices.FindIndex(x =>
                x.VendorId == _original.UsbVendorId && x.ProductId == _original.UsbProductId);
            if (current >= 0) _usbDevicesComboBox.SelectedIndex = current;
            _validationTextBlock.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            ShowValidationError($"读取 USB 失败：{ex.Message}");
        }
    }

    private void UsbDevicesComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_usbDevicesComboBox.SelectedItem is not ComboBoxItem { Tag: UsbDeviceInfo device }) return;
        _vendorIdTextBox.Text = device.VendorId.ToString("X4");
        _productIdTextBox.Text = device.ProductId.ToString("X4");
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(_vendorIdTextBox.Text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var vid) ||
            !int.TryParse(_productIdTextBox.Text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var pid))
        {
            ShowValidationError("USB Vendor ID 和 Product ID 必须同时填写为 4 位十六进制。");
            return;
        }

        if (_coordinationToggle.IsOn &&
            (string.IsNullOrWhiteSpace(_peerHostTextBox.Text) || _pairingCodeBox.Password.Trim().Length < 8))
        {
            ShowValidationError("启用协同时，请填写 Mac IP 和至少 8 位配对码。");
            return;
        }

        if (!int.TryParse(_portTextBox.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var port) ||
            port is < 1 or > 65535 ||
            !int.TryParse(_redmiInputTextBox.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var redmiInput) ||
            redmiInput is < 0 or > 65535 ||
            !int.TryParse(_dellInputTextBox.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var dellInput) ||
            dellInput is < 0 or > 65535)
        {
            ShowValidationError("UDP 端口必须为 1–65535；显示器输入源必须为 0–65535 的整数。");
            return;
        }

        var selected = (_usbDevicesComboBox.SelectedItem as ComboBoxItem)?.Tag as UsbDeviceInfo;
        var result = new AppConfig
        {
            CoordinationEnabled = _coordinationToggle.IsOn,
            PeerHost = _peerHostTextBox.Text.Trim(),
            Port = port,
            PairingCode = _pairingCodeBox.Password.Trim(),
            UsbVendorId = vid,
            UsbProductId = pid,
            UsbName = selected?.Name ?? _original.UsbName,
            ControlMyMonitorPath = _controlMyMonitorTextBox.Text.Trim(),
            RedmiMonitorPath = _redmiPathTextBox.Text.Trim(),
            RedmiMacInput = redmiInput,
            DellMonitorPath = _dellPathTextBox.Text.Trim(),
            DellMacInput = dellInput,
            StartWithWindows = _autoStartToggle.IsOn
        };

        Saved?.Invoke(result);
        HideWindow();
    }

    private void ShowValidationError(string message)
    {
        _validationTextBlock.Text = message;
        _validationTextBlock.Visibility = Visibility.Visible;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

}
