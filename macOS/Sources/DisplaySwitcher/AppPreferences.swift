import Foundation

enum AppPreferences {
    private static let mediaKeyVolumeTakeoverKey = "mediaKeyVolumeTakeoverEnabled"

    static var displayConfigurations: [DisplayConfiguration] {
        DisplayConfigurationStore.load().configurations
    }

    static func loadDisplayConfigurations() -> DisplayConfigurationLoadResult {
        DisplayConfigurationStore.load()
    }

    static func saveDisplayConfigurations(_ configurations: [DisplayConfiguration]) throws {
        try DisplayConfigurationStore.saveAll(configurations)
    }

    static var localConfiguration: DisplayConfigurationStoreV5Document {
        DisplayConfigurationStore.load().document
    }

    static func saveLocalConfiguration(_ document: DisplayConfigurationStoreV5Document) throws {
        try DisplayConfigurationStore.saveDocument(document)
    }

    static var usbSwitch: USBSwitchConfiguration { localConfiguration.usbSwitch }

    static var detailedDiagnosticRecordingEnabled: Bool {
        DetailedDiagnosticRecordingPreference.shared.isEnabled
    }

    static func setDetailedDiagnosticRecordingEnabled(_ enabled: Bool) {
        DetailedDiagnosticRecordingPreference.shared.setEnabled(enabled)
    }

    /// Local-only opt-in. Absence is intentionally false for backward compatibility.
    static var mediaKeyVolumeTakeoverEnabled: Bool {
        UserDefaults.standard.bool(forKey: mediaKeyVolumeTakeoverKey)
    }

    static func setMediaKeyVolumeTakeoverEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: mediaKeyVolumeTakeoverKey)
    }
}
