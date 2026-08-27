#pragma once

#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    class DdcBackendSet final
    {
    public:
        explicit DdcBackendSet(AppConfig const& config);
        IDdcBackend* Lookup(std::wstring const& key) const noexcept;

    private:
        std::unique_ptr<IDdcBackend> native_;
        std::unique_ptr<IDdcBackend> controlMyMonitor_;
    };
}
