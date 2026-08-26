import Foundation

struct DisplayConfiguration {
    let index: Int
    var name: String
    var selector: String
    var macInput: Int
    var windowsInput: Int
    var readEnabled: Bool

    private var prefix: String { "Display.\(index)" }

    static func load(index: Int) -> DisplayConfiguration {
        let defaults = UserDefaults.standard
        let fallback = defaultConfiguration(index: index)
        let prefix = "Display.\(index)"

        return DisplayConfiguration(
            index: index,
            name: defaults.string(forKey: "\(prefix).Name") ?? fallback.name,
            selector: defaults.string(forKey: "\(prefix).Selector") ?? fallback.selector,
            macInput: defaults.object(forKey: "\(prefix).MacInput") == nil
                ? fallback.macInput
                : defaults.integer(forKey: "\(prefix).MacInput"),
            windowsInput: defaults.object(forKey: "\(prefix).WindowsInput") == nil
                ? fallback.windowsInput
                : defaults.integer(forKey: "\(prefix).WindowsInput"),
            readEnabled: defaults.object(forKey: "\(prefix).ReadEnabled") == nil
                ? fallback.readEnabled
                : defaults.bool(forKey: "\(prefix).ReadEnabled")
        )
    }

    static func load(index: Int, detectedName: String, detectedSelector: String) -> DisplayConfiguration {
        let defaults = UserDefaults.standard
        var configuration = load(index: index)
        let devicePrefix = "Device.\(detectedSelector)"

        configuration.name = detectedName
        configuration.selector = detectedSelector

        if defaults.object(forKey: "\(devicePrefix).WindowsInput") != nil {
            configuration.windowsInput = defaults.integer(forKey: "\(devicePrefix).WindowsInput")
        }
        if defaults.object(forKey: "\(devicePrefix).MacInput") != nil {
            configuration.macInput = defaults.integer(forKey: "\(devicePrefix).MacInput")
        }
        if defaults.object(forKey: "\(devicePrefix).ReadEnabled") != nil {
            configuration.readEnabled = defaults.bool(forKey: "\(devicePrefix).ReadEnabled")
        }
        return configuration
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(name, forKey: "\(prefix).Name")
        defaults.set(selector, forKey: "\(prefix).Selector")
        defaults.set(macInput, forKey: "\(prefix).MacInput")
        defaults.set(windowsInput, forKey: "\(prefix).WindowsInput")
        defaults.set(readEnabled, forKey: "\(prefix).ReadEnabled")

        if selector.contains("-") {
            let devicePrefix = "Device.\(selector)"
            defaults.set(macInput, forKey: "\(devicePrefix).MacInput")
            defaults.set(windowsInput, forKey: "\(devicePrefix).WindowsInput")
            defaults.set(readEnabled, forKey: "\(devicePrefix).ReadEnabled")
        }
    }

    private static func defaultConfiguration(index: Int) -> DisplayConfiguration {
        return DisplayConfiguration(
            index: index,
            name: "显示器 \(index)",
            selector: "\(index)",
            macInput: index == 1 ? 15 : 17,
            windowsInput: index == 1 ? 18 : 15,
            readEnabled: index == 1
        )
    }
}

struct DetectedDisplay {
    let index: Int
    let name: String
    let systemUUID: String

    static func parseList(_ output: String) -> [DetectedDisplay] {
        let pattern = #"^\[(\d+)\]\s+(.+?)\s+\(([0-9A-Fa-f-]{36})\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        return output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard
                let match = expression.firstMatch(in: line, range: range),
                match.numberOfRanges == 4,
                let indexRange = Range(match.range(at: 1), in: line),
                let nameRange = Range(match.range(at: 2), in: line),
                let uuidRange = Range(match.range(at: 3), in: line),
                let index = Int(line[indexRange])
            else {
                return nil
            }

            return DetectedDisplay(
                index: index,
                name: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                systemUUID: String(line[uuidRange]).uppercased()
            )
        }
        .sorted { $0.index < $1.index }
    }
}

enum AppPreferences {
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
