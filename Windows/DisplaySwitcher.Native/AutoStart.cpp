#include "pch.h"
#include "AutoStart.h"

namespace DisplaySwitcher::Native
{
    void ApplyAutoStart(bool enabled)
    {
        HKEY key{};
        auto createResult = RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0,
            KEY_SET_VALUE, nullptr, &key, nullptr);
        if (createResult != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(createResult));
        if (enabled)
        {
            wchar_t executable[32768]{};
            auto length = GetModuleFileNameW(nullptr, executable, ARRAYSIZE(executable));
            if (length == 0 || length == ARRAYSIZE(executable))
            {
                RegCloseKey(key);
                winrt::throw_last_error();
            }
            std::wstring value = L"\"" + std::wstring(executable, length) + L"\"";
            auto result = RegSetValueExW(key, L"DisplaySwitcher.Windows", 0, REG_SZ,
                reinterpret_cast<BYTE const*>(value.c_str()),
                static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
            RegCloseKey(key);
            if (result != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(result));
        }
        else
        {
            auto result = RegDeleteValueW(key, L"DisplaySwitcher.Windows");
            RegCloseKey(key);
            if (result != ERROR_SUCCESS && result != ERROR_FILE_NOT_FOUND)
                winrt::throw_hresult(HRESULT_FROM_WIN32(result));
        }
    }
}
