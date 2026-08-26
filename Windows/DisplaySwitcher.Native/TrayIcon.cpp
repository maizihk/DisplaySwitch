#include "pch.h"
#include "TrayIcon.h"
#include "resource.h"

namespace
{
    constexpr UINT CallbackMessage = WM_APP + 1;
    constexpr UINT PopupCommandMessage = WM_APP + 2;
    constexpr UINT_PTR PopupDismissTimer = 1;
    constexpr UINT ManualSwitchCommand = 1001;
    constexpr UINT SettingsCommand = 1002;
    constexpr UINT ExitCommand = 1003;
    constexpr GUID TrayGuid{ 0x438e980a, 0x76bb, 0x4e3a, { 0x99, 0x5c, 0x5e, 0xab, 0x0d, 0x26, 0x3e, 0x3a } };

    int ScaleForDpi(int value, UINT dpi)
    {
        return MulDiv(value, static_cast<int>(dpi), 96);
    }

    bool AppsUseDarkTheme()
    {
        DWORD useLightTheme = 1;
        DWORD size = sizeof(useLightTheme);
        auto result = RegGetValueW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
            L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &useLightTheme, &size);
        return result == ERROR_SUCCESS && useLightTheme == 0;
    }

    HFONT CreateMenuFont(UINT dpi)
    {
        NONCLIENTMETRICSW metrics{ sizeof(metrics) };
        using SystemParametersInfoForDpiFn = BOOL(WINAPI*)(UINT, UINT, PVOID, UINT, UINT);
        auto user32 = GetModuleHandleW(L"user32.dll");
        auto systemParametersInfoForDpi = reinterpret_cast<SystemParametersInfoForDpiFn>(
            GetProcAddress(user32, "SystemParametersInfoForDpi"));
        auto loaded = systemParametersInfoForDpi
            ? systemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi)
            : SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0);
        return loaded ? CreateFontIndirectW(&metrics.lfMenuFont) : nullptr;
    }

    struct PopupMenuItem
    {
        UINT command{};
        std::wstring text;
        bool separator{};
        bool enabled{ true };
        RECT bounds{};
    };

    struct PopupMenuState
    {
        std::vector<PopupMenuItem> items;
        HFONT font{};
        UINT dpi{ 96 };
        bool dark{};
        int hotIndex{ -1 };
        HWND owner{};
        HWND window{};
        bool closing{};
        bool inputArmed{};
        bool heapOwned{};

        ~PopupMenuState()
        {
            if (font) DeleteObject(font);
        }
    };

    int HitTestMenuItem(PopupMenuState const& state, int x, int y)
    {
        for (size_t index = 0; index < state.items.size(); ++index)
        {
            auto const& item = state.items[index];
            if (!item.separator && item.enabled && x >= item.bounds.left && x < item.bounds.right
                && y >= item.bounds.top && y < item.bounds.bottom)
                return static_cast<int>(index);
        }
        return -1;
    }

    void ClosePopupMenu(HWND window, PopupMenuState& state)
    {
        if (state.closing) return;
        state.closing = true;
        if (IsWindow(window)) DestroyWindow(window);
    }

    int NextMenuItem(PopupMenuState const& state, int current, int direction)
    {
        if (state.items.empty()) return -1;
        auto index = current;
        for (size_t count = 0; count < state.items.size(); ++count)
        {
            index = (index + direction + static_cast<int>(state.items.size()))
                % static_cast<int>(state.items.size());
            auto const& item = state.items[index];
            if (!item.separator && item.enabled) return index;
        }
        return -1;
    }

    void DrawPopupMenu(HWND window, PopupMenuState const& state, HDC dc)
    {
        RECT client{};
        GetClientRect(window, &client);
        auto background = state.dark ? RGB(32, 32, 32) : RGB(249, 249, 249);
        auto hover = state.dark ? RGB(58, 58, 58) : RGB(229, 229, 229);
        auto text = state.dark ? RGB(245, 245, 245) : RGB(31, 31, 31);
        auto disabled = state.dark ? RGB(158, 158, 158) : RGB(105, 105, 105);
        auto separator = state.dark ? RGB(70, 70, 70) : RGB(218, 218, 218);

        HBRUSH backgroundBrush = CreateSolidBrush(background);
        FillRect(dc, &client, backgroundBrush);
        DeleteObject(backgroundBrush);
        auto previousFont = SelectObject(dc, state.font ? state.font : GetStockObject(DEFAULT_GUI_FONT));
        SetBkMode(dc, TRANSPARENT);

        for (size_t index = 0; index < state.items.size(); ++index)
        {
            auto const& item = state.items[index];
            if (item.separator)
            {
                HPEN pen = CreatePen(PS_SOLID, 1, separator);
                auto previousPen = SelectObject(dc, pen);
                auto y = (item.bounds.top + item.bounds.bottom) / 2;
                MoveToEx(dc, item.bounds.left, y, nullptr);
                LineTo(dc, item.bounds.right, y);
                SelectObject(dc, previousPen);
                DeleteObject(pen);
                continue;
            }

            if (static_cast<int>(index) == state.hotIndex)
            {
                HBRUSH hoverBrush = CreateSolidBrush(hover);
                FillRect(dc, &item.bounds, hoverBrush);
                DeleteObject(hoverBrush);
            }
            SetTextColor(dc, item.enabled ? text : disabled);
            RECT textBounds = item.bounds;
            textBounds.left += ScaleForDpi(20, state.dpi);
            textBounds.right -= ScaleForDpi(20, state.dpi);
            DrawTextW(dc, item.text.c_str(), static_cast<int>(item.text.size()), &textBounds,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        }
        SelectObject(dc, previousFont);
    }

    LRESULT CALLBACK PopupMenuWindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
    {
        PopupMenuState* state{};
        if (message == WM_NCCREATE)
        {
            state = static_cast<PopupMenuState*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
            state->window = window;
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
        }
        else state = reinterpret_cast<PopupMenuState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (!state) return DefWindowProcW(window, message, wParam, lParam);

        switch (message)
        {
        case WM_ERASEBKGND:
            return TRUE;
        case WM_SETCURSOR:
            SetCursor(LoadCursorW(nullptr, IDC_ARROW));
            return TRUE;
        case WM_PAINT:
        {
            PAINTSTRUCT paint{};
            auto dc = BeginPaint(window, &paint);
            DrawPopupMenu(window, *state, dc);
            EndPaint(window, &paint);
            return 0;
        }
        case WM_MOUSEMOVE:
        {
            auto point = MAKEPOINTS(lParam);
            auto hotIndex = HitTestMenuItem(*state, point.x, point.y);
            if (hotIndex != state->hotIndex)
            {
                state->hotIndex = hotIndex;
                InvalidateRect(window, nullptr, FALSE);
            }
            TRACKMOUSEEVENT tracking{ sizeof(tracking), TME_LEAVE, window, 0 };
            TrackMouseEvent(&tracking);
            return 0;
        }
        case WM_MOUSELEAVE:
            state->hotIndex = -1;
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        case WM_LBUTTONUP:
        case WM_RBUTTONUP:
        {
            auto point = MAKEPOINTS(lParam);
            auto index = HitTestMenuItem(*state, point.x, point.y);
            if (index >= 0) PostMessageW(state->owner, PopupCommandMessage, state->items[index].command, 0);
            ClosePopupMenu(window, *state);
            return 0;
        }
        case WM_KEYDOWN:
            if (wParam == VK_ESCAPE)
            {
                ClosePopupMenu(window, *state);
                return 0;
            }
            if (wParam == VK_DOWN || wParam == VK_UP)
            {
                state->hotIndex = NextMenuItem(*state, state->hotIndex, wParam == VK_DOWN ? 1 : -1);
                InvalidateRect(window, nullptr, FALSE);
                return 0;
            }
            if (wParam == VK_RETURN && state->hotIndex >= 0)
            {
                PostMessageW(state->owner, PopupCommandMessage, state->items[state->hotIndex].command, 0);
                ClosePopupMenu(window, *state);
                return 0;
            }
            break;
        case WM_TIMER:
            if (wParam == PopupDismissTimer)
            {
                auto buttonsDown = (GetAsyncKeyState(VK_LBUTTON) & 0x8000)
                    || (GetAsyncKeyState(VK_RBUTTON) & 0x8000)
                    || (GetAsyncKeyState(VK_MBUTTON) & 0x8000);
                if (!state->inputArmed)
                {
                    if (!buttonsDown) state->inputArmed = true;
                    return 0;
                }
                if (buttonsDown)
                {
                    POINT cursor{};
                    RECT bounds{};
                    GetCursorPos(&cursor);
                    GetWindowRect(window, &bounds);
                    if (!PtInRect(&bounds, cursor)) ClosePopupMenu(window, *state);
                }
            }
            return 0;
        case WM_CLOSE:
            ClosePopupMenu(window, *state);
            return 0;
        case WM_NCDESTROY:
        {
            KillTimer(window, PopupDismissTimer);
            auto heapOwned = state->heapOwned;
            state->window = nullptr;
            SetWindowLongPtrW(window, GWLP_USERDATA, 0);
            auto result = DefWindowProcW(window, message, wParam, lParam);
            if (heapOwned) delete state;
            return result;
        }
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

namespace DisplaySwitcher::Native
{
    TrayIcon::TrayIcon(std::function<void()> showSettings, std::function<void()> manualSwitch, std::function<void()> exit) :
        showSettings_(std::move(showSettings)), manualSwitch_(std::move(manualSwitch)), exit_(std::move(exit))
    {
        instance_ = GetModuleHandleW(nullptr);
        icon_ = LoadIconW(instance_, MAKEINTRESOURCEW(IDI_APP_ICON));
        if (!icon_) icon_ = LoadIconW(nullptr, IDI_APPLICATION);
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
        if (message == PopupCommandMessage)
        {
            auto command = static_cast<UINT>(wParam);
            if (command == ManualSwitchCommand && manualSwitch_) manualSwitch_();
            else if (command == SettingsCommand && showSettings_) showSettings_();
            else if (command == ExitCommand && exit_) exit_();
            return 0;
        }
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
        auto state = std::make_unique<PopupMenuState>();
        state->owner = window_;
        state->dark = AppsUseDarkTheme();
        state->dpi = GetDpiForWindow(window_);
        if (!state->dpi) state->dpi = 96;
        state->font = CreateMenuFont(state->dpi);
        state->items = {
            { 0, Limit(status_, 70), false, false },
            { 0, L"", true, false },
            { ManualSwitchCommand, L"手动切换到 Mac", false, true },
            { SettingsCommand, L"设置…", false, true },
            { 0, L"", true, false },
            { ExitCommand, L"退出", false, true },
        };

        auto rowHeight = ScaleForDpi(32, state->dpi);
        auto separatorHeight = ScaleForDpi(1, state->dpi);
        auto menuWidth = ScaleForDpi(120, state->dpi);
        auto menuHeight = 0;
        HDC dc = GetDC(window_);
        HGDIOBJ previousFont{};
        if (dc) previousFont = SelectObject(dc, state->font ? state->font : GetStockObject(DEFAULT_GUI_FONT));
        for (auto& item : state->items)
        {
            auto itemHeight = item.separator ? separatorHeight : rowHeight;
            item.bounds = { 0, menuHeight, 0, menuHeight + itemHeight };
            menuHeight += itemHeight;
            if (!item.separator && dc)
            {
                SIZE textSize{};
                GetTextExtentPoint32W(dc, item.text.c_str(), static_cast<int>(item.text.size()), &textSize);
                menuWidth = (std::max)(menuWidth, static_cast<int>(textSize.cx) + ScaleForDpi(40, state->dpi));
            }
        }
        if (dc)
        {
            if (previousFont) SelectObject(dc, previousFont);
            ReleaseDC(window_, dc);
        }
        for (auto& item : state->items) item.bounds.right = menuWidth;

        POINT point{};
        GetCursorPos(&point);
        MONITORINFO monitorInfo{ sizeof(monitorInfo) };
        GetMonitorInfoW(MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), &monitorInfo);
        auto x = (std::min)((std::max)(point.x, monitorInfo.rcWork.left), monitorInfo.rcWork.right - menuWidth);
        auto y = point.y - menuHeight;
        if (y < monitorInfo.rcWork.top) y = point.y;
        y = (std::min)((std::max)(y, monitorInfo.rcWork.top), monitorInfo.rcWork.bottom - menuHeight);

        auto menuClassName = L"DisplaySwitcher.PopupMenu." + std::to_wstring(GetCurrentProcessId());
        WNDCLASSEXW windowClass{ sizeof(windowClass) };
        windowClass.style = CS_DROPSHADOW;
        windowClass.lpfnWndProc = PopupMenuWindowProcedure;
        windowClass.hInstance = instance_;
        windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowClass.lpszClassName = menuClassName.c_str();
        if (!RegisterClassExW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;

        auto menuWindow = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            menuClassName.c_str(), L"DisplaySwitcher menu", WS_POPUP,
            x, y, menuWidth, menuHeight, window_, nullptr, instance_, state.get());
        if (menuWindow)
        {
            state->heapOwned = true;
            auto radius = ScaleForDpi(10, state->dpi);
            HRGN region = CreateRoundRectRgn(0, 0, menuWidth + 1, menuHeight + 1, radius, radius);
            if (!SetWindowRgn(menuWindow, region, FALSE)) DeleteObject(region);
            BOOL darkMode = state->dark;
            DwmSetWindowAttribute(menuWindow, DWMWA_USE_IMMERSIVE_DARK_MODE, &darkMode, sizeof(darkMode));
            DWM_WINDOW_CORNER_PREFERENCE cornerPreference = DWMWCP_ROUND;
            DwmSetWindowAttribute(menuWindow, DWMWA_WINDOW_CORNER_PREFERENCE,
                &cornerPreference, sizeof(cornerPreference));
            COLORREF noBorder = 0xFFFFFFFE;
            DwmSetWindowAttribute(menuWindow, DWMWA_BORDER_COLOR, &noBorder, sizeof(noBorder));

            ShowWindow(menuWindow, SW_SHOWNOACTIVATE);
            UpdateWindow(menuWindow);
            SetTimer(menuWindow, PopupDismissTimer, 16, nullptr);
            state.release();
        }
    }

    std::wstring TrayIcon::Limit(std::wstring const& value, size_t length)
    {
        return value.size() <= length ? value : value.substr(0, length);
    }
}
