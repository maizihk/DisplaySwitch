#include "pch.h"
#include "Diagnostics.h"
#include "SystemActions.h"

namespace
{
    using DisplaySwitcher::Native::ActionResult;
    using DisplaySwitcher::Native::DdcMonitorInfo;
    using DisplaySwitcher::Native::WriteDiagnostic;

    struct NativeMonitor
    {
        DdcMonitorInfo info;
        HANDLE handle{};
    };

    std::vector<NativeMonitor> EnumerateNativeMonitors()
    {
        std::vector<NativeMonitor> result;
        EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL
        {
            auto& monitors = *reinterpret_cast<std::vector<NativeMonitor>*>(parameter);
            MONITORINFOEXW monitorInfo{ sizeof(monitorInfo) };
            if (!GetMonitorInfoW(monitor, &monitorInfo)) return TRUE;

            DISPLAY_DEVICEW displayDevice{ sizeof(displayDevice) };
            EnumDisplayDevicesW(monitorInfo.szDevice, 0, &displayDevice, EDD_GET_DEVICE_INTERFACE_NAME);
            std::wstring baseId = displayDevice.DeviceID[0] ? displayDevice.DeviceID : monitorInfo.szDevice;
            std::wstring friendlyName = displayDevice.DeviceString[0] ? displayDevice.DeviceString : monitorInfo.szDevice;

            DWORD count{};
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, &count) || count == 0) return TRUE;
            std::vector<PHYSICAL_MONITOR> physical(count);
            if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical.data())) return TRUE;
            for (DWORD index = 0; index < count; ++index)
            {
                std::wstring id = baseId + L"|" + std::to_wstring(index);
                std::wstring label = friendlyName;
                if (physical[index].szPhysicalMonitorDescription[0] &&
                    _wcsicmp(physical[index].szPhysicalMonitorDescription, friendlyName.c_str()) != 0)
                    label += L" · " + std::wstring(physical[index].szPhysicalMonitorDescription);
                label += L" (" + std::wstring(monitorInfo.szDevice) + L")";
                monitors.push_back({ { std::move(id), std::move(label), monitorInfo.szDevice }, physical[index].hPhysicalMonitor });
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&result));
        return result;
    }

    void CloseNativeMonitors(std::vector<NativeMonitor>& monitors)
    {
        for (auto& monitor : monitors)
        {
            if (monitor.handle) DestroyPhysicalMonitor(monitor.handle);
            monitor.handle = nullptr;
        }
    }

    std::wstring Quote(std::wstring const& value)
    {
        std::wstring result = L"\"";
        unsigned slashes = 0;
        for (wchar_t character : value)
        {
            if (character == L'\\') { ++slashes; continue; }
            if (character == L'\"')
            {
                result.append(slashes * 2 + 1, L'\\');
                result.push_back(character);
                slashes = 0;
                continue;
            }
            result.append(slashes, L'\\');
            slashes = 0;
            result.push_back(character);
        }
        result.append(slashes * 2, L'\\');
        result.push_back(L'\"');
        return result;
    }

    ActionResult RunControlMyMonitor(
        std::wstring const& executable, std::wstring const& monitor, int input)
    {
        std::wstring command = Quote(executable) + L" /SetValue " + Quote(monitor) + L" 60 " + std::to_wstring(input);
        std::vector<wchar_t> mutableCommand(command.begin(), command.end());
        mutableCommand.push_back(L'\0');
        STARTUPINFOW startup{ sizeof(startup) };
        PROCESS_INFORMATION process{};
        if (!CreateProcessW(executable.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process))
        {
            return { false, monitor + L"：无法启动 ControlMyMonitor，错误 " + std::to_wstring(GetLastError()) };
        }
        CloseHandle(process.hThread);
        auto wait = WaitForSingleObject(process.hProcess, 5000);
        if (wait != WAIT_OBJECT_0)
        {
            CloseHandle(process.hProcess);
            return { false, monitor + L"：ControlMyMonitor 等待超时" };
        }
        DWORD exitCode{};
        GetExitCodeProcess(process.hProcess, &exitCode);
        CloseHandle(process.hProcess);
        if (exitCode != 0)
            return { false, monitor + L" 返回退出码 " + std::to_wstring(exitCode) };
        return { true, {} };
    }

    ActionResult RunNativeDdc(std::wstring const& monitorId, int input)
    {
        auto started = std::chrono::steady_clock::now();
        auto monitors = EnumerateNativeMonitors();
        auto enumerationMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        auto found = std::find_if(monitors.begin(), monitors.end(), [&](NativeMonitor const& monitor)
        {
            return _wcsicmp(monitor.info.id.c_str(), monitorId.c_str()) == 0;
        });
        if (found == monitors.end())
        {
            CloseNativeMonitors(monitors);
            return { false, L"找不到已配置的原生 DDC/CI 显示器，请在设置中重新选择" };
        }

        SetLastError(ERROR_SUCCESS);
        auto setStarted = std::chrono::steady_clock::now();
        auto succeeded = SetVCPFeature(found->handle, 0x60, static_cast<DWORD>(input)) != FALSE;
        auto setMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - setStarted).count();
        auto error = GetLastError();
        auto name = found->info.displayName;
        CloseNativeMonitors(monitors);
        WriteDiagnostic("ddc.set completed=1 success=" + std::to_string(succeeded ? 1 : 0) +
            " enumerate_ms=" + std::to_string(enumerationMilliseconds) + " set_ms=" + std::to_string(setMilliseconds));
        if (!succeeded)
            return { false, name + L"：原生 DDC/CI 切换失败，错误 " + std::to_wstring(error) };
        return { true, {} };
    }

    ActionResult RunWithRetry(std::function<ActionResult()> const& action)
    {
        ActionResult result;
        for (int attempt = 0; attempt < 2; ++attempt)
        {
            result = action();
            if (result.success) break;
            if (attempt == 0) std::this_thread::sleep_for(std::chrono::milliseconds(150));
        }
        return result;
    }
}

