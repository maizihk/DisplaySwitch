#pragma once
#include "UnboundProbeRouter.h"

namespace DisplaySwitcher::Native
{
    class UdpPeer
    {
    public:
        struct Datagram
        {
            std::string data;
            DatagramSource source;
        };
        using MessageCallback = std::function<void(Datagram const&)>;
        using ErrorCallback = std::function<void(std::wstring const&)>;

        UdpPeer(MessageCallback messageCallback, ErrorCallback errorCallback);
        ~UdpPeer();
        UdpPeer(UdpPeer const&) = delete;
        UdpPeer& operator=(UdpPeer const&) = delete;

        void Start(int port);
        void Stop();
        bool IsRunning() const;
        void SendRaw(std::string const& data, std::wstring const& host, int port, bool trace = true);
        static bool SourceMatches(DatagramSource const& source, std::wstring const& configuredHost, int configuredPort);
        static double TimestampNow();

    private:
        void Receive(std::stop_token token, SOCKET socket);
        void Report(std::wstring const& message) const;
        MessageCallback messageCallback_;
        ErrorCallback errorCallback_;
        mutable std::mutex mutex_;
        SOCKET socket_{ INVALID_SOCKET };
        std::jthread receiveThread_;
        bool winsockStarted_{};
    };
}
