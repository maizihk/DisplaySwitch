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
        using PresenceCallback = std::function<void(uint64_t, bool)>;

        UsbWatcher(int vendorId, int productId, PresenceCallback callback);
        ~UsbWatcher();
        UsbWatcher(UsbWatcher const&) = delete;
        UsbWatcher& operator=(UsbWatcher const&) = delete;

        void Reconfigure(int vendorId, int productId, std::wstring localReference, uint64_t generation);
        bool IsPresent() const;
        static std::vector<UsbDeviceInfo> EnumerateDevices();

    private:
        static DWORD CALLBACK OnDeviceNotification(HCMNOTIFICATION notification, void* context,
            CM_NOTIFY_ACTION action, PCM_NOTIFY_EVENT_DATA eventData, DWORD eventDataSize);
        void Poll(std::stop_token token);
        mutable std::mutex configurationMutex_;
        int vendorId_;
        int productId_;
        std::wstring localReference_;
        uint64_t generation_{};
        std::optional<bool> pendingTargetPresence_;
        PresenceCallback callback_;
        HANDLE changeEvent_{};
        HCMNOTIFICATION notification_{};
        std::atomic<bool> notificationsEnabled_{};
        std::jthread thread_;
    };
}
