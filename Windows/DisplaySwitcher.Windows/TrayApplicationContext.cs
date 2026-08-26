namespace DisplaySwitcher.Windows;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _trayIcon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly UdpPeer _peer = new();
    private UsbWatcher _usbWatcher;
    private AppConfig _config;
    private readonly SynchronizationContext _ui;
    private readonly object _stateLock = new();
    private CancellationTokenSource? _outgoingCts;
    private string? _outgoingEventId;
    private string? _incomingEventId;
    private double _lastIncomingRequestTimestamp;

    public TrayApplicationContext()
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _config = AppConfig.Load();
        _usbWatcher = new UsbWatcher(_config.UsbVendorId, _config.UsbProductId);
        _usbWatcher.PresenceChanged += OnUsbPresenceChanged;
        _peer.MessageReceived += message => _ui.Post(_ => HandlePeerMessage(message), null);
        _peer.Error += message => SetStatus(message);

        _statusItem = new ToolStripMenuItem("正在初始化…") { Enabled = false };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("手动切换到 Mac", null, async (_, _) => await ManualSwitchAsync());
        menu.Items.Add("设置…", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Exit());

        _trayIcon = new NotifyIcon {
            Icon = SystemIcons.Application,
            Text = "显示器切换",
            ContextMenuStrip = menu,
            Visible = true
        };
        _trayIcon.DoubleClick += (_, _) => ShowSettings();

        ApplyConfiguration();
    }

    private void ApplyConfiguration()
    {
        _peer.Stop();
        _usbWatcher.Reconfigure(_config.UsbVendorId, _config.UsbProductId);
        if (_config.CoordinationEnabled) _peer.Start(_config.Port);
        try { AutoStart.Apply(_config.StartWithWindows); } catch { }
        SetStatus(_config.CoordinationEnabled
            ? $"协同已开启 · USB {_config.UsbVendorId:X4}:{_config.UsbProductId:X4}"
            : "协同未开启");
    }

    private void OnUsbPresenceChanged(bool isPresent) => _ui.Post(async _ =>
    {
        if (!_config.CoordinationEnabled) return;

        if (isPresent)
        {
            CancelOutgoing();
            var wakeSucceeded = SystemActions.WakeDisplay();
            await SendAsync("usb_present", Guid.NewGuid().ToString(), wakeSucceeded);
            if (_incomingEventId is not null)
                await SendAsync("usb_attached_and_awake", _incomingEventId, wakeSucceeded);
            SetStatus("USB 已接入 Windows，等待切屏");
            return;
        }

        SetStatus("USB 已离开 Windows，等待确认…");
        await Task.Delay(800);
        if (!_usbWatcher.IsPresent()) BeginOutgoingHandover();
    }, null);

    private void BeginOutgoingHandover()
    {
        CancelOutgoing();
        var eventId = Guid.NewGuid().ToString();
        var cts = new CancellationTokenSource();
        lock (_stateLock) { _outgoingEventId = eventId; _outgoingCts = cts; }
        _ = RunOutgoingAsync(eventId, cts.Token);
    }

    private async Task RunOutgoingAsync(string eventId, CancellationToken token)
    {
        try
        {
            for (var attempt = 0; attempt < 5; attempt++)
            {
                if (token.IsCancellationRequested) return;
                await SendAsync("handover_request", eventId, null);
                await Task.Delay(450, token);
            }
            await Task.Delay(250, token);
            _ui.Post(async _ => await CompleteOutgoingAsync(eventId), null);
        }
        catch (OperationCanceledException) { }
    }

    private async Task CompleteOutgoingAsync(string eventId)
    {
        lock (_stateLock)
        {
            if (_outgoingEventId != eventId) return;
            _outgoingEventId = null;
            _outgoingCts?.Cancel();
            _outgoingCts?.Dispose();
            _outgoingCts = null;
        }

        SetStatus("正在切换显示器到 Mac…");
        var result = await SystemActions.SwitchDisplaysToMacAsync(_config);
        await SendAsync("committed", eventId, result.Success);
        SetStatus(result.Success ? "已切换到 Mac" : $"部分切换失败：{result.Error}");
        if (!result.Success)
            _trayIcon.ShowBalloonTip(4000, "显示器切换失败", result.Error ?? "未知错误", ToolTipIcon.Warning);
    }

    private void CancelOutgoing()
    {
        lock (_stateLock)
        {
            _outgoingEventId = null;
            _outgoingCts?.Cancel();
            _outgoingCts?.Dispose();
            _outgoingCts = null;
        }
    }

    private async void HandlePeerMessage(PeerMessage message)
    {
        if (!_config.CoordinationEnabled || message.Version != 1 ||
            message.PairingCode != _config.PairingCode || message.Source != "mac" || message.Target != "windows" ||
            Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - message.Timestamp) > 10)
            return;

        switch (message.Type)
        {
            case "handover_request":
                if (message.Timestamp < _lastIncomingRequestTimestamp) return;
                _lastIncomingRequestTimestamp = message.Timestamp;
                _incomingEventId = message.EventID;
                var wakeSucceeded = SystemActions.WakeDisplay();
                if (_usbWatcher.IsPresent())
                    await SendAsync("usb_attached_and_awake", message.EventID, wakeSucceeded);
                break;
            case "usb_present":
                if (_outgoingEventId is not null) await CompleteOutgoingAsync(_outgoingEventId);
                break;
            case "usb_attached_and_awake":
                if (_outgoingEventId == message.EventID) await CompleteOutgoingAsync(message.EventID);
                break;
            case "committed":
                if (_incomingEventId == message.EventID) _incomingEventId = null;
                SetStatus("Mac 已完成显示器切换");
                break;
        }
    }

    private Task SendAsync(string type, string eventId, bool? wakeSucceeded)
    {
        var message = new PeerMessage(
            1, type, eventId, "windows", "mac",
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            _config.PairingCode, wakeSucceeded);
        return _peer.SendAsync(message, _config.PeerHost, _config.Port);
    }

    private async Task ManualSwitchAsync()
    {
        var result = await SystemActions.SwitchDisplaysToMacAsync(_config);
        SetStatus(result.Success ? "已手动切换到 Mac" : $"切换失败：{result.Error}");
    }

    private void ShowSettings()
    {
        using var form = new SettingsForm(_config);
        if (form.ShowDialog() != DialogResult.OK) return;
        _config = form.Result;
        _config.Save();
        ApplyConfiguration();
    }

    private void SetStatus(string text) => _ui.Post(_ =>
    {
        _statusItem.Text = text.Length > 70 ? text[..70] : text;
        _trayIcon.Text = text.Length > 60 ? text[..60] : text;
    }, null);

    private void Exit()
    {
        CancelOutgoing();
        _peer.Dispose();
        _usbWatcher.Dispose();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        ExitThread();
    }
}
