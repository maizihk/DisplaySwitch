#include "pch.h"
#include "MediaKeyWatcher.h"

namespace DisplaySwitcher::Native
{
    bool MediaKeyWatcher::Register(HWND window, USHORT usagePage, USHORT usage) noexcept
    {
        RAWINPUTDEVICE device{ usagePage, usage, MediaKeyRawInputRegistrationFlags(), window };
        return RegisterRawInputDevices(&device, 1, sizeof(device)) != FALSE;
    }

    void MediaKeyWatcher::Unregister(USHORT usagePage, USHORT usage) noexcept
    {
        RAWINPUTDEVICE device{ usagePage, usage, RIDEV_REMOVE, nullptr };
        static_cast<void>(RegisterRawInputDevices(&device, 1, sizeof(device)));
    }

    MediaKeyWatcher::MediaKeyWatcher(HWND window, Callback callback) : callback_(std::move(callback))
    {
        // No RIDEV_NOLEGACY: DisplaySwitcher observes the final media action and
        // leaves the system's normal handling untouched.
        keyboardRegistered_ = Register(window, 0x01, 0x06);
        consumerControlRegistered_ = Register(window, 0x0C, 0x01);
    }

    MediaKeyWatcher::~MediaKeyWatcher()
    {
        if (keyboardRegistered_) Unregister(0x01, 0x06);
        if (consumerControlRegistered_) Unregister(0x0C, 0x01);
    }

    void MediaKeyWatcher::HandleRawInput(HRAWINPUT input) const
    {
        UINT size{};
        if (GetRawInputData(input, RID_INPUT, nullptr, &size, sizeof(RAWINPUTHEADER)) != 0 || !size) return;
        std::vector<std::byte> bytes(size);
        if (GetRawInputData(input, RID_INPUT, bytes.data(), &size, sizeof(RAWINPUTHEADER)) != size) return;
        auto raw = reinterpret_cast<RAWINPUT const*>(bytes.data());
        if (raw->header.dwType == RIM_TYPEKEYBOARD)
        {
            auto action = NormalizeKeyboardMediaKey(raw->data.keyboard.VKey,
                (raw->data.keyboard.Flags & RI_KEY_BREAK) == 0);
            if (action && callback_) callback_(*action);
        }
        else if (raw->header.dwType == RIM_TYPEHID)
        {
            HandleHid(*raw);
        }
    }

    void MediaKeyWatcher::HandleHid(RAWINPUT const& input) const
    {
        UINT preparsedSize{};
        if (GetRawInputDeviceInfoW(input.header.hDevice, RIDI_PREPARSEDDATA,
            nullptr, &preparsedSize) == static_cast<UINT>(-1) || !preparsedSize) return;
        std::vector<std::byte> preparsedBytes(preparsedSize);
        if (GetRawInputDeviceInfoW(input.header.hDevice, RIDI_PREPARSEDDATA,
            preparsedBytes.data(), &preparsedSize) == static_cast<UINT>(-1)) return;
        auto preparsed = reinterpret_cast<PHIDP_PREPARSED_DATA>(preparsedBytes.data());
        HIDP_CAPS caps{};
        if (HidP_GetCaps(preparsed, &caps) != HIDP_STATUS_SUCCESS
            || caps.UsagePage != 0x0C || caps.Usage != 0x01) return;
        auto maximumUsages = HidP_MaxUsageListLength(HidP_Input, 0x0C, preparsed);
        if (!maximumUsages) return;

        auto const& hid = input.data.hid;
        for (DWORD reportIndex = 0; reportIndex < hid.dwCount; ++reportIndex)
        {
            auto report = reinterpret_cast<PCHAR>(const_cast<BYTE*>(hid.bRawData)
                + reportIndex * hid.dwSizeHid);
            std::vector<USAGE> usages(maximumUsages);
            ULONG usageCount = maximumUsages;
            if (HidP_GetUsages(HidP_Input, 0x0C, 0, usages.data(), &usageCount,
                preparsed, report, hid.dwSizeHid) != HIDP_STATUS_SUCCESS) continue;
            for (ULONG index = 0; index < usageCount; ++index)
            {
                auto action = NormalizeConsumerControlUsage(usages[index], true);
                if (action && callback_) callback_(*action);
            }
        }
    }
}
