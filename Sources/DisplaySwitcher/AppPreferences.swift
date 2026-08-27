import Foundation

enum AppPreferences {
    static var displayConfigurations: [DisplayConfiguration] {
        get { DisplayConfigurationStore.loadAll() }
        set { DisplayConfigurationStore.saveAll(newValue) }
    }

    static var linkedDisplays: Bool {
        get {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: "LinkedDisplays") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "LinkedDisplays")
        }
    }

    static var usbAutomationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "USBAutomation.Enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "USBAutomation.Enabled") }
    }

    static var usbSwitchDisplaysOnArrival: Bool {
        get { UserDefaults.standard.bool(forKey: "USBAutomation.SwitchDisplaysOnArrival") }
        set { UserDefaults.standard.set(newValue, forKey: "USBAutomation.SwitchDisplaysOnArrival") }
    }

    static var peerCoordinationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "Peer.Enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "Peer.Enabled") }
    }

    static var peerHost: String {
        get { UserDefaults.standard.string(forKey: "Peer.Host") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "Peer.Host") }
    }

    static var peerPort: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "Peer.Port")
            return value == 0 ? 49731 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: "Peer.Port") }
    }

    static var pairingCode: String {
        get { UserDefaults.standard.string(forKey: "Peer.PairingCode") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "Peer.PairingCode") }
    }

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
