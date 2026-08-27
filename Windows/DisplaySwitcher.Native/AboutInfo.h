#pragma once

#include <filesystem>

namespace DisplaySwitcher::Native
{
    struct AboutInfo
    {
        std::wstring applicationName;
        std::wstring publicVersion;
        std::wstring architecture;
        std::wstring protocol;
        std::wstring projectUrl;
        std::wstring licenseUrl;
        std::wstring thirdPartyNoticesUrl;
        std::wstring buildNotice;
        bool versionFromApplicationMetadata{};
    };

    AboutInfo PublicAboutInfo();
    AboutInfo PublicAboutInfo(std::filesystem::path const& applicationExecutable);
}
