#include "pch.h"
#include "AboutInfo.h"

namespace DisplaySwitcher::Native
{
    namespace
    {
        std::filesystem::path CurrentExecutablePath()
        {
            std::wstring buffer(32768, L'\0');
            auto length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
            if (length == 0 || length == buffer.size()) return {};
            buffer.resize(length);
            return buffer;
        }

        std::optional<std::wstring> VersionFromMetadata(std::filesystem::path const& executable)
        {
            if (executable.empty()) return std::nullopt;
            DWORD ignored{};
            auto size = GetFileVersionInfoSizeW(executable.c_str(), &ignored);
            if (size == 0) return std::nullopt;

            std::vector<std::byte> data(size);
            if (!GetFileVersionInfoW(executable.c_str(), 0, size, data.data())) return std::nullopt;

            void* rawVersion{};
            UINT versionSize{};
            if (!VerQueryValueW(data.data(), L"\\", &rawVersion, &versionSize)
                || versionSize < sizeof(VS_FIXEDFILEINFO) || !rawVersion)
                return std::nullopt;
            auto version = static_cast<VS_FIXEDFILEINFO*>(rawVersion);
            if (version->dwSignature != 0xfeef04bd) return std::nullopt;

            auto major = HIWORD(version->dwProductVersionMS);
            auto minor = LOWORD(version->dwProductVersionMS);
            auto patch = HIWORD(version->dwProductVersionLS);
            auto build = LOWORD(version->dwProductVersionLS);
            return std::to_wstring(major) + L"." + std::to_wstring(minor) + L"." + std::to_wstring(patch)
                + L" (" + std::to_wstring(build) + L")";
        }
    }

    AboutInfo PublicAboutInfo(std::filesystem::path const& applicationExecutable)
    {
#if defined(_M_X64)
        auto architecture = L"Windows x64";
#elif defined(_M_ARM64)
        auto architecture = L"Windows ARM64";
#else
        auto architecture = L"Windows";
#endif
        auto version = VersionFromMetadata(applicationExecutable);
        return {
            L"DisplaySwitch",
            version.value_or(L"未知"),
            architecture,
            L"UDP 协议 v1 / v2",
            L"https://github.com/maizihk/DisplaySwitch",
            L"https://github.com/maizihk/DisplaySwitch/blob/main/LICENSE",
            L"https://github.com/maizihk/DisplaySwitch/blob/main/THIRD_PARTY_NOTICES.md",
            L"当前为未签名测试构建，不等同于正式发布版本。",
            version.has_value(),
        };
    }

    AboutInfo PublicAboutInfo()
    {
        return PublicAboutInfo(CurrentExecutablePath());
    }
}
