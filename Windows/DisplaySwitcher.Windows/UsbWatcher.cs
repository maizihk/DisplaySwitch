using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace DisplaySwitcher.Windows;

internal sealed record UsbDeviceInfo(int VendorId, int ProductId, string Name, string PnpDeviceId)
{
    public string DisplayName => $"{Name} ({VendorId:X4}:{ProductId:X4})";
}

internal sealed partial class UsbWatcher : IDisposable
{
    public event Action<bool>? PresenceChanged;

    private readonly System.Threading.Timer _timer;
    private int _vendorId;
    private int _productId;
    private bool? _lastPresence;
    private int _polling;

    public UsbWatcher(int vendorId, int productId)
    {
        _vendorId = vendorId;
        _productId = productId;
        _timer = new System.Threading.Timer(_ => Poll(), null, TimeSpan.Zero, TimeSpan.FromMilliseconds(700));
    }

    public void Reconfigure(int vendorId, int productId)
    {
        _vendorId = vendorId;
        _productId = productId;
        _lastPresence = null;
    }

    public bool IsPresent() => EnumerateDevices().Any(x => x.VendorId == _vendorId && x.ProductId == _productId);

    private void Poll()
    {
        if (Interlocked.Exchange(ref _polling, 1) != 0) return;
        try
        {
            var present = IsPresent();
            if (_lastPresence.HasValue && _lastPresence.Value != present)
                PresenceChanged?.Invoke(present);
            _lastPresence = present;
        }
        catch { }
        finally { Interlocked.Exchange(ref _polling, 0); }
    }

    public static List<UsbDeviceInfo> EnumerateDevices()
    {
        var devices = new List<UsbDeviceInfo>();
        var deviceSet = SetupDiGetClassDevs(IntPtr.Zero, "USB", IntPtr.Zero, DigcfPresent | DigcfAllClasses);
        if (deviceSet == InvalidHandleValue) return devices;

        try
        {
            for (uint index = 0; ; index++)
            {
                var info = new SpDevinfoData { Size = (uint)Marshal.SizeOf<SpDevinfoData>() };
                if (!SetupDiEnumDeviceInfo(deviceSet, index, ref info)) break;

                var instance = new StringBuilder(1024);
                if (!SetupDiGetDeviceInstanceId(deviceSet, ref info, instance, instance.Capacity, out _)) continue;
                var pnp = instance.ToString();
                var match = VidPidRegex().Match(pnp);
                if (!match.Success) continue;

                var name = ReadDeviceProperty(deviceSet, ref info, SpdrpFriendlyName)
                    ?? ReadDeviceProperty(deviceSet, ref info, SpdrpDeviceDesc)
                    ?? "USB 设备";
                devices.Add(new UsbDeviceInfo(
                    Convert.ToInt32(match.Groups[1].Value, 16),
                    Convert.ToInt32(match.Groups[2].Value, 16),
                    name,
                    pnp));
            }
        }
        finally { SetupDiDestroyDeviceInfoList(deviceSet); }

        return devices.GroupBy(x => (x.VendorId, x.ProductId, x.Name)).Select(x => x.First())
            .OrderBy(x => x.DisplayName).ToList();
    }

    private static string? ReadDeviceProperty(IntPtr deviceSet, ref SpDevinfoData info, uint property)
    {
        var buffer = new byte[2048];
        if (!SetupDiGetDeviceRegistryProperty(
            deviceSet, ref info, property, out _, buffer, (uint)buffer.Length, out _)) return null;
        return Encoding.Unicode.GetString(buffer).TrimEnd('\0');
    }

    private const uint DigcfPresent = 0x00000002;
    private const uint DigcfAllClasses = 0x00000004;
    private const uint SpdrpDeviceDesc = 0x00000000;
    private const uint SpdrpFriendlyName = 0x0000000C;
    private static readonly IntPtr InvalidHandleValue = new(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDevinfoData
    {
        public uint Size;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        IntPtr classGuid, string? enumerator, IntPtr parent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInfo(
        IntPtr deviceInfoSet, uint memberIndex, ref SpDevinfoData deviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInstanceId(
        IntPtr deviceInfoSet, ref SpDevinfoData deviceInfoData,
        StringBuilder deviceInstanceId, int deviceInstanceIdSize, out int requiredSize);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceRegistryProperty(
        IntPtr deviceInfoSet, ref SpDevinfoData deviceInfoData, uint property,
        out uint propertyRegDataType, byte[] propertyBuffer, uint propertyBufferSize, out uint requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [GeneratedRegex(@"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase)]
    private static partial Regex VidPidRegex();

    public void Dispose() => _timer.Dispose();
}