namespace DisplaySwitcher::Native
{
    bool WakeDisplay()
    {
        constexpr auto required = ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
        return SetThreadExecutionState(required) != 0;
    }

    std::vector<DdcMonitorInfo> EnumerateDdcMonitors()
    {
        auto native = EnumerateNativeMonitors();
        std::vector<DdcMonitorInfo> result;
        result.reserve(native.size());
        for (auto const& monitor : native) result.push_back(monitor.info);
        CloseNativeMonitors(native);
        std::sort(result.begin(), result.end(), [](auto const& left, auto const& right)
        {
            return _wcsicmp(left.displayName.c_str(), right.displayName.c_str()) < 0;
        });
        return result;
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config)
    {
        if (!config.HasDisplayConfiguration())
            return { false, L"显示器配置不完整，未执行切换" };
        auto native = config.displayControlBackend == L"native_ddc";
        WriteDiagnostic(native ? "display.backend native_ddc" : "display.backend control_my_monitor");
        if (!native && !std::filesystem::is_regular_file(config.controlMyMonitorPath))
            return { false, L"找不到 ControlMyMonitor：" + config.controlMyMonitorPath };

        auto redmi = std::async(std::launch::async, [&]
        {
            return RunWithRetry([&]
            {
                return native
                    ? RunNativeDdc(config.redmiNativeMonitorId, config.redmiMacInput)
                    : RunControlMyMonitor(config.controlMyMonitorPath, config.redmiMonitorPath, config.redmiMacInput);
            });
        });
        auto dell = std::async(std::launch::async, [&]
        {
            return RunWithRetry([&]
            {
                return native
                    ? RunNativeDdc(config.dellNativeMonitorId, config.dellMacInput)
                    : RunControlMyMonitor(config.controlMyMonitorPath, config.dellMonitorPath, config.dellMacInput);
            });
        });
        auto redmiResult = redmi.get();
        auto dellResult = dell.get();
        WriteDiagnostic("display.switch_complete success=" + std::to_string(redmiResult.success && dellResult.success ? 1 : 0));
        if (!redmiResult.success && !dellResult.success)
            return { false, redmiResult.error + L"；" + dellResult.error };
        if (!redmiResult.success) return redmiResult;
        if (!dellResult.success) return dellResult;
        return { true, {} };
    }
}
