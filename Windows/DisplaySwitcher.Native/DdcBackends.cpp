#include "pch.h"
#include "DdcBackends.h"

namespace
{
    using namespace DisplaySwitcher::Native;

    struct NativeMonitor
    {
        DdcMonitorInfo info;
        NativeMonitorHandleLease handles{ [](HANDLE handle) { DestroyPhysicalMonitor(handle); } };
    };

    struct NativeEnumeration
    {
        bool success{ true };
        bool partialFailure{};
        DWORD error{};
        std::vector<NativeMonitor> monitors;
    };

    std::mutex nativeDdcMutex;

    NativeEnumeration EnumerateNativeMonitors()
    {
        NativeEnumeration result;
        SetLastError(ERROR_SUCCESS);
        auto enumerated = EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL
        {
            auto& state = *reinterpret_cast<NativeEnumeration*>(parameter);
            MONITORINFOEXW monitorInfo{ sizeof(monitorInfo) };
            if (!GetMonitorInfoW(monitor, &monitorInfo)) { state.partialFailure = true; return TRUE; }
            DISPLAY_DEVICEW displayDevice{ sizeof(displayDevice) };
            if (!EnumDisplayDevicesW(monitorInfo.szDevice, 0, &displayDevice, EDD_GET_DEVICE_INTERFACE_NAME))
            { state.partialFailure = true; return TRUE; }
            std::wstring baseId = CanonicalDdcMonitorId(displayDevice.DeviceID[0] ? displayDevice.DeviceID : displayDevice.DeviceKey);
            std::wstring friendlyName = displayDevice.DeviceString[0] ? displayDevice.DeviceString : monitorInfo.szDevice;
            DWORD count{};
            if (baseId.empty()) { state.partialFailure = true; return TRUE; }
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count))
            { state.partialFailure = true; state.error = GetLastError(); return TRUE; }
            if (count == 0) return TRUE;
            std::vector<PHYSICAL_MONITOR> physical(count);
            if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical.data()))
            { state.partialFailure = true; state.error = GetLastError(); return TRUE; }

            auto found = std::find_if(state.monitors.begin(), state.monitors.end(), [&](auto const& item)
                { return _wcsicmp(item.info.id.c_str(), baseId.c_str()) == 0; });
            if (found == state.monitors.end())
            {
                NativeMonitor item;
                item.info = { baseId, friendlyName, monitorInfo.szDevice };
                state.monitors.push_back(std::move(item));
                found = std::prev(state.monitors.end());
            }
            for (DWORD index = 0; index < count; ++index)
            {
                if (physical[index].szPhysicalMonitorDescription[0]
                    && (_wcsicmp(friendlyName.c_str(), L"Generic PnP Monitor") == 0 || friendlyName == monitorInfo.szDevice))
                    found->info.displayName = physical[index].szPhysicalMonitorDescription;
                found->handles.Add(physical[index].hPhysicalMonitor);
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&result));
        if (!enumerated)
        {
            result.success = false;
            result.error = GetLastError();
        }
        return result;
    }

    std::vector<DdcMonitorInfo> PublicMonitorInfo(std::vector<NativeMonitor> const& native)
    {
        std::vector<DdcMonitorInfo> result;
        for (auto const& monitor : native) result.push_back(monitor.info);
        return NormalizeDdcMonitorCollection(std::move(result));
    }

    template<typename Action>
    auto WithNativeMonitor(std::wstring const& monitorId, Action const& action,
        std::optional<NativeEnumeration>* cachedEnumeration = nullptr)
    {
        std::scoped_lock lock(nativeDdcMutex);
        NativeEnumeration current;
        NativeEnumeration* enumeration = &current;
        if (cachedEnumeration)
        {
            if (!*cachedEnumeration) cachedEnumeration->emplace(EnumerateNativeMonitors());
            enumeration = &cachedEnumeration->value();
        }
        else current = EnumerateNativeMonitors();
        auto canonicalId = CanonicalDdcMonitorId(monitorId);
        auto found = std::find_if(enumeration->monitors.begin(), enumeration->monitors.end(), [&](auto const& monitor)
        { return _wcsicmp(monitor.info.id.c_str(), canonicalId.c_str()) == 0; });
        if (!enumeration->success || found == enumeration->monitors.end() || found->handles.Handles().empty())
        {
            using Result = decltype(action(HANDLE{}));
            auto message = !enumeration->success ? L"Windows 原生显示器枚举失败，错误 " + std::to_wstring(enumeration->error)
                : L"找不到按稳定 ID 配置的原生 DDC/CI 显示器";
            if (cachedEnumeration) cachedEnumeration->reset();
            if constexpr (std::is_same_v<Result, DdcValueResult>)
                return Result{ false, 0, 0, DdcErrorKind::MonitorUnavailable, std::move(message) };
            else
                return Result{ false, DdcErrorKind::MonitorUnavailable, std::move(message) };
        }
        using Result = decltype(action(HANDLE{}));
        Result result{};
        for (auto handle : found->handles.Handles())
        {
            result = action(handle);
            if (result.success || result.error == DdcErrorKind::Canceled) break;
        }
        if (cachedEnumeration && !result.success && result.error != DdcErrorKind::Canceled)
            cachedEnumeration->reset();
        return result;
    }

    class NativeDdcBackend final : public IDdcBackend
    {
    public:
        DdcBackendStatus Status() const override { return { DdcAvailability::Available, L"Windows 物理显示器 DDC/CI" }; }

        DdcEnumerationResult Enumerate(DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消", {}, false };
            std::scoped_lock lock(nativeDdcMutex);
            auto native = EnumerateNativeMonitors();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消", {}, false };
            if (!native.success || (native.partialFailure && native.monitors.empty())) return { false, DdcErrorKind::BackendUnavailable,
                L"Windows 原生显示器枚举失败，错误 " + std::to_wstring(native.error), {}, false };
            auto monitors = PublicMonitorInfo(native.monitors);
            return { true, DdcErrorKind::None, native.partialFailure ? L"部分显示器无法通过 Windows 原生接口枚举" : L"",
                std::move(monitors), !native.partialFailure };
        }

        DdcCapabilities Capabilities(std::wstring const& monitorId,
            DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled())
                return { { DdcAvailability::TemporarilyUnavailable, L"操作已取消" }, true, {}, {} };
            std::scoped_lock lock(nativeDdcMutex);
            auto enumeration = EnumerateNativeMonitors();
            if (!enumeration.success) return { { DdcAvailability::TemporarilyUnavailable,
                L"Windows 原生显示器枚举失败，错误 " + std::to_wstring(enumeration.error) }, true, {}, {} };
            auto canonicalId = CanonicalDdcMonitorId(monitorId);
            auto found = std::find_if(enumeration.monitors.begin(), enumeration.monitors.end(), [&](auto const& monitor)
            { return _wcsicmp(monitor.info.id.c_str(), canonicalId.c_str()) == 0; });
            auto available = found != enumeration.monitors.end() && !found->handles.Handles().empty();
            if (!available) return { { DdcAvailability::TemporarilyUnavailable, L"显示器当前未连接" }, true, {}, {} };
            // MCCS capability strings are optional and frequently incomplete. Unknown means
            // that the actual Get/Set VCP call is the authoritative capability probe.
            return { { DdcAvailability::Available, L"原生硬件 DDC/CI 可用" }, false, {}, {} };
        }

        DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled()) return { false, 0, 0, DdcErrorKind::Canceled, L"操作已取消" };
            return WithNativeMonitor(monitorId, [&](HANDLE handle)
            {
                DWORD current{}, maximum{}; MC_VCP_CODE_TYPE type{}; SetLastError(ERROR_SUCCESS);
                auto success = GetVCPFeatureAndVCPFeatureReply(handle, static_cast<BYTE>(code), &type, &current, &maximum) != FALSE;
                auto error = GetLastError();
                if (cancellation.IsCanceled()) return DdcValueResult{ false, 0, 0, DdcErrorKind::Canceled, L"操作已取消" };
                if (!success) return DdcValueResult{ false, 0, 0, DdcErrorKind::ReadFailed,
                    L"原生硬件 DDC/CI 读取失败，错误 " + std::to_wstring(error) };
                return DdcValueResult{ true, static_cast<int>(current), static_cast<int>(maximum), DdcErrorKind::None, {} };
            }, &cachedEnumeration_);
        }

        DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消" };
            return WithNativeMonitor(monitorId, [&](HANDLE handle)
            {
                SetLastError(ERROR_SUCCESS);
                auto success = SetVCPFeature(handle, static_cast<BYTE>(code), static_cast<DWORD>(value)) != FALSE;
                auto error = GetLastError();
                if (cancellation.IsCanceled()) return DdcWriteResult{ false, DdcErrorKind::Canceled, L"操作已取消" };
                if (!success) return DdcWriteResult{ false, DdcErrorKind::WriteFailed,
                    L"原生硬件 DDC/CI 写入失败，错误 " + std::to_wstring(error) };
                return DdcWriteResult{ true, DdcErrorKind::None, {} };
            }, &cachedEnumeration_);
        }

    private:
        std::optional<NativeEnumeration> cachedEnumeration_;
    };
}

namespace DisplaySwitcher::Native
{
    std::unique_ptr<IDdcBackend> CreateNativeDdcBackend()
    {
        return std::make_unique<NativeDdcBackend>();
    }
}
