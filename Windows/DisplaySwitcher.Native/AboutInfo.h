#pragma once

namespace DisplaySwitcher::Native
{
    struct AboutInfo
    {
        std::wstring applicationName;
        std::wstring publicVersion;
        std::wstring architecture;
        std::wstring protocol;
        std::wstring projectUrl;
        std::wstring buildNotice;
    };

    AboutInfo PublicAboutInfo();
}
