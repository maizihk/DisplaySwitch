using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace DisplaySwitcher.Windows;

internal sealed record PeerMessage(
    int Version,
    string Type,
    string EventID,
    string Source,
    string Target,
    double Timestamp,
    string PairingCode,
    bool? WakeSucceeded = null);

internal sealed class UdpPeer : IDisposable
{
    public event Action<PeerMessage>? MessageReceived;
    public event Action<string>? Error;

    private UdpClient? _client;
    private CancellationTokenSource? _cts;
    private readonly JsonSerializerOptions _json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public void Start(int port)
    {
        Stop();
        try
        {
            _client = new UdpClient(new IPEndPoint(IPAddress.Any, port));
            _cts = new CancellationTokenSource();
            _ = ReceiveLoop(_cts.Token);
        }
        catch (Exception ex) { Error?.Invoke($"无法监听端口 {port}：{ex.Message}"); }
    }

    public async Task SendAsync(PeerMessage message, string host, int port)
    {
        try
        {
            if (_client is null || string.IsNullOrWhiteSpace(host)) return;
            var data = JsonSerializer.SerializeToUtf8Bytes(message, _json);
            await _client.SendAsync(data, new IPEndPoint(await ResolveAsync(host), port));
        }
        catch (Exception ex) { Error?.Invoke($"发送失败：{ex.Message}"); }
    }

    private static async Task<IPAddress> ResolveAsync(string host)
    {
        if (IPAddress.TryParse(host, out var address)) return address;
        return (await Dns.GetHostAddressesAsync(host)).First(x => x.AddressFamily == AddressFamily.InterNetwork);
    }

    private async Task ReceiveLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _client is not null)
        {
            try
            {
                var result = await _client.ReceiveAsync(token);
                var message = JsonSerializer.Deserialize<PeerMessage>(result.Buffer, _json);
                if (message is not null) MessageReceived?.Invoke(message);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex) { Error?.Invoke($"接收失败：{ex.Message}"); }
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        _client?.Dispose();
        _cts?.Dispose();
        _cts = null;
        _client = null;
    }

    public void Dispose() => Stop();
}
