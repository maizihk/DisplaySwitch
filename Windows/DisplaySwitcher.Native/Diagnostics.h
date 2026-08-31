#pragma once

namespace DisplaySwitcher::Native
{
    void SetDetailedDiagnosticRecordingEnabled(bool enabled);
    bool IsDetailedDiagnosticRecordingEnabled();
    void ResetDiagnosticLog();
    void WriteDiagnostic(std::string const& event);
    std::vector<std::string> DiagnosticEventSnapshot();
    std::string SanitizeDiagnosticEvent(std::string const& event);
    void SetDiagnosticLogPathForTesting(std::optional<std::filesystem::path> path);
}
