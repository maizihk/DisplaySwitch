using System.Runtime.InteropServices;

namespace DisplaySwitcher.Windows;

internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private const uint NimAdd = 0x00000000;
    private const uint NimModify = 0x00000001;
    private const uint NimDelete = 0x00000002;
    private const uint NimSetVersion = 0x00000004;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint NifInfo = 0x00000010;
    private const uint NifGuid = 0x00000020;
    private const uint NifShowTip = 0x00000080;
    private const uint NotifyIconVersion4 = 4;
    private const uint NiifWarning = 0x00000002;
    private const uint WmContextMenu = 0x007B;
    private const uint WmLButtonDoubleClick = 0x0203;
    private const uint WmRButtonUp = 0x0205;
    private const uint NinSelect = 0x0400;
    private const uint NinKeySelect = 0x0401;
    private const uint MfString = 0x00000000;
    private const uint MfDisabled = 0x00000002;
    private const uint MfGrayed = 0x00000001;
    private const uint MfSeparator = 0x00000800;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCommand = 0x0100;
    private const uint ManualSwitchCommand = 1001;
    private const uint SettingsCommand = 1002;
    private const uint ExitCommand = 1003;

    private static readonly IntPtr IdiApplication = new(32512);
    private static readonly Guid TrayIconGuid = new("438E980A-76BB-4E3A-995C-5EAB0D263E3A");

    private readonly string _windowClassName = $"DisplaySwitcher.Tray.{Environment.ProcessId}";
    private readonly WndProc _windowProc;
    private readonly Action _showSettings;
    private readonly Func<Task> _manualSwitch;
    private readonly Action _exit;
    private readonly IntPtr _instance;
    private readonly IntPtr _icon;
    private IntPtr _window;
    private string _status = "正在初始化…";
    private bool _disposed;

    public TrayIcon(Action showSettings, Func<Task> manualSwitch, Action exit)
    {
        _showSettings = showSettings;
        _manualSwitch = manualSwitch;
        _exit = exit;
        _windowProc = WindowProc;
        _instance = GetModuleHandleW(null);
        _icon = LoadIconW(IntPtr.Zero, IdiApplication);

        var windowClass = new WndClassEx
        {
            Size = (uint)Marshal.SizeOf<WndClassEx>(),
            Instance = _instance,
            ClassName = _windowClassName,
            WindowProc = Marshal.GetFunctionPointerForDelegate(_windowProc)
        };
        if (RegisterClassExW(ref windowClass) == 0)
            throw new InvalidOperationException($"无法注册托盘窗口：{Marshal.GetLastWin32Error()}");

        _window = CreateWindowExW(
            0, _windowClassName, "DisplaySwitcher tray host", 0,
            0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, _instance, IntPtr.Zero);
        if (_window == IntPtr.Zero)
            throw new InvalidOperationException($"无法创建托盘窗口：{Marshal.GetLastWin32Error()}");

        var data = CreateData(NifMessage | NifIcon | NifTip | NifShowTip);
        if (!ShellNotifyIconW(NimAdd, ref data))
            throw new InvalidOperationException(
                $"无法创建托盘图标：error={Marshal.GetLastWin32Error()}, hwnd=0x{_window:X}, " +
                $"icon=0x{_icon:X}, dataSize={data.Size}");
        data.TimeoutOrVersion = NotifyIconVersion4;
        ShellNotifyIconW(NimSetVersion, ref data);
    }

    public void SetStatus(string status)
    {
        if (_disposed) return;
        _status = status;
        var data = CreateData(NifIcon | NifTip);
        ShellNotifyIconW(NimModify, ref data);
    }

    public void ShowBalloon(string title, string message)
    {
        if (_disposed) return;
        var data = CreateData(NifIcon | NifTip | NifInfo);
        data.InfoTitle = Limit(title, 63);
        data.Info = Limit(message, 255);
        data.InfoFlags = NiifWarning;
        ShellNotifyIconW(NimModify, ref data);
    }

    private NotifyIconData CreateData(uint flags) => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = _window,
        Id = 1,
        Flags = flags | NifGuid,
        CallbackMessage = CallbackMessage,
        Icon = _icon,
        Tip = Limit($"显示器切换 · {_status}", 127),
        Info = string.Empty,
        InfoTitle = string.Empty,
        GuidItem = TrayIconGuid
    };

    private IntPtr WindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            var notification = unchecked((uint)lParam.ToInt64()) & 0xFFFF;
            switch (notification)
            {
                case WmContextMenu:
                case WmRButtonUp:
                    ShowContextMenu();
                    return IntPtr.Zero;
                case WmLButtonDoubleClick:
                case NinSelect:
                case NinKeySelect:
                    _showSettings();
                    return IntPtr.Zero;
            }
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        try
        {
            AppendMenuW(menu, MfString | MfDisabled | MfGrayed, 0, Limit(_status, 70));
            AppendMenuW(menu, MfSeparator, 0, null);
            AppendMenuW(menu, MfString, ManualSwitchCommand, "手动切换到 Mac");
            AppendMenuW(menu, MfString, SettingsCommand, "设置…");
            AppendMenuW(menu, MfSeparator, 0, null);
            AppendMenuW(menu, MfString, ExitCommand, "退出");

            GetCursorPos(out var point);
            SetForegroundWindow(_window);
            var command = TrackPopupMenu(
                menu, TpmRightButton | TpmReturnCommand,
                point.X, point.Y, 0, _window, IntPtr.Zero);
            switch (command)
            {
                case ManualSwitchCommand:
                    _ = _manualSwitch();
                    break;
                case SettingsCommand:
                    _showSettings();
                    break;
                case ExitCommand:
                    _exit();
                    break;
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private static string Limit(string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_window != IntPtr.Zero)
        {
            var data = CreateData(0);
            ShellNotifyIconW(NimDelete, ref data);
            DestroyWindow(_window);
            _window = IntPtr.Zero;
        }
        UnregisterClassW(_windowClassName, _instance);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClassEx
    {
        public uint Size;
        public uint Style;
        public IntPtr WindowProc;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public string? MenuName;
        public string ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid GuidItem;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WndProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? moduleName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassExW(ref WndClassEx windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool UnregisterClassW(string className, IntPtr instance);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(
        uint extendedStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu,
        IntPtr instance, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadIconW(IntPtr instance, IntPtr iconName);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ShellNotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr menu, uint flags, uint id, string? text);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(
        IntPtr menu, uint flags, int x, int y, int reserved, IntPtr window, IntPtr rectangle);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
}
