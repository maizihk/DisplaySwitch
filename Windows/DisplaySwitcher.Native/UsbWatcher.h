#pragma once
#include "UsbLearning.h"

namespace DisplaySwitcher::Native
{
    struct UsbDeviceInfo
    {
        int vendorId{};
        int productId{};
        std::wstring name;
        std::wstring pnpDeviceId;

        std::wstring DisplayName() const;
        UsbLearningDevice LearningDevice() const;
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
        static DWORD CALLBACK OnDeviceNotification(HCMNOTIFICATION notification, void* context,
            CM_NOTIFY_ACTION action, PCM_NOTIFY_EVENT_DATA eventData, DWORD eventDataSize);
        void Poll(std::stop_token token);
        std::atomic<int> vendorId_;
        std::atomic<int> productId_;
        PresenceCallback callback_;
        HANDLE changeEvent_{};
        HCMNOTIFICATION notification_{};
        std::atomic<bool> notificationsEnabled_{};
        std::jthread thread_;
    };
}
