#pragma once

namespace DisplaySwitcher::Native
{
    class TrayIcon
    {
    public:
        TrayIcon(std::function<void()> showSettings, std::function<void()> manualSwitch, std::function<void()> exit);
        ~TrayIcon();
        TrayIcon(TrayIcon const&) = delete;
        TrayIcon& operator=(TrayIcon const&) = delete;

        void SetStatus(std::wstring const& status);
        void ShowBalloon(std::wstring const& title, std::wstring const& message);

    private:
        static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
        LRESULT HandleMessage(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
        void ShowContextMenu();
        NOTIFYICONDATAW Data(UINT flags) const;
        static std::wstring Limit(std::wstring const& value, size_t length);

        std::function<void()> showSettings_;
        std::function<void()> manualSwitch_;
        std::function<void()> exit_;
        HINSTANCE instance_{};
        HICON icon_{};
        HWND window_{};
        std::wstring className_;
        std::wstring status_{ L"正在初始化…" };
        bool disposed_{};
    };
}
