#pragma once

namespace DisplaySwitcher::Native
{
    class UsbPresencePollPolicy final
    {
    public:
        static constexpr DWORD NotificationFollowupIntervalMilliseconds = 100;
        static constexpr int NotificationFollowupPollCount = 10;

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
            if (followupPollsRemaining_ > 0) return NotificationFollowupIntervalMilliseconds;
            return notificationsEnabled ? 2000 : 250;
        }

        int FollowupPollsRemaining() const noexcept { return followupPollsRemaining_; }

    private:
        int followupPollsRemaining_{};
    };
}
