#include "pch.h"
#include "SystemActions.h"

namespace
{
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

    DisplaySwitcher::Native::ActionResult RunControlMyMonitor(
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
}

namespace DisplaySwitcher::Native
{
    bool WakeDisplay()
    {
        constexpr auto required = ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
        return SetThreadExecutionState(required) != 0;
    }

    ActionResult SwitchDisplaysToMac(AppConfig const& config)
    {
        if (!std::filesystem::is_regular_file(config.controlMyMonitorPath))
            return { false, L"找不到 ControlMyMonitor：" + config.controlMyMonitorPath };

        std::optional<std::wstring> firstError;
        for (auto const& [monitor, input] : std::vector<std::pair<std::wstring, int>>{
            { config.redmiMonitorPath, config.redmiMacInput },
            { config.dellMonitorPath, config.dellMacInput } })
        {
            ActionResult result;
            for (int attempt = 0; attempt < 2; ++attempt)
            {
                result = RunControlMyMonitor(config.controlMyMonitorPath, monitor, input);
                if (result.success) break;
                if (attempt == 0) std::this_thread::sleep_for(std::chrono::milliseconds(300));
            }
            if (!result.success && !firstError) firstError = result.error;
        }
        return firstError ? ActionResult{ false, *firstError } : ActionResult{ true, {} };
    }
}
