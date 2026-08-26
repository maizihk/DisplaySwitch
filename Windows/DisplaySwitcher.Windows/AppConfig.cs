using System.Text.Json;

namespace DisplaySwitcher.Windows;

internal sealed class AppConfig
{
    public bool CoordinationEnabled { get; set; }
    public string PeerHost { get; set; } = "";
    public int Port { get; set; } = 49731;
    public string PairingCode { get; set; } = "";
    public int UsbVendorId { get; set; } = 0x0BDA;
    public int UsbProductId { get; set; } = 0x5409;
    public string UsbName { get; set; } = "4-Port USB 2.0 Hub";
    public string ControlMyMonitorPath { get; set; } = @"D:\Soft\ControlMyMonitor\ControlMyMonitor.exe";
    public string RedmiMonitorPath { get; set; } = @"\\.\DISPLAY2\Monitor0";
    public int RedmiMacInput { get; set; } = 16;
    public string DellMonitorPath { get; set; } = @"\\.\DISPLAY1\Monitor0";
    public int DellMacInput { get; set; } = 17;
    public bool StartWithWindows { get; set; }

    private static string ConfigDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DisplaySwitcher");
    private static string ConfigPath => Path.Combine(ConfigDirectory, "settings.json");

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath)) ?? new AppConfig();
        }
        catch { }
        return new AppConfig();
    }

    public void Save()
    {
        Directory.CreateDirectory(ConfigDirectory);
        File.WriteAllText(ConfigPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
