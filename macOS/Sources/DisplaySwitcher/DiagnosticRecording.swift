import Foundation

final class DetailedDiagnosticRecordingPreference {
    static let shared = DetailedDiagnosticRecordingPreference()
    static let defaultKey = "DetailedDiagnosticRecordingEnabled"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    var isEnabled: Bool {
        defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }
}
