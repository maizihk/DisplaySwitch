#pragma once

#include "MediaKeys.h"

namespace DisplaySwitcher::Native
{
    class MediaKeyWatcher final
    {
    public:
        using Callback = std::function<void(MediaKeyAction)>;

        MediaKeyWatcher(HWND window, Callback callback);
        ~MediaKeyWatcher();
        MediaKeyWatcher(MediaKeyWatcher const&) = delete;
        MediaKeyWatcher& operator=(MediaKeyWatcher const&) = delete;

        void HandleRawInput(HRAWINPUT input) const;
        bool KeyboardRegistered() const noexcept { return keyboardRegistered_; }
        bool ConsumerControlRegistered() const noexcept { return consumerControlRegistered_; }

    private:
        static bool Register(HWND window, USHORT usagePage, USHORT usage) noexcept;
        static void Unregister(USHORT usagePage, USHORT usage) noexcept;
        void HandleHid(RAWINPUT const& input) const;

        Callback callback_;
        bool keyboardRegistered_{};
        bool consumerControlRegistered_{};
    };
}
