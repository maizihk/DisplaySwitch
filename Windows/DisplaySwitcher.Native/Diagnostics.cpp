#include "pch.h"
#include "Diagnostics.h"

namespace
{
    std::mutex logMutex;
    std::vector<std::string> sessionEvents;
    bool detailedRecordingEnabled{};
    std::optional<std::filesystem::path> testLogPath;
    constexpr size_t MaximumSessionEvents = 64;

    bool SafeToken(std::string const& value, bool allowDot)
    {
        return !value.empty() && std::all_of(value.begin(), value.end(), [allowDot](unsigned char value)
        {
            return (value >= 'a' && value <= 'z') || (value >= '0' && value <= '9') ||
                value == '_' || value == '-' || (allowDot && value == '.');
        });
    }

    bool SafeField(std::string const& key, std::string const& value)
    {
        static std::set<std::string> const allowed{
            "present", "message_ignored", "success", "count", "duration_ms", "elapsed_ms",
            "resolve_ok", "resolve_ms", "send_ok", "send_ms"
        };
        return allowed.contains(key) && !value.empty() && std::all_of(value.begin(), value.end(), [](unsigned char c)
        { return c >= '0' && c <= '9'; });
    }

    std::string Sanitize(std::string const& event)
    {
        std::istringstream stream(event);
        std::string name;
        stream >> name;
        static std::set<std::string> const allowedEvents{
            "app.started", "controller.usb_presence", "protocol.v2",
            "profile_detection.response_received", "profile_detection.response_authenticated",
            "profile_detection.response_authentication_failed", "profile_detection.started",
            "profile_detection.response_timeout", "profile_detection.send_completed",
            "udp.send", "display.switch_complete", "usb.target_notification", "usb.poll_change",
            "diagnostic.redacted"
        };
        if (!SafeToken(name, true) || !allowedEvents.contains(name))
            return "diagnostic.redacted redacted=1";
        std::string result = name;
        std::string field;
        bool removed{};
        while (stream >> field)
        {
            auto separator = field.find('=');
            if (separator == std::string::npos || !SafeField(field.substr(0, separator), field.substr(separator + 1)))
            {
                removed = true;
                continue;
            }
            result += " " + field;
        }
        if (removed) result += " redacted=1";
        return result;
    }

    void Remember(std::string const& event)
    {
        sessionEvents.push_back(event);
        if (sessionEvents.size() > MaximumSessionEvents)
            sessionEvents.erase(sessionEvents.begin(), sessionEvents.begin() + (sessionEvents.size() - MaximumSessionEvents));
    }

    std::filesystem::path LogPath()
    {
        if (testLogPath) return *testLogPath;
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

    void ClearStoredLog()
    {
        auto path = LogPath();
        if (path.empty()) return;
        std::error_code error;
        if (!std::filesystem::exists(path, error)) return;
        {
            std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        }
        std::filesystem::remove(path, error);
    }
}

namespace DisplaySwitcher::Native
{
    void SetDetailedDiagnosticRecordingEnabled(bool enabled)
    {
        std::scoped_lock lock(logMutex);
        if (detailedRecordingEnabled == enabled) return;
        detailedRecordingEnabled = enabled;
        sessionEvents.clear();
        ClearStoredLog();
    }

    bool IsDetailedDiagnosticRecordingEnabled()
    {
        std::scoped_lock lock(logMutex);
        return detailedRecordingEnabled;
    }

    void ResetDiagnosticLog()
    {
        std::scoped_lock lock(logMutex);
        sessionEvents.clear();
        ClearStoredLog();
        if (!detailedRecordingEnabled) return;
        Remember("app.started");
        WriteLine(std::ios::trunc, "app.started");
    }

    void WriteDiagnostic(std::string const& event)
    {
        std::scoped_lock lock(logMutex);
        if (!detailedRecordingEnabled) return;
        auto safe = Sanitize(event);
        Remember(safe);
        WriteLine(std::ios::app, safe);
    }

    std::vector<std::string> DiagnosticEventSnapshot()
    {
        std::scoped_lock lock(logMutex);
        if (!detailedRecordingEnabled) return {};
        return sessionEvents;
    }

    std::string SanitizeDiagnosticEvent(std::string const& event) { return Sanitize(event); }

    void SetDiagnosticLogPathForTesting(std::optional<std::filesystem::path> path)
    {
        std::scoped_lock lock(logMutex);
        sessionEvents.clear();
        if (testLogPath) ClearStoredLog();
        testLogPath = std::move(path);
        if (testLogPath) ClearStoredLog();
    }
}
