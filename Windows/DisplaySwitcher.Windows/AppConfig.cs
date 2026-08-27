using System.Text.Json;

namespace DisplaySwitcher.Windows;

internal sealed class AppConfig
{
    public bool CoordinationEnabled { get; set; }
    public string PeerHost { get; set; } = "";
    public int Port { get; set; } = 49731;
    public string PairingCode { get; set; } = "";
    public int UsbVendorId { get; set; } = -1;
    public int UsbProductId { get; set; } = -1;
    public string UsbName { get; set; } = "";
    public string ControlMyMonitorPath { get; set; } = "";
    public string RedmiMonitorPath { get; set; } = "";
    public int RedmiMacInput { get; set; } = -1;
    public string DellMonitorPath { get; set; } = "";
    public int DellMacInput { get; set; } = -1;
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
