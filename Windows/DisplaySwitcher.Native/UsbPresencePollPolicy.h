#pragma once

namespace DisplaySwitcher::Native
{
    enum class UsbDeviceNotificationKind
    {
        Other,
        Present,
        Removed,
    };

    inline std::optional<bool> TargetUsbPresenceFromNotification(UsbDeviceNotificationKind kind,
        std::wstring const& localReference, std::wstring const& instanceId)
    {
        constexpr std::wstring_view prefix = L"usb:pnp:";
        if (kind == UsbDeviceNotificationKind::Other || instanceId.empty() ||
            localReference.size() <= prefix.size() ||
            _wcsnicmp(localReference.c_str(), prefix.data(), prefix.size()) != 0 ||
            _wcsicmp(localReference.c_str() + prefix.size(), instanceId.c_str()) != 0)
            return std::nullopt;
        return kind == UsbDeviceNotificationKind::Present;
    }

    class UsbPresencePollPolicy final
    {
    public:
        static constexpr DWORD NotificationFollowupIntervalMilliseconds = 100;
        static constexpr DWORD NotificationSettlingIntervalMilliseconds = 250;
        static constexpr int NotificationFastPollCount = 10;
        static constexpr int NotificationSettlingPollCount = 8;
        static constexpr int NotificationFollowupPollCount = NotificationFastPollCount + NotificationSettlingPollCount;

        void NotificationReceived() noexcept
        {
            followupPollsRemaining_ = NotificationFollowupPollCount;
        }

        void WaitTimedOut() noexcept
        {
            if (followupPollsRemaining_ > 0) --followupPollsRemaining_;
        }

        DWORD NextWaitMilliseconds(bool notificationsEnabled) const noexcept
        {
            if (followupPollsRemaining_ > NotificationSettlingPollCount) return NotificationFollowupIntervalMilliseconds;
            if (followupPollsRemaining_ > 0) return NotificationSettlingIntervalMilliseconds;
            return notificationsEnabled ? 2000 : 250;
        }

        int FollowupPollsRemaining() const noexcept { return followupPollsRemaining_; }

    private:
        int followupPollsRemaining_{};
    };
}
