#include "pch.h"
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
        wchar_t ids[16]{};
        swprintf_s(ids, L"%04X:%04X", vendorId, productId);
        return name + L" (" + ids + L")";
    }

    UsbWatcher::UsbWatcher(int vendorId, int productId, PresenceCallback callback) :
        vendorId_(vendorId), productId_(productId), callback_(std::move(callback)),
        thread_([this](std::stop_token token) { Poll(token); })
    {
    }

    UsbWatcher::~UsbWatcher()
    {
        thread_.request_stop();
    }

    void UsbWatcher::Reconfigure(int vendorId, int productId)
    {
        vendorId_.store(vendorId);
        productId_.store(productId);
    }

    bool UsbWatcher::IsPresent() const
    {
        auto vendor = vendorId_.load();
        auto product = productId_.load();
        auto devices = EnumerateDevices();
        return std::any_of(devices.begin(), devices.end(), [=](auto const& device)
        {
            return device.vendorId == vendor && device.productId == product;
        });
    }

    void UsbWatcher::Poll(std::stop_token token)
    {
        std::optional<bool> last;
        int lastVendor = vendorId_.load();
        int lastProduct = productId_.load();
        while (!token.stop_requested())
        {
            try
            {
                auto vendor = vendorId_.load();
                auto product = productId_.load();
                if (vendor != lastVendor || product != lastProduct)
                {
                    last.reset();
                    lastVendor = vendor;
                    lastProduct = product;
                }
                auto present = IsPresent();
                if (last.has_value() && *last != present && callback_) callback_(present);
                last = present;
            }
            catch (...) {}
            for (int elapsed = 0; elapsed < 700 && !token.stop_requested(); elapsed += 50)
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
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
            return std::tie(left.name, left.vendorId, left.productId) < std::tie(right.name, right.vendorId, right.productId);
        });
        devices.erase(std::unique(devices.begin(), devices.end(), [](auto const& left, auto const& right)
        {
            return left.vendorId == right.vendorId && left.productId == right.productId && left.name == right.name;
        }), devices.end());
        return devices;
    }
}
