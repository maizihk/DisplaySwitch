namespace DisplaySwitcher.Windows;

internal sealed class SettingsForm : Form
{
    public AppConfig Result { get; private set; }

    private readonly CheckBox _enabled = new() { Text = "启用 Mac / Windows 网络协同", AutoSize = true };
    private readonly TextBox _peerHost = new();
    private readonly NumericUpDown _port = new() { Minimum = 1, Maximum = 65535 };
    private readonly TextBox _pairingCode = new() { UseSystemPasswordChar = true };
    private readonly ComboBox _usbDevices = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _vid = new();
    private readonly TextBox _pid = new();
    private readonly TextBox _cmmPath = new();
    private readonly TextBox _redmiPath = new();
    private readonly NumericUpDown _redmiInput = new() { Minimum = 0, Maximum = 65535 };
    private readonly TextBox _dellPath = new();
    private readonly NumericUpDown _dellInput = new() { Minimum = 0, Maximum = 65535 };
    private readonly CheckBox _autoStart = new() { Text = "登录 Windows 时自动启动", AutoSize = true };

    public SettingsForm(AppConfig config)
    {
        Result = config;
        Text = "显示器切换设置";
        Width = 650;
        Height = 650;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;

        var table = new TableLayoutPanel {
            Dock = DockStyle.Fill,
            Padding = new Padding(18),
            ColumnCount = 2,
            RowCount = 0,
            AutoScroll = true
        };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(table);

        AddWide(table, _enabled);
        Add(table, "Mac IP", _peerHost);
        Add(table, "通信端口", _port);
        Add(table, "配对码", _pairingCode);

        var usbPanel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        _usbDevices.Width = 330;
        var refresh = new Button { Text = "读取当前 USB", AutoSize = true };
        refresh.Click += (_, _) => LoadUsbDevices();
        _usbDevices.SelectedIndexChanged += (_, _) => SelectUsbDevice();
        usbPanel.Controls.Add(_usbDevices);
        usbPanel.Controls.Add(refresh);
        Add(table, "USB 触发设备", usbPanel);
        Add(table, "USB Vendor ID", _vid);
        Add(table, "USB Product ID", _pid);
        Add(table, "ControlMyMonitor", _cmmPath);
        Add(table, "小米设备路径", _redmiPath);
        Add(table, "小米 Mac 输入", _redmiInput);
        Add(table, "Dell 设备路径", _dellPath);
        Add(table, "Dell Mac 输入", _dellInput);
        AddWide(table, _autoStart);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, AutoSize = true };
        var save = new Button { Text = "保存", AutoSize = true };
        var cancel = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel };
        save.Click += SaveClicked;
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);
        AddWide(table, buttons);

        AcceptButton = save;
        CancelButton = cancel;
        LoadValues(config);
        Shown += (_, _) => LoadUsbDevices();
    }

    private static void Add(TableLayoutPanel table, string label, Control control)
    {
        var row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        table.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Right, Margin = new Padding(3, 8, 8, 3) }, 0, row);
        control.Dock = DockStyle.Top;
        control.Margin = new Padding(3, 4, 3, 4);
        table.Controls.Add(control, 1, row);
    }

    private static void AddWide(TableLayoutPanel table, Control control)
    {
        var row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        control.Margin = new Padding(3, 6, 3, 6);
        table.Controls.Add(control, 0, row);
        table.SetColumnSpan(control, 2);
    }

    private void LoadValues(AppConfig c)
    {
        _enabled.Checked = c.CoordinationEnabled;
        _peerHost.Text = c.PeerHost;
        _port.Value = c.Port;
        _pairingCode.Text = c.PairingCode;
        _vid.Text = c.UsbVendorId.ToString("X4");
        _pid.Text = c.UsbProductId.ToString("X4");
        _cmmPath.Text = c.ControlMyMonitorPath;
        _redmiPath.Text = c.RedmiMonitorPath;
        _redmiInput.Value = c.RedmiMacInput;
        _dellPath.Text = c.DellMonitorPath;
        _dellInput.Value = c.DellMacInput;
        _autoStart.Checked = c.StartWithWindows;
    }

    private void LoadUsbDevices()
    {
        try
        {
            var devices = UsbWatcher.EnumerateDevices();
            _usbDevices.DataSource = devices;
            _usbDevices.DisplayMember = nameof(UsbDeviceInfo.DisplayName);
            var current = devices.FindIndex(x => x.VendorId == Result.UsbVendorId && x.ProductId == Result.UsbProductId);
            if (current >= 0) _usbDevices.SelectedIndex = current;
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "读取 USB 失败"); }
    }

    private void SelectUsbDevice()
    {
        if (_usbDevices.SelectedItem is not UsbDeviceInfo device) return;
        _vid.Text = device.VendorId.ToString("X4");
        _pid.Text = device.ProductId.ToString("X4");
    }

    private void SaveClicked(object? sender, EventArgs e)
    {
        if (!int.TryParse(_vid.Text, System.Globalization.NumberStyles.HexNumber, null, out var vid) ||
            !int.TryParse(_pid.Text, System.Globalization.NumberStyles.HexNumber, null, out var pid))
        {
            MessageBox.Show(this, "USB Vendor ID 和 Product ID 必须是十六进制，例如 0BDA、5409。", "无法保存");
            return;
        }
        if (_enabled.Checked && (string.IsNullOrWhiteSpace(_peerHost.Text) || _pairingCode.Text.Trim().Length < 8))
        {
            MessageBox.Show(this, "启用协同时，请填写 Mac IP 和至少 8 位配对码。", "无法保存");
            return;
        }

        var selected = _usbDevices.SelectedItem as UsbDeviceInfo;
        Result = new AppConfig {
            CoordinationEnabled = _enabled.Checked,
            PeerHost = _peerHost.Text.Trim(),
            Port = (int)_port.Value,
            PairingCode = _pairingCode.Text.Trim(),
            UsbVendorId = vid,
            UsbProductId = pid,
            UsbName = selected?.Name ?? Result.UsbName,
            ControlMyMonitorPath = _cmmPath.Text.Trim(),
            RedmiMonitorPath = _redmiPath.Text.Trim(),
            RedmiMacInput = (int)_redmiInput.Value,
            DellMonitorPath = _dellPath.Text.Trim(),
            DellMacInput = (int)_dellInput.Value,
            StartWithWindows = _autoStart.Checked
        };
        DialogResult = DialogResult.OK;
        Close();
    }
}
