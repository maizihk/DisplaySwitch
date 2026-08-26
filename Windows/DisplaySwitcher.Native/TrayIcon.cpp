#include "pch.h"
#include "TrayIcon.h"

namespace
{
    constexpr UINT CallbackMessage = WM_APP + 1;
    constexpr UINT ManualSwitchCommand = 1001;
    constexpr UINT SettingsCommand = 1002;
    constexpr UINT ExitCommand = 1003;
    constexpr GUID TrayGuid{ 0x438e980a, 0x76bb, 0x4e3a, { 0x99, 0x5c, 0x5e, 0xab, 0x0d, 0x26, 0x3e, 0x3a } };
}

namespace DisplaySwitcher::Native
{
    TrayIcon::TrayIcon(std::function<void()> showSettings, std::function<void()> manualSwitch, std::function<void()> exit) :
        showSettings_(std::move(showSettings)), manualSwitch_(std::move(manualSwitch)), exit_(std::move(exit))
    {
        instance_ = GetModuleHandleW(nullptr);
        icon_ = LoadIconW(nullptr, IDI_APPLICATION);
        className_ = L"DisplaySwitcher.Tray." + std::to_wstring(GetCurrentProcessId());
        WNDCLASSEXW windowClass{ sizeof(windowClass) };
        windowClass.lpfnWndProc = WindowProcedure;
        windowClass.hInstance = instance_;
        windowClass.lpszClassName = className_.c_str();
        if (!RegisterClassExW(&windowClass)) winrt::throw_last_error();
        window_ = CreateWindowExW(0, className_.c_str(), L"DisplaySwitcher tray host", 0,
            0, 0, 0, 0, nullptr, nullptr, instance_, this);
        if (!window_) winrt::throw_last_error();
        auto data = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        if (!Shell_NotifyIconW(NIM_ADD, &data)) winrt::throw_last_error();
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &data);
    }

    TrayIcon::~TrayIcon()
    {
        if (disposed_) return;
        disposed_ = true;
        if (window_)
        {
            auto data = Data(0);
            Shell_NotifyIconW(NIM_DELETE, &data);
            DestroyWindow(window_);
            window_ = nullptr;
        }
        if (!className_.empty()) UnregisterClassW(className_.c_str(), instance_);
    }

    NOTIFYICONDATAW TrayIcon::Data(UINT flags) const
    {
        NOTIFYICONDATAW data{ sizeof(data) };
        data.hWnd = window_;
        data.uID = 1;
        data.uFlags = flags | NIF_GUID;
        data.uCallbackMessage = CallbackMessage;
        data.hIcon = icon_;
        data.guidItem = TrayGuid;
        auto tip = Limit(L"显示器切换 · " + status_, 127);
        wcscpy_s(data.szTip, tip.c_str());
        return data;
    }

    void TrayIcon::SetStatus(std::wstring const& status)
    {
        if (disposed_) return;
        status_ = status;
        auto data = Data(NIF_ICON | NIF_TIP);
        Shell_NotifyIconW(NIM_MODIFY, &data);
    }

    void TrayIcon::ShowBalloon(std::wstring const& title, std::wstring const& message)
    {
        if (disposed_) return;
        auto data = Data(NIF_ICON | NIF_TIP | NIF_INFO);
        wcscpy_s(data.szInfoTitle, Limit(title, 63).c_str());
        wcscpy_s(data.szInfo, Limit(message, 255).c_str());
        data.dwInfoFlags = NIIF_WARNING;
        Shell_NotifyIconW(NIM_MODIFY, &data);
    }

    LRESULT CALLBACK TrayIcon::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
    {
        TrayIcon* self{};
        if (message == WM_NCCREATE)
        {
            self = static_cast<TrayIcon*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        else self = reinterpret_cast<TrayIcon*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        return self ? self->HandleMessage(window, message, wParam, lParam) : DefWindowProcW(window, message, wParam, lParam);
    }

    LRESULT TrayIcon::HandleMessage(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
    {
        if (message == CallbackMessage)
        {
            auto notification = LOWORD(lParam);
            if (notification == WM_CONTEXTMENU || notification == WM_RBUTTONUP)
            {
                ShowContextMenu();
                return 0;
            }
            if (notification == WM_LBUTTONDBLCLK || notification == NIN_SELECT || notification == NIN_KEYSELECT)
            {
                if (showSettings_) showSettings_();
                return 0;
            }
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }

    void TrayIcon::ShowContextMenu()
    {
        HMENU menu = CreatePopupMenu();
        if (!menu) return;
        AppendMenuW(menu, MF_STRING | MF_DISABLED | MF_GRAYED, 0, Limit(status_, 70).c_str());
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, ManualSwitchCommand, L"手动切换到 Mac");
        AppendMenuW(menu, MF_STRING, SettingsCommand, L"设置…");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, ExitCommand, L"退出");
        POINT point{};
        GetCursorPos(&point);
        SetForegroundWindow(window_);
        auto command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD,
            point.x, point.y, 0, window_, nullptr);
        DestroyMenu(menu);
        if (command == ManualSwitchCommand && manualSwitch_) manualSwitch_();
        else if (command == SettingsCommand && showSettings_) showSettings_();
        else if (command == ExitCommand && exit_) exit_();
    }

    std::wstring TrayIcon::Limit(std::wstring const& value, size_t length)
    {
        return value.size() <= length ? value : value.substr(0, length);
    }
}
