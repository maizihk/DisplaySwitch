#include "pch.h"
#include "Diagnostics.h"
#include "UsbPresencePollPolicy.h"
#include "UsbWatcher.h"

namespace
{
    std::optional<int> Hex4(std::wstring const& text, std::wstring const& marker)
    {
        auto position = text.find(marker);
        if (position == std::wstring::npos || position + marker.size() + 4 > text.size()) return std::nullopt;
        wchar_t* end{};
        auto value = std::wcstol(text.c_str() + position + marker.size(), &end, 16);
        if (end != text.c_str() + position + marker.size() + 4) return std::nullopt;
        return static_cast<int>(value);
    }

    std::wstring ReadProperty(HDEVINFO set, SP_DEVINFO_DATA& info, DWORD property)
    {
        wchar_t buffer[1024]{};
        DWORD type{}, required{};
        if (!SetupDiGetDeviceRegistryPropertyW(set, &info, property, &type,
            reinterpret_cast<PBYTE>(buffer), sizeof(buffer), &required)) return {};
        return buffer;
    }
}

namespace DisplaySwitcher::Native
{
    std::wstring UsbDeviceInfo::DisplayName() const
    {
        return name;
    }

    UsbLearningDevice UsbDeviceInfo::LearningDevice() const
    {
        return { L"usb:pnp:" + pnpDeviceId, DisplayName(), vendorId, productId };
    }

    UsbWatcher::UsbWatcher(int vendorId, int productId, PresenceCallback callback) :
        vendorId_(vendorId), productId_(productId), callback_(std::move(callback))
    {
        changeEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        CM_NOTIFY_FILTER filter{};
        filter.cbSize = sizeof(filter);
        filter.Flags = CM_NOTIFY_FILTER_FLAG_ALL_DEVICE_INSTANCES;
        filter.FilterType = CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE;
        if (CM_Register_Notification(&filter, this, OnDeviceNotification, &notification_) != CR_SUCCESS)
            notification_ = nullptr;
        notificationsEnabled_.store(notification_ != nullptr);
        thread_ = std::jthread([this](std::stop_token token) { Poll(token); });
    }

    UsbWatcher::~UsbWatcher()
    {
        if (notification_)
        {
            CM_Unregister_Notification(notification_);
            notification_ = nullptr;
        }
        notificationsEnabled_.store(false);
        thread_.request_stop();
        if (changeEvent_) SetEvent(changeEvent_);
        if (thread_.joinable()) thread_.join();
        if (changeEvent_)
        {
            CloseHandle(changeEvent_);
            changeEvent_ = nullptr;
        }
    }

    void UsbWatcher::Reconfigure(int vendorId, int productId, std::wstring localReference, uint64_t generation)
    {
        {
            std::scoped_lock lock(configurationMutex_);
            vendorId_ = vendorId;
            productId_ = productId;
            localReference_ = std::move(localReference);
            generation_ = generation;
            pendingTargetPresence_.reset();
        }
        if (changeEvent_) SetEvent(changeEvent_);
    }

    DWORD CALLBACK UsbWatcher::OnDeviceNotification(HCMNOTIFICATION, void* context,
        CM_NOTIFY_ACTION action, PCM_NOTIFY_EVENT_DATA eventData, DWORD eventDataSize)
    {
        auto watcher = static_cast<UsbWatcher*>(context);
        if (!watcher) return ERROR_SUCCESS;
        auto kind = UsbDeviceNotificationKind::Other;
        if (action == CM_NOTIFY_ACTION_DEVICEINSTANCEENUMERATED || action == CM_NOTIFY_ACTION_DEVICEINSTANCESTARTED)
            kind = UsbDeviceNotificationKind::Present;
        else if (action == CM_NOTIFY_ACTION_DEVICEINSTANCEREMOVED)
            kind = UsbDeviceNotificationKind::Removed;
        std::optional<bool> targetPresence;
        if (eventData && eventDataSize >= sizeof(CM_NOTIFY_EVENT_DATA) &&
            eventData->FilterType == CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE)
        {
            std::scoped_lock lock(watcher->configurationMutex_);
            targetPresence = TargetUsbPresenceFromNotification(kind, watcher->localReference_, eventData->u.DeviceInstance.InstanceId);
            if (targetPresence) watcher->pendingTargetPresence_ = targetPresence;
        }
        if (watcher->changeEvent_) SetEvent(watcher->changeEvent_);
        return ERROR_SUCCESS;
    }

    bool UsbWatcher::IsPresent() const
    {
        int vendor{}, product{};
        std::wstring localReference;
        { std::scoped_lock lock(configurationMutex_); vendor = vendorId_; product = productId_; localReference = localReference_; }
        if (vendor < 0 || vendor > 0xFFFF || product < 0 || product > 0xFFFF) return false;
        auto devices = EnumerateDevices();
        return std::any_of(devices.begin(), devices.end(), [&](auto const& device)
        {
            return device.vendorId == vendor && device.productId == product &&
                (localReference.empty() || _wcsicmp(device.LearningDevice().localReference.c_str(), localReference.c_str()) == 0);
        });
    }

