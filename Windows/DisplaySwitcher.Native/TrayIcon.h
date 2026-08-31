#pragma once
#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    struct TrayDdcItem
    {
        std::wstring displayId;
        std::wstring displayName;
        DdcVcpCode code{ DdcVcpCode::Brightness };
        std::wstring label;
        int value{};
        int maximum{ 100 };
        bool known{};
    };

    class TrayIcon
    {
    public:
        TrayIcon(std::function<void()> showSettings, std::function<void(std::wstring const&)> manualSwitch,
            std::function<void(std::wstring const&, DdcVcpCode, int)> writeDdc,
            std::function<void()> topologyChanged, std::function<void()> exit);
        ~TrayIcon();
        TrayIcon(TrayIcon const&) = delete;
        TrayIcon& operator=(TrayIcon const&) = delete;

        void SetStatus(std::wstring const& status);
        void SetProfiles(std::vector<std::pair<std::wstring, std::wstring>> profiles);
        void SetDdcItems(std::vector<TrayDdcItem> items);
        void ShowBalloon(std::wstring const& title, std::wstring const& message);

    private:
        static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
        LRESULT HandleMessage(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
        void ShowContextMenu();
        NOTIFYICONDATAW Data(UINT flags) const;
        static std::wstring Limit(std::wstring const& value, size_t length);

        std::function<void()> showSettings_;
        std::function<void(std::wstring const&)> manualSwitch_;
        std::function<void(std::wstring const&, DdcVcpCode, int)> writeDdc_;
        std::function<void()> topologyChanged_;
        std::function<void()> exit_;
        HINSTANCE instance_{};
        HICON icon_{};
        HWND window_{};
        std::wstring className_;
        std::wstring status_{ L"正在初始化…" };
        std::vector<std::pair<std::wstring, std::wstring>> profiles_;
        std::vector<TrayDdcItem> ddcItems_;
        bool sessionNotificationsRegistered_{};
        bool disposed_{};
    };
}
