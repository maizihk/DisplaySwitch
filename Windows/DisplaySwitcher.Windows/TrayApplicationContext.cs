using Microsoft.UI.Dispatching;

namespace DisplaySwitcher.Windows;

internal sealed class TrayApplicationContext : IDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private readonly Action _exitApplication;
    private readonly TrayIcon _trayIcon;
    private readonly UdpPeer _peer = new();
    private readonly object _stateLock = new();
    private readonly UsbWatcher _usbWatcher;
    private AppConfig _config;
    private SettingsWindow? _settingsWindow;
    private CancellationTokenSource? _outgoingCts;
    private string? _outgoingEventId;
    private string? _incomingEventId;
    private double _lastIncomingRequestTimestamp;
    private bool _disposed;

    public TrayApplicationContext(DispatcherQueue dispatcher, Action exitApplication)
    {
        _dispatcher = dispatcher;
        _exitApplication = exitApplication;
        _config = AppConfig.Load();
        _usbWatcher = new UsbWatcher(_config.UsbVendorId, _config.UsbProductId);
        _trayIcon = new TrayIcon(
            () => Queue(ShowSettings),
            () =>
            {
                Queue(() => _ = ManualSwitchAsync());
                return Task.CompletedTask;
            },
            () => Queue(_exitApplication));

        _usbWatcher.PresenceChanged += OnUsbPresenceChanged;
        _peer.MessageReceived += message => Enqueue(() => _ = HandlePeerMessageAsync(message));
        _peer.Error += message => SetStatus(message);

        ApplyConfiguration();
    }

    private void ApplyConfiguration()
    {
        _peer.Stop();
        _usbWatcher.Reconfigure(_config.UsbVendorId, _config.UsbProductId);
        if (_config.CoordinationEnabled) _peer.Start(_config.Port);
        try { AutoStart.Apply(_config.StartWithWindows); }
        catch (Exception ex) { ShowError("登录启动设置失败", ex.Message); }
        SetStatus(_config.CoordinationEnabled
            ? $"协同已开启 · USB {_config.UsbVendorId:X4}:{_config.UsbProductId:X4}"
            : "协同未开启");
    }

    private void OnUsbPresenceChanged(bool isPresent) =>
        Enqueue(() => _ = HandleUsbPresenceChangedAsync(isPresent));

    private async Task HandleUsbPresenceChangedAsync(bool isPresent)
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
    }

    private void BeginOutgoingHandover()
    {
        CancelOutgoing();
        var eventId = Guid.NewGuid().ToString();
        var cts = new CancellationTokenSource();
        lock (_stateLock)
        {
            _outgoingEventId = eventId;
            _outgoingCts = cts;
        }
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
            Enqueue(() => _ = CompleteOutgoingAsync(eventId));
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
            ShowError("显示器切换失败", result.Error ?? "未知错误");
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

    private async Task HandlePeerMessageAsync(PeerMessage message)
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
                var outgoingEventId = _outgoingEventId;
                if (outgoingEventId is not null) await CompleteOutgoingAsync(outgoingEventId);
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
        SetStatus("正在手动切换显示器到 Mac…");
        var result = await SystemActions.SwitchDisplaysToMacAsync(_config);
        SetStatus(result.Success ? "已手动切换到 Mac" : $"切换失败：{result.Error}");
        if (!result.Success) ShowError("显示器切换失败", result.Error ?? "未知错误");
    }

    private void ShowSettings()
    {
        if (_settingsWindow is not null)
        {
            _settingsWindow.ShowWindow();
            return;
        }

        var window = new SettingsWindow(_config);
        _settingsWindow = window;
        window.Saved += config =>
        {
            _config = config;
            _config.Save();
            ApplyConfiguration();
        };
        window.Closed += (_, _) =>
        {
            if (ReferenceEquals(_settingsWindow, window)) _settingsWindow = null;
        };
        window.ShowWindow();
    }

    private void SetStatus(string text) => Enqueue(() => _trayIcon.SetStatus(text));

    public void ShowError(string title, string message) =>
        Enqueue(() => _trayIcon.ShowBalloon(title, message));

    private void Enqueue(Action action)
    {
        if (_disposed) return;
        if (_dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    private void Queue(Action action)
    {
        if (_disposed) return;
        _dispatcher.TryEnqueue(() => action());
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        CancelOutgoing();
        _peer.Dispose();
        _usbWatcher.Dispose();
        _settingsWindow?.CloseForExit();
        _settingsWindow = null;
        _trayIcon.Dispose();
    }
}
