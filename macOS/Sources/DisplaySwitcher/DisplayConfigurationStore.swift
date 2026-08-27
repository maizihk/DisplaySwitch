import Foundation

struct DisplayConfiguration: Codable, Equatable {
    let index: Int
    var name: String
    var selector: String
    var macInput: Int?
    var windowsInput: Int?
    var readEnabled: Bool
}

struct DetectedDisplay: Equatable {
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
            else { return nil }

            return DetectedDisplay(
                index: index,
                name: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                systemUUID: String(line[uuidRange]).uppercased()
            )
        }
        .sorted { $0.index < $1.index }
    }
}

enum DisplayConfigurationStore {
    static let storageKey = "Displays.Configuration.v1"

    static func loadAll(defaults: UserDefaults = .standard) -> [DisplayConfiguration] {
        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([DisplayConfiguration].self, from: data),
            !decoded.isEmpty
        {
            return normalized(decoded)
        }

        guard hasLegacyConfiguration(defaults: defaults) else { return [] }

        let migrated = (1...2).map { loadLegacy(index: $0, defaults: defaults) }
        saveAll(migrated, defaults: defaults)
        return migrated
    }

    static func saveAll(
        _ configurations: [DisplayConfiguration],
        defaults: UserDefaults = .standard
    ) {
        let values = normalized(configurations)
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: storageKey)
        }

        // Keep the legacy keys during the migration window so users can roll back safely.
        for configuration in values {
            saveLegacy(configuration, defaults: defaults)
            saveDeviceOverrides(configuration, defaults: defaults)
        }
    }

    static func merge(
        detected: [DetectedDisplay],
        existing: [DisplayConfiguration],
        defaults: UserDefaults = .standard
    ) -> [DisplayConfiguration] {
        let sortedDetected = detected.sorted { $0.index < $1.index }
        var usedExistingIndexes = Set<Int>()

        let merged = sortedDetected.enumerated().map { offset, display in
            let selector = display.systemUUID.uppercased()
            let selectorMatch = existing.indices.first {
                !usedExistingIndexes.contains($0) && existing[$0].selector.uppercased() == selector
            }
            let nameMatches = existing.indices.filter {
                !usedExistingIndexes.contains($0) &&
                isLegacySelector(existing[$0].selector) &&
                existing[$0].name.caseInsensitiveCompare(display.name) == .orderedSame
            }
            let positionalMatch = existing.indices.contains(offset) &&
                !usedExistingIndexes.contains(offset) &&
                isLegacySelector(existing[offset].selector)
                ? offset
                : nil
            let matchIndex = selectorMatch ?? (nameMatches.count == 1 ? nameMatches[0] : positionalMatch)

            var configuration = matchIndex.map { existing[$0] }
                ?? defaultConfiguration(index: offset + 1, legacyDefaults: false)
            if let matchIndex { usedExistingIndexes.insert(matchIndex) }

            configuration = DisplayConfiguration(
                index: offset + 1,
                name: display.name,
                selector: selector,
                macInput: configuration.macInput,
                windowsInput: configuration.windowsInput,
                readEnabled: configuration.readEnabled
            )
            applyDeviceOverrides(to: &configuration, defaults: defaults)
            return configuration
        }

        saveAll(merged, defaults: defaults)
        return merged
    }

    static func defaultConfiguration(
        index: Int,
        legacyDefaults: Bool = true
    ) -> DisplayConfiguration {
        DisplayConfiguration(
            index: index,
            name: "显示器 \(index)",
            selector: "\(index)",
            macInput: legacyDefaults ? (index == 1 ? 15 : 17) : nil,
            windowsInput: legacyDefaults ? (index == 1 ? 18 : 15) : nil,
            readEnabled: legacyDefaults && index == 1
        )
    }

    private static func normalized(_ configurations: [DisplayConfiguration]) -> [DisplayConfiguration] {
        configurations.enumerated().map { offset, value in
            DisplayConfiguration(
                index: offset + 1,
                name: value.name,
                selector: value.selector,
                macInput: value.macInput,
                windowsInput: value.windowsInput,
                readEnabled: value.readEnabled
            )
        }
    }

    private static func hasLegacyConfiguration(defaults: UserDefaults) -> Bool {
        for index in 1...2 {
            let prefix = "Display.\(index)"
            for suffix in ["Name", "Selector", "MacInput", "WindowsInput", "ReadEnabled"]
            where defaults.object(forKey: "\(prefix).\(suffix)") != nil {
                return true
            }
        }
        return false
    }

    private static func isLegacySelector(_ selector: String) -> Bool {
        Int(selector.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func loadLegacy(index: Int, defaults: UserDefaults) -> DisplayConfiguration {
        let fallback = defaultConfiguration(index: index)
        let prefix = "Display.\(index)"
        return DisplayConfiguration(
            index: index,
            name: defaults.string(forKey: "\(prefix).Name") ?? fallback.name,
            selector: defaults.string(forKey: "\(prefix).Selector") ?? fallback.selector,
            macInput: defaults.object(forKey: "\(prefix).MacInput") == nil
                ? fallback.macInput : defaults.integer(forKey: "\(prefix).MacInput"),
            windowsInput: defaults.object(forKey: "\(prefix).WindowsInput") == nil
                ? fallback.windowsInput : defaults.integer(forKey: "\(prefix).WindowsInput"),
            readEnabled: defaults.object(forKey: "\(prefix).ReadEnabled") == nil
                ? fallback.readEnabled : defaults.bool(forKey: "\(prefix).ReadEnabled")
        )
    }

    private static func saveLegacy(_ configuration: DisplayConfiguration, defaults: UserDefaults) {
        let prefix = "Display.\(configuration.index)"
        defaults.set(configuration.name, forKey: "\(prefix).Name")
        defaults.set(configuration.selector, forKey: "\(prefix).Selector")
        if let macInput = configuration.macInput {
            defaults.set(macInput, forKey: "\(prefix).MacInput")
        } else {
            defaults.removeObject(forKey: "\(prefix).MacInput")
        }
        if let windowsInput = configuration.windowsInput {
            defaults.set(windowsInput, forKey: "\(prefix).WindowsInput")
        } else {
            defaults.removeObject(forKey: "\(prefix).WindowsInput")
        }
        defaults.set(configuration.readEnabled, forKey: "\(prefix).ReadEnabled")
    }

    private static func saveDeviceOverrides(
        _ configuration: DisplayConfiguration,
        defaults: UserDefaults
    ) {
        guard configuration.selector.contains("-") else { return }
        let prefix = "Device.\(configuration.selector.uppercased())"
        if let macInput = configuration.macInput {
            defaults.set(macInput, forKey: "\(prefix).MacInput")
        }
        if let windowsInput = configuration.windowsInput {
            defaults.set(windowsInput, forKey: "\(prefix).WindowsInput")
        }
        defaults.set(configuration.readEnabled, forKey: "\(prefix).ReadEnabled")
    }

    private static func applyDeviceOverrides(
        to configuration: inout DisplayConfiguration,
        defaults: UserDefaults
    ) {
        let prefix = "Device.\(configuration.selector.uppercased())"
        if defaults.object(forKey: "\(prefix).MacInput") != nil {
            configuration.macInput = defaults.integer(forKey: "\(prefix).MacInput")
        }
        if defaults.object(forKey: "\(prefix).WindowsInput") != nil {
            configuration.windowsInput = defaults.integer(forKey: "\(prefix).WindowsInput")
        }
        if defaults.object(forKey: "\(prefix).ReadEnabled") != nil {
            configuration.readEnabled = defaults.bool(forKey: "\(prefix).ReadEnabled")
        }
    }
}
