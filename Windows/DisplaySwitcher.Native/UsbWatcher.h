#pragma once

namespace DisplaySwitcher::Native
{
    struct UsbDeviceInfo
    {
        int vendorId{};
        int productId{};
        std::wstring name;
        std::wstring pnpDeviceId;

        std::wstring DisplayName() const;
    };

    class UsbWatcher
    {
    public:
        using PresenceCallback = std::function<void(bool)>;

        UsbWatcher(int vendorId, int productId, PresenceCallback callback);
        ~UsbWatcher();
        UsbWatcher(UsbWatcher const&) = delete;
        UsbWatcher& operator=(UsbWatcher const&) = delete;

        void Reconfigure(int vendorId, int productId);
        bool IsPresent() const;
        static std::vector<UsbDeviceInfo> EnumerateDevices();

    private:
        void Poll(std::stop_token token);
        std::atomic<int> vendorId_;
        std::atomic<int> productId_;
        PresenceCallback callback_;
        std::jthread thread_;
    };
}
