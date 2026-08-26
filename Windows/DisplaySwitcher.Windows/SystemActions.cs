using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DisplaySwitcher.Windows;

internal static class SystemActions
{
    [Flags]
    private enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState flags);

    public static bool WakeDisplay() => SetThreadExecutionState(
        ExecutionState.SystemRequired | ExecutionState.DisplayRequired) != 0;

    public static async Task<(bool Success, string? Error)> SwitchDisplaysToMacAsync(AppConfig config)
    {
        if (!File.Exists(config.ControlMyMonitorPath))
            return (false, $"找不到 ControlMyMonitor：{config.ControlMyMonitorPath}");

        // 小米先切：切离 Windows 后它可能不再接受当前链路上的 DDC 指令。
        var commands = new[] {
            (config.RedmiMonitorPath, config.RedmiMacInput),
            (config.DellMonitorPath, config.DellMacInput)
        };

        string? firstError = null;
        foreach (var (monitor, input) in commands)
        {
            var succeeded = false;
            string? displayError = null;
            for (var attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    using var process = new Process {
                        StartInfo = new ProcessStartInfo {
                            FileName = config.ControlMyMonitorPath,
                            UseShellExecute = false,
                            CreateNoWindow = true,
                            WindowStyle = ProcessWindowStyle.Hidden
                        }
                    };
                    process.StartInfo.ArgumentList.Add("/SetValue");
                    process.StartInfo.ArgumentList.Add(monitor);
                    process.StartInfo.ArgumentList.Add("60");
                    process.StartInfo.ArgumentList.Add(input.ToString());
                    process.Start();
                    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                    if (process.ExitCode == 0) { succeeded = true; break; }
                    displayError = $"{monitor} 返回退出码 {process.ExitCode}";
                }
                catch (Exception ex) { displayError = $"{monitor}：{ex.Message}"; }
                if (attempt == 0) await Task.Delay(300);
            }
            if (!succeeded) firstError ??= displayError;
        }

        return firstError is null ? (true, null) : (false, firstError);
    }
}
