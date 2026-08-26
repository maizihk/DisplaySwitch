#pragma once

namespace DisplaySwitcher::Native
{
    struct PeerMessage
    {
        int version{};
        std::wstring type;
        std::wstring eventId;
        std::wstring source;
        std::wstring target;
        double timestamp{};
        std::wstring pairingCode;
        std::optional<bool> wakeSucceeded;
    };

    class UdpPeer
    {
    public:
        using MessageCallback = std::function<void(PeerMessage const&)>;
        using ErrorCallback = std::function<void(std::wstring const&)>;

        UdpPeer(MessageCallback messageCallback, ErrorCallback errorCallback);
        ~UdpPeer();
        UdpPeer(UdpPeer const&) = delete;
        UdpPeer& operator=(UdpPeer const&) = delete;

        void Start(int port);
        void Stop();
        void Send(PeerMessage const& message, std::wstring const& host, int port);
        static double TimestampNow();

    private:
        void Receive(std::stop_token token, SOCKET socket);
        void Report(std::wstring const& message) const;
        MessageCallback messageCallback_;
        ErrorCallback errorCallback_;
        std::mutex mutex_;
        SOCKET socket_{ INVALID_SOCKET };
        std::jthread receiveThread_;
        bool winsockStarted_{};
    };
}
