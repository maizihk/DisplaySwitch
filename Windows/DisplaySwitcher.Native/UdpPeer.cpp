#include "pch.h"
#include "Diagnostics.h"
#include "UdpPeer.h"

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    std::wstring SocketError(int code)
    {
        return L"Winsock 错误 " + std::to_wstring(code);
    }
}

namespace DisplaySwitcher::Native
{
    UdpPeer::UdpPeer(MessageCallback messageCallback, ErrorCallback errorCallback) :
        messageCallback_(std::move(messageCallback)), errorCallback_(std::move(errorCallback))
    {
        WSADATA data{};
        winsockStarted_ = WSAStartup(MAKEWORD(2, 2), &data) == 0;
        if (!winsockStarted_) Report(L"无法初始化网络组件");
    }

    UdpPeer::~UdpPeer()
    {
        Stop();
        if (winsockStarted_) WSACleanup();
    }

    void UdpPeer::Start(int port)
    {
        Stop();
        if (!winsockStarted_) return;
        auto socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket == INVALID_SOCKET)
        {
            Report(L"无法创建 UDP socket：" + SocketError(WSAGetLastError()));
            return;
        }
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons(static_cast<u_short>(port));
        if (bind(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR)
        {
            auto error = WSAGetLastError();
            closesocket(socket);
            Report(L"无法监听端口 " + std::to_wstring(port) + L"：" + SocketError(error));
            return;
        }
        {
            std::scoped_lock lock(mutex_);
            socket_ = socket;
        }
        receiveThread_ = std::jthread([this, socket](std::stop_token token) { Receive(token, socket); });
    }

    void UdpPeer::Stop()
    {
        receiveThread_.request_stop();
        SOCKET socket{};
        {
            std::scoped_lock lock(mutex_);
            socket = socket_;
            socket_ = INVALID_SOCKET;
        }
        if (socket != INVALID_SOCKET)
        {
            shutdown(socket, SD_BOTH);
            closesocket(socket);
        }
        if (receiveThread_.joinable()) receiveThread_.join();
    }

    void UdpPeer::Receive(std::stop_token token, SOCKET socket)
    {
        while (!token.stop_requested())
        {
            fd_set readers;
            FD_ZERO(&readers);
            FD_SET(socket, &readers);
            timeval timeout{ 0, 200000 };
            auto selected = select(0, &readers, nullptr, nullptr, &timeout);
            if (selected == 0) continue;
            if (selected == SOCKET_ERROR)
            {
                if (!token.stop_requested()) Report(L"接收失败：" + SocketError(WSAGetLastError()));
                break;
            }
            char buffer[8192]{};
            auto received = recvfrom(socket, buffer, static_cast<int>(sizeof(buffer)), 0, nullptr, nullptr);
            if (received == SOCKET_ERROR)
            {
                if (!token.stop_requested()) Report(L"接收失败：" + SocketError(WSAGetLastError()));
                break;
            }
            try
            {
                auto object = JsonObject::Parse(to_hstring(std::string(buffer, received)));
                PeerMessage message;
                message.version = static_cast<int>(object.GetNamedNumber(L"version", 0));
                message.type = object.GetNamedString(L"type", L"").c_str();
                message.eventId = object.GetNamedString(L"eventID", L"").c_str();
                message.source = object.GetNamedString(L"source", L"").c_str();
                message.target = object.GetNamedString(L"target", L"").c_str();
                message.timestamp = object.GetNamedNumber(L"timestamp", 0);
                message.pairingCode = object.GetNamedString(L"pairingCode", L"").c_str();
                if (object.HasKey(L"wakeSucceeded"))
                {
                    auto value = object.GetNamedValue(L"wakeSucceeded");
                    if (value.ValueType() == JsonValueType::Boolean) message.wakeSucceeded = value.GetBoolean();
                }
                if (messageCallback_) messageCallback_(message);
                if (message.type != L"status_probe" && message.type != L"status_response")
                    WriteDiagnostic("udp.receive parsed=1");
            }
            catch (...) {}
        }
    }

    void UdpPeer::Send(PeerMessage const& message, std::wstring const& host, int port)
    {
        if (host.empty()) return;
        auto trace = message.type != L"status_probe" && message.type != L"status_response";
        auto started = std::chrono::steady_clock::now();
        SOCKET socket;
        {
            std::scoped_lock lock(mutex_);
            socket = socket_;
        }
        if (socket == INVALID_SOCKET) return;

        JsonObject object;
        object.Insert(L"version", JsonValue::CreateNumberValue(message.version));
        object.Insert(L"type", JsonValue::CreateStringValue(message.type));
        object.Insert(L"eventID", JsonValue::CreateStringValue(message.eventId));
        object.Insert(L"source", JsonValue::CreateStringValue(message.source));
        object.Insert(L"target", JsonValue::CreateStringValue(message.target));
        object.Insert(L"timestamp", JsonValue::CreateNumberValue(message.timestamp));
        object.Insert(L"pairingCode", JsonValue::CreateStringValue(message.pairingCode));
        if (message.wakeSucceeded)
            object.Insert(L"wakeSucceeded", JsonValue::CreateBooleanValue(*message.wakeSucceeded));
        auto data = to_string(object.Stringify());

        addrinfoW hints{};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        hints.ai_protocol = IPPROTO_UDP;
        addrinfoW* addresses{};
        auto service = std::to_wstring(port);
        auto result = GetAddrInfoW(host.c_str(), service.c_str(), &hints, &addresses);
        auto resolvedMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        if (result != 0)
        {
            if (trace) WriteDiagnostic("udp.send resolve_ok=0 resolve_ms=" + std::to_string(resolvedMilliseconds));
            Report(L"发送失败：无法解析主机 " + host);
            return;
        }
        auto sent = sendto(socket, data.data(), static_cast<int>(data.size()), 0,
            addresses->ai_addr, static_cast<int>(addresses->ai_addrlen));
        FreeAddrInfoW(addresses);
        auto totalMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        if (trace) WriteDiagnostic("udp.send resolve_ok=1 resolve_ms=" + std::to_string(resolvedMilliseconds) +
            " total_ms=" + std::to_string(totalMilliseconds));
        if (sent == SOCKET_ERROR) Report(L"发送失败：" + SocketError(WSAGetLastError()));
    }

    double UdpPeer::TimestampNow()
    {
        auto now = std::chrono::system_clock::now().time_since_epoch();
        return std::chrono::duration<double>(now).count();
    }

    void UdpPeer::Report(std::wstring const& message) const
    {
        if (errorCallback_) errorCallback_(message);
    }
}
