#include "pch.h"
#include "AboutInfo.h"

namespace DisplaySwitcher::Native
{
    AboutInfo PublicAboutInfo()
    {
#if defined(_M_X64)
        auto architecture = L"Windows x64";
#elif defined(_M_ARM64)
        auto architecture = L"Windows ARM64";
#else
        auto architecture = L"Windows";
#endif
        return {
            L"DisplaySwitch",
            L"2.1.0 (19)",
            architecture,
            L"UDP 协议 v1",
            L"https://github.com/maizihk/DisplaySwitch",
            L"当前为未签名测试构建，不等同于正式发布版本。",
        };
    }
}
