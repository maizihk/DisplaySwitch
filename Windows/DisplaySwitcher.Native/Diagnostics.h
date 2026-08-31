#pragma once

namespace DisplaySwitcher::Native
{
    void ResetDiagnosticLog();
    void WriteDiagnostic(std::string const& event);
    std::vector<std::string> DiagnosticEventSnapshot();
    std::string SanitizeDiagnosticEvent(std::string const& event);
}
