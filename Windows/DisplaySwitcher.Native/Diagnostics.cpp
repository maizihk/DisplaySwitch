#include "pch.h"
#include "Diagnostics.h"

namespace
{
    std::mutex logMutex;

    std::filesystem::path LogPath()
    {
        PWSTR localAppData{};
        if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &localAppData))) return {};
        std::filesystem::path path(localAppData);
        CoTaskMemFree(localAppData);
        return path / L"DisplaySwitcher" / L"diagnostic.log";
    }

    void WriteLine(std::ios::openmode mode, std::string const& event)
    {
        auto path = LogPath();
        if (path.empty()) return;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream stream(path, std::ios::binary | mode);
        if (!stream) return;
        auto unixMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        stream << "unix_ms=" << unixMilliseconds << " tick_ms=" << GetTickCount64() << " " << event << "\n";
    }
}

namespace DisplaySwitcher::Native
{
    void ResetDiagnosticLog()
    {
        std::scoped_lock lock(logMutex);
        WriteLine(std::ios::trunc, "app.started");
    }

    void WriteDiagnostic(std::string const& event)
    {
        std::scoped_lock lock(logMutex);
        WriteLine(std::ios::app, event);
    }
}