    void UsbWatcher::Poll(std::stop_token token)
    {
        std::optional<bool> last;
        UsbPresencePollPolicy pollPolicy;
        int lastVendor{}, lastProduct{};
        uint64_t lastGeneration{};
        { std::scoped_lock lock(configurationMutex_); lastVendor = vendorId_; lastProduct = productId_; lastGeneration = generation_; }
        std::wstring lastReference;
        std::optional<bool> authoritativePresence;
        ULONGLONG authoritativeUntil{};
        while (!token.stop_requested())
        {
            try
            {
                int vendor{}, product{};
                uint64_t generation{};
                std::wstring reference;
                std::optional<bool> targetPresence;
                {
                    std::scoped_lock lock(configurationMutex_);
                    vendor = vendorId_; product = productId_; reference = localReference_;
                    generation = generation_;
                    targetPresence = pendingTargetPresence_;
                    pendingTargetPresence_.reset();
                }
                if (generation != lastGeneration || vendor != lastVendor || product != lastProduct ||
                    _wcsicmp(reference.c_str(), lastReference.c_str()) != 0)
                {
                    last.reset();
                    authoritativePresence.reset();
                    lastVendor = vendor;
                    lastProduct = product;
                    lastGeneration = generation;
                    lastReference = reference;
                }
                bool present{};
                auto now = GetTickCount64();
                if (targetPresence)
                {
                    present = *targetPresence;
                    authoritativePresence = present;
                    authoritativeUntil = now + 1500;
                }
                else
                {
                    bool observed{};
                    if (vendor >= 0 && vendor <= 0xFFFF && product >= 0 && product <= 0xFFFF)
                    {
                        auto devices = EnumerateDevices();
                        observed = std::any_of(devices.begin(), devices.end(), [&](auto const& device)
                        {
                            return device.vendorId == vendor && device.productId == product &&
                                (reference.empty() || _wcsicmp(device.LearningDevice().localReference.c_str(), reference.c_str()) == 0);
                        });
                    }
                    if (authoritativePresence && now < authoritativeUntil && observed != *authoritativePresence)
                        present = *authoritativePresence;
                    else
                    {
                        present = observed;
                        if (now >= authoritativeUntil) authoritativePresence.reset();
                    }
                }
                {
                    std::scoped_lock lock(configurationMutex_);
                    if (generation != generation_) continue;
                }
                if ((!last.has_value() || *last != present) && callback_)
                {
                    callback_(generation, present);
                    WriteDiagnostic(targetPresence
                        ? (*targetPresence ? "usb.target_notification present=1" : "usb.target_notification present=0")
                        : (present ? "usb.poll_change present=1" : "usb.poll_change present=0"));
                }
                last = present;
            }
            catch (...) {}
            if (changeEvent_)
            {
                auto wait = WaitForSingleObject(changeEvent_,
                    pollPolicy.NextWaitMilliseconds(notificationsEnabled_.load()));
                if (wait == WAIT_OBJECT_0) pollPolicy.NotificationReceived();
                else if (wait == WAIT_TIMEOUT) pollPolicy.WaitTimedOut();
            }
            else
            {
                for (int elapsed = 0; elapsed < 250 && !token.stop_requested(); elapsed += 50)
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
        }
    }

    std::vector<UsbDeviceInfo> UsbWatcher::EnumerateDevices()
    {
        std::vector<UsbDeviceInfo> devices;
        HDEVINFO set = SetupDiGetClassDevsW(nullptr, L"USB", nullptr, DIGCF_PRESENT | DIGCF_ALLCLASSES);
        if (set == INVALID_HANDLE_VALUE) return devices;

        for (DWORD index = 0;; ++index)
        {
            SP_DEVINFO_DATA info{ sizeof(info) };
            if (!SetupDiEnumDeviceInfo(set, index, &info)) break;
            wchar_t instance[1024]{};
            if (!SetupDiGetDeviceInstanceIdW(set, &info, instance, ARRAYSIZE(instance), nullptr)) continue;
            std::wstring pnp(instance);
            std::transform(pnp.begin(), pnp.end(), pnp.begin(), ::towupper);
            auto vendor = Hex4(pnp, L"VID_");
            auto product = Hex4(pnp, L"PID_");
            if (!vendor || !product) continue;
            auto name = ReadProperty(set, info, SPDRP_FRIENDLYNAME);
            if (name.empty()) name = ReadProperty(set, info, SPDRP_DEVICEDESC);
            if (name.empty()) name = L"USB 设备";
            devices.push_back({ *vendor, *product, name, pnp });
        }
        SetupDiDestroyDeviceInfoList(set);

        std::sort(devices.begin(), devices.end(), [](auto const& left, auto const& right)
        {
            return std::tie(left.name, left.vendorId, left.productId, left.pnpDeviceId) <
                std::tie(right.name, right.vendorId, right.productId, right.pnpDeviceId);
        });
        devices.erase(std::unique(devices.begin(), devices.end(), [](auto const& left, auto const& right)
        {
            return _wcsicmp(left.pnpDeviceId.c_str(), right.pnpDeviceId.c_str()) == 0;
        }), devices.end());
        return devices;
    }
}
