#include <windows.h>
#include <shellapi.h>

#include <filesystem>
#include <string>
#include <vector>

namespace
{
    std::wstring QuoteArgument(std::wstring const& argument)
    {
        std::wstring result = L"\"";
        size_t slashes = 0;
        for (auto character : argument)
        {
            if (character == L'\\')
            {
                ++slashes;
                continue;
            }
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

    std::filesystem::path ExecutablePath()
    {
        std::wstring buffer(32768, L'\0');
        auto length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (length == 0 || length >= buffer.size()) return {};
        buffer.resize(length);
        return buffer;
    }

    std::wstring ErrorText(DWORD error)
    {
        wchar_t* buffer{};
        auto length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, error, 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
        std::wstring text = length && buffer ? std::wstring(buffer, length) : L"Windows error " + std::to_wstring(error);
        if (buffer) LocalFree(buffer);
        return text;
    }
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    auto launcher = ExecutablePath();
    if (launcher.empty()) return 1;
    auto runtimeDirectory = launcher.parent_path() / L"runtime";
    auto target = runtimeDirectory / L"DisplaySwitcher.Windows.exe";
    if (!std::filesystem::is_regular_file(target))
    {
        MessageBoxW(nullptr, L"缺少 runtime\\DisplaySwitcher.Windows.exe，请重新复制完整程序目录。",
            L"DisplaySwitch", MB_OK | MB_ICONERROR);
        return 2;
    }

    int argumentCount{};
    auto arguments = CommandLineToArgvW(GetCommandLineW(), &argumentCount);
    std::wstring commandLine = QuoteArgument(target.wstring());
    if (arguments)
    {
        for (int index = 1; index < argumentCount; ++index)
            commandLine += L" " + QuoteArgument(arguments[index]);
        LocalFree(arguments);
    }
    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{ sizeof(startup) };
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(target.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE, 0, nullptr,
        runtimeDirectory.c_str(), &startup, &process))
    {
        auto message = L"无法启动 DisplaySwitch：\n\n" + ErrorText(GetLastError());
        MessageBoxW(nullptr, message.c_str(), L"DisplaySwitch", MB_OK | MB_ICONERROR);
        return 3;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
}
