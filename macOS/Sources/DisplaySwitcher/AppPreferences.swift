import Foundation

enum AppPreferences {
    static var displayConfigurations: [DisplayConfiguration] {
        DisplayConfigurationStore.load().configurations
    }

    static func loadDisplayConfigurations() -> DisplayConfigurationLoadResult {
        DisplayConfigurationStore.load()
    }

    static func saveDisplayConfigurations(_ configurations: [DisplayConfiguration]) throws {
        try DisplayConfigurationStore.saveAll(configurations)
    }

    static var localConfiguration: DisplayConfigurationStoreV4Document {
        DisplayConfigurationStore.load().document
    }

    static func saveLocalConfiguration(_ document: DisplayConfigurationStoreV4Document) throws {
        try DisplayConfigurationStore.saveDocument(document)
    }

    static var linkedDisplays: Bool { localConfiguration.linkAllDisplays }

    static var usbAutomationEnabled: Bool { localConfiguration.usbAutomationEnabled }

    static var usbSwitchDisplaysOnArrival: Bool { localConfiguration.usbSwitchDisplaysOnArrival }

    static var usbTriggerDevice: USBDevice? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "USBAutomation.Device") else { return nil }
            return try? JSONDecoder().decode(USBDevice.self, from: data)
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "USBAutomation.Device")
            } else {
                defaults.removeObject(forKey: "USBAutomation.Device")
            }
        }
    }
}
