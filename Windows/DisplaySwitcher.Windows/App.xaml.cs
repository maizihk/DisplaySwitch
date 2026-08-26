using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace DisplaySwitcher.Windows;

public partial class App : Application
{
    private TrayApplicationContext? _context;
    private Window? _lifetimeWindow;

    public App()
    {
        UnhandledException += (_, args) =>
        {
            Console.Error.WriteLine(args.Exception);
            _context?.ShowError("程序发生错误", args.Exception.Message);
        };
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _lifetimeWindow = new Window { Title = "DisplaySwitcher lifetime host" };
        var lifetimeWindowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(
            WinRT.Interop.WindowNative.GetWindowHandle(_lifetimeWindow));
        var lifetimeAppWindow = AppWindow.GetFromWindowId(lifetimeWindowId);
        lifetimeAppWindow.IsShownInSwitchers = false;
        _lifetimeWindow.Activate();
        lifetimeAppWindow.Hide();

        _context = new TrayApplicationContext(
            DispatcherQueue.GetForCurrentThread(),
            ExitApplication);
    }

    private void ExitApplication()
    {
        _context?.Dispose();
        _context = null;
        _lifetimeWindow?.Close();
        _lifetimeWindow = null;
        Exit();
    }

}
