#include "pch.h"
#include "App.xaml.h"

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Xaml;

namespace winrt::DisplaySwitcher::Native::implementation
{
    App::App() = default;

    void App::OnLaunched(LaunchActivatedEventArgs const&)
    {
        lifetimeWindow_ = Window();
        lifetimeWindow_.Title(L"DisplaySwitcher lifetime host");

        HWND window{};
        check_hresult(lifetimeWindow_.as<::IWindowNative>()->get_WindowHandle(&window));
        auto id = Microsoft::UI::GetWindowIdFromWindow(window);
        auto appWindow = Windowing::AppWindow::GetFromWindowId(id);
        appWindow.IsShownInSwitchers(false);

        controller_ = ::DisplaySwitcher::Native::Controller::Create(
            Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread(),
            [this] { ExitApplication(); });
    }

    void App::ExitApplication()
    {
        if (controller_) controller_->Dispose();
        controller_.reset();
        if (lifetimeWindow_) lifetimeWindow_.Close();
        lifetimeWindow_ = nullptr;
        Exit();
    }
}
