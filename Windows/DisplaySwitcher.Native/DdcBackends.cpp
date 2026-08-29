#include "pch.h"
#include "DdcBackends.h"
#include "Diagnostics.h"

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

    std::wstring Quote(std::wstring const& value)
    {
        std::wstring result = L"\"";
        unsigned slashes{};
        for (auto character : value)
        {
            if (character == L'\\') { ++slashes; continue; }
            if (character == L'\"')
            {
                result.append(slashes * 2 + 1, L'\\'); result.push_back(character); slashes = 0; continue;
            }
            result.append(slashes, L'\\'); slashes = 0; result.push_back(character);
        }
        result.append(slashes * 2, L'\\'); result.push_back(L'\"'); return result;
    }

    std::wstring HexCode(DdcVcpCode code)
    {
        wchar_t value[5]{};
        swprintf_s(value, L"%02X", static_cast<unsigned>(code));
        return value;
    }

    struct ProcessResult
    {
        bool completed{};
        bool canceled{};
        DWORD exitCode{};
        std::wstring error;
    };

    ProcessResult RunProcess(std::wstring const& executable, std::wstring command,
        DdcCancellationToken const& cancellation)
    {
        std::vector<wchar_t> mutableCommand(command.begin(), command.end()); mutableCommand.push_back(L'\0');
        STARTUPINFOW startup{ sizeof(startup) }; PROCESS_INFORMATION process{};
        if (!CreateProcessW(executable.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process))
            return { false, false, 0, L"无法启动 ControlMyMonitor，错误 " + std::to_wstring(GetLastError()) };
        CloseHandle(process.hThread);
        DWORD wait{};
        for (int elapsed = 0; elapsed < 5000; elapsed += 25)
        {
            if (cancellation.IsCanceled())
            {
                TerminateProcess(process.hProcess, ERROR_CANCELLED); WaitForSingleObject(process.hProcess, 1000);
                CloseHandle(process.hProcess); return { false, true, 0, L"操作已取消" };
            }
            wait = WaitForSingleObject(process.hProcess, 25);
            if (wait == WAIT_OBJECT_0) break;
        }
        if (wait != WAIT_OBJECT_0)
        {
            TerminateProcess(process.hProcess, ERROR_TIMEOUT); CloseHandle(process.hProcess);
            return { false, false, 0, L"ControlMyMonitor 等待超时" };
        }
        DWORD exitCode{}; GetExitCodeProcess(process.hProcess, &exitCode); CloseHandle(process.hProcess);
        return { true, false, exitCode, {} };
    }

    class NativeDdcBackend final : public IDdcBackend
    {
    public:
        std::wstring Key() const override { return L"native_ddc"; }
        std::wstring DisplayName() const override { return L"Windows 原生 DDC/CI"; }
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

    class ControlMyMonitorBackend final : public IDdcBackend
    {
    public:
        explicit ControlMyMonitorBackend(std::wstring executable) : executable_(std::move(executable)) {}
        std::wstring Key() const override { return L"control_my_monitor"; }
        std::wstring DisplayName() const override { return L"ControlMyMonitor 硬件 DDC/CI"; }
        DdcBackendStatus Status() const override
        {
            std::error_code error;
            auto available = std::filesystem::is_regular_file(executable_, error);
            return available && !error
                ? DdcBackendStatus{ DdcAvailability::Available, L"ControlMyMonitor 硬件 DDC/CI 可用" }
                : DdcBackendStatus{ DdcAvailability::TemporarilyUnavailable, L"ControlMyMonitor 程序当前不可用" };
        }
        DdcEnumerationResult Enumerate(DdcCancellationToken const&) override
        { return { false, DdcErrorKind::Unsupported, L"本轮不使用 ControlMyMonitor 枚举", {}, false }; }
        DdcCapabilities Capabilities(std::wstring const& monitorId, DdcCancellationToken const& cancellation) override
        {
            auto status = Status();
            if (cancellation.IsCanceled()) status = { DdcAvailability::TemporarilyUnavailable, L"操作已取消" };
            if (monitorId.empty()) status = { DdcAvailability::Unsupported, L"未配置 ControlMyMonitor 稳定显示器字符串" };
            return { status, false, {}, {} };
        }
        DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) override
        {
            auto command = Quote(executable_) + L" /GetValue " + Quote(monitorId) + L" " + HexCode(code);
            auto result = RunProcess(executable_, std::move(command), cancellation);
            if (result.canceled) return { false, 0, 0, DdcErrorKind::Canceled, result.error };
            if (!result.completed) return { false, 0, 0, DdcErrorKind::ReadFailed, result.error };
            return { true, static_cast<int>(result.exitCode), 100, DdcErrorKind::None, {} };
        }
        DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) override
        {
            auto command = Quote(executable_) + L" /SetValue " + Quote(monitorId) + L" " + HexCode(code) + L" " + std::to_wstring(value);
            auto result = RunProcess(executable_, std::move(command), cancellation);
            if (result.canceled) return { false, DdcErrorKind::Canceled, result.error };
            if (!result.completed) return { false, DdcErrorKind::WriteFailed, result.error };
            if (result.exitCode != 0) return { false, DdcErrorKind::WriteFailed,
                L"ControlMyMonitor 返回退出码 " + std::to_wstring(result.exitCode) };
            return { true, DdcErrorKind::None, {} };
        }

    private:
        std::wstring executable_;
    };
}

namespace DisplaySwitcher::Native
{
    DdcBackendSet::DdcBackendSet(AppConfig const& config) :
        native_(std::make_unique<NativeDdcBackend>()),
        controlMyMonitor_(std::make_unique<ControlMyMonitorBackend>(config.controlMyMonitorPath))
    {
    }

    IDdcBackend* DdcBackendSet::Lookup(std::wstring const& key) const noexcept
    {
        if (key == L"native_ddc") return native_.get();
        if (key == L"control_my_monitor") return controlMyMonitor_.get();
        return nullptr;
    }
}
