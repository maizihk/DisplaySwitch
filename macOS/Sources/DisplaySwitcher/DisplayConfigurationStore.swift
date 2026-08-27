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

struct DisplayConfigurationDocument: Codable, Equatable {
    let schemaVersion: Int
    let displays: [DisplayConfiguration]
}

enum DisplayConfigurationStoreError: Error, Equatable, LocalizedError {
    case corruptedData
    case unsupportedSchemaVersion(Int)
    case encodingFailed
    case writeFailed
    case previousFailureRequiresReview

    var errorDescription: String? {
        switch self {
        case .corruptedData:
            return "显示器配置数据已损坏或格式不完整。"
        case .unsupportedSchemaVersion(let version):
            return "显示器配置版本 \(version) 不受当前 App 支持。"
        case .encodingFailed:
            return "无法编码显示器配置。"
        case .writeFailed:
            return "无法安全写入显示器配置。"
        case .previousFailureRequiresReview:
            return "上次显示器配置迁移或保存失败，需要用户检查。"
        }
    }
}

enum DisplayConfigurationSafetyState: Equatable {
    case ready
    case requiresUserReview(DisplayConfigurationStoreError)
}

struct DisplayConfigurationLoadResult: Equatable {
    let configurations: [DisplayConfiguration]
    let safetyState: DisplayConfigurationSafetyState
}

enum ConfigurationSideEffect: CaseIterable {
    case usb
    case ddc
    case wake
    case network
}

final class ConfigurationSafetyGate {
    private let lock = NSLock()
    private var storedState: DisplayConfigurationSafetyState

    init(state: DisplayConfigurationSafetyState = .ready) {
        storedState = state
    }

    var state: DisplayConfigurationSafetyState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    func apply(_ result: DisplayConfigurationLoadResult) {
        setState(result.safetyState)
    }

    func requireUserReview(_ error: DisplayConfigurationStoreError) {
        setState(.requiresUserReview(error))
    }

    func allows(_ sideEffect: ConfigurationSideEffect) -> Bool {
        state == .ready
    }

    private func setState(_ state: DisplayConfigurationSafetyState) {
        lock.lock()
        storedState = state
        lock.unlock()
    }
}

protocol DisplayConfigurationStorage {
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func writeDocument(_ data: Data, forKey key: String) throws
}

struct UserDefaultsDisplayConfigurationStorage: DisplayConfigurationStorage {
    let defaults: UserDefaults

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }

    func writeDocument(_ data: Data, forKey key: String) throws {
        let previous = defaults.object(forKey: key)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            throw DisplayConfigurationStoreError.writeFailed
        }
    }
}

enum DisplayConfigurationStore {
    static let storageKey = "Displays.Configuration.v2"
    static let legacyArrayStorageKey = "Displays.Configuration.v1"
    static let requiresReviewKey = "Displays.Configuration.RequiresReview"
    static let currentSchemaVersion = 2

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    typealias DocumentEncoder = (DisplayConfigurationDocument) throws -> Data

    static func load(defaults: UserDefaults = .standard) -> DisplayConfigurationLoadResult {
        load(storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults))
    }

    static func load(
        storage: DisplayConfigurationStorage,
        encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }
    ) -> DisplayConfigurationLoadResult {
        if let data = storage.data(forKey: storageKey) {
            do {
                let version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
                guard version == currentSchemaVersion else {
                    return failureResult(
                        .unsupportedSchemaVersion(version),
                        storage: storage
                    )
                }
                let document = try JSONDecoder().decode(DisplayConfigurationDocument.self, from: data)
                return DisplayConfigurationLoadResult(
                    configurations: normalized(document.displays),
                    safetyState: storage.bool(forKey: requiresReviewKey)
                        ? .requiresUserReview(.previousFailureRequiresReview)
                        : .ready
                )
            } catch let error as DisplayConfigurationStoreError {
                return failureResult(error, storage: storage)
            } catch {
                return failureResult(.corruptedData, storage: storage)
            }
        }

        if let legacyData = storage.data(forKey: legacyArrayStorageKey) {
            guard let decoded = try? JSONDecoder().decode([DisplayConfiguration].self, from: legacyData) else {
                return failureResult(.corruptedData, storage: storage, includeLegacyArray: false)
            }
            let migrated = normalized(decoded)
            return migrate(migrated, storage: storage, encodeDocument: encodeDocument)
        }

        guard hasLegacyConfiguration(storage: storage) else {
            return DisplayConfigurationLoadResult(configurations: [], safetyState: .ready)
        }

        let migrated = (1...2).map { loadLegacy(index: $0, storage: storage) }
        return migrate(migrated, storage: storage, encodeDocument: encodeDocument)
    }

    static func saveAll(
        _ configurations: [DisplayConfiguration],
        defaults: UserDefaults = .standard
    ) throws {
        try saveAll(
            configurations,
            storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults),
            clearSafetyMarker: true
        )
    }

    static func saveAll(
        _ configurations: [DisplayConfiguration],
        storage: DisplayConfigurationStorage,
        clearSafetyMarker: Bool = true,
        encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }
    ) throws {
        let values = normalized(configurations)
        let document = DisplayConfigurationDocument(
            schemaVersion: currentSchemaVersion,
            displays: values
        )
        let data: Data
        do {
            data = try encodeDocument(document)
        } catch {
            markRequiresReview(storage: storage)
            throw DisplayConfigurationStoreError.encodingFailed
        }
        do {
            try storage.writeDocument(data, forKey: storageKey)
        } catch {
            markRequiresReview(storage: storage)
            throw DisplayConfigurationStoreError.writeFailed
        }

        // The v1 array and legacy keys are intentionally retained for rollback and recovery.
        for configuration in values {
            saveLegacy(configuration, storage: storage)
            saveDeviceOverrides(configuration, storage: storage)
        }
        if clearSafetyMarker {
            storage.removeObject(forKey: requiresReviewKey)
        }
    }

    static func merge(
        detected: [DetectedDisplay],
        existing: [DisplayConfiguration],
        defaults: UserDefaults = .standard
    ) throws -> [DisplayConfiguration] {
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
            applyDeviceOverrides(
                to: &configuration,
                storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults)
            )
            return configuration
        }

        try saveAll(
            merged,
            storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults),
            clearSafetyMarker: false
        )
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

    private static func migrate(
        _ configurations: [DisplayConfiguration],
        storage: DisplayConfigurationStorage,
        encodeDocument: DocumentEncoder
    ) -> DisplayConfigurationLoadResult {
        do {
            try saveAll(
                configurations,
                storage: storage,
                clearSafetyMarker: false,
                encodeDocument: encodeDocument
            )
            return DisplayConfigurationLoadResult(
                configurations: configurations,
                safetyState: storage.bool(forKey: requiresReviewKey)
                    ? .requiresUserReview(.previousFailureRequiresReview)
                    : .ready
            )
        } catch let error as DisplayConfigurationStoreError {
            return DisplayConfigurationLoadResult(
                configurations: configurations,
                safetyState: .requiresUserReview(error)
            )
        } catch {
            return DisplayConfigurationLoadResult(
                configurations: configurations,
                safetyState: .requiresUserReview(.writeFailed)
            )
        }
    }

    private static func failureResult(
        _ error: DisplayConfigurationStoreError,
        storage: DisplayConfigurationStorage,
        includeLegacyArray: Bool = true
    ) -> DisplayConfigurationLoadResult {
        markRequiresReview(storage: storage)
        return DisplayConfigurationLoadResult(
            configurations: recoveryConfigurations(
                storage: storage,
                includeLegacyArray: includeLegacyArray
            ),
            safetyState: .requiresUserReview(error)
        )
    }

    private static func markRequiresReview(storage: DisplayConfigurationStorage) {
        storage.set(true, forKey: requiresReviewKey)
    }

    private static func recoveryConfigurations(
        storage: DisplayConfigurationStorage,
        includeLegacyArray: Bool
    ) -> [DisplayConfiguration] {
        if includeLegacyArray,
           let data = storage.data(forKey: legacyArrayStorageKey),
           let decoded = try? JSONDecoder().decode([DisplayConfiguration].self, from: data) {
            return normalized(decoded)
        }
        guard hasLegacyConfiguration(storage: storage) else { return [] }
        return (1...2).map { loadLegacy(index: $0, storage: storage) }
    }

    private static func hasLegacyConfiguration(storage: DisplayConfigurationStorage) -> Bool {
        for index in 1...2 {
            let prefix = "Display.\(index)"
            for suffix in ["Name", "Selector", "MacInput", "WindowsInput", "ReadEnabled"]
            where storage.object(forKey: "\(prefix).\(suffix)") != nil {
                return true
            }
        }
        return false
    }

    private static func isLegacySelector(_ selector: String) -> Bool {
        Int(selector.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func loadLegacy(
        index: Int,
        storage: DisplayConfigurationStorage
    ) -> DisplayConfiguration {
        let fallback = defaultConfiguration(index: index)
        let prefix = "Display.\(index)"
        return DisplayConfiguration(
            index: index,
            name: storage.string(forKey: "\(prefix).Name") ?? fallback.name,
            selector: storage.string(forKey: "\(prefix).Selector") ?? fallback.selector,
            macInput: storage.object(forKey: "\(prefix).MacInput") == nil
                ? fallback.macInput : storage.integer(forKey: "\(prefix).MacInput"),
            windowsInput: storage.object(forKey: "\(prefix).WindowsInput") == nil
                ? fallback.windowsInput : storage.integer(forKey: "\(prefix).WindowsInput"),
            readEnabled: storage.object(forKey: "\(prefix).ReadEnabled") == nil
                ? fallback.readEnabled : storage.bool(forKey: "\(prefix).ReadEnabled")
        )
    }

    private static func saveLegacy(
        _ configuration: DisplayConfiguration,
        storage: DisplayConfigurationStorage
    ) {
        let prefix = "Display.\(configuration.index)"
        storage.set(configuration.name, forKey: "\(prefix).Name")
        storage.set(configuration.selector, forKey: "\(prefix).Selector")
        if let macInput = configuration.macInput {
            storage.set(macInput, forKey: "\(prefix).MacInput")
        } else {
            storage.removeObject(forKey: "\(prefix).MacInput")
        }
        if let windowsInput = configuration.windowsInput {
            storage.set(windowsInput, forKey: "\(prefix).WindowsInput")
        } else {
            storage.removeObject(forKey: "\(prefix).WindowsInput")
        }
        storage.set(configuration.readEnabled, forKey: "\(prefix).ReadEnabled")
    }

    private static func saveDeviceOverrides(
        _ configuration: DisplayConfiguration,
        storage: DisplayConfigurationStorage
    ) {
        guard configuration.selector.contains("-") else { return }
        let prefix = "Device.\(configuration.selector.uppercased())"
        if let macInput = configuration.macInput {
            storage.set(macInput, forKey: "\(prefix).MacInput")
        }
        if let windowsInput = configuration.windowsInput {
            storage.set(windowsInput, forKey: "\(prefix).WindowsInput")
        }
        storage.set(configuration.readEnabled, forKey: "\(prefix).ReadEnabled")
    }

    private static func applyDeviceOverrides(
        to configuration: inout DisplayConfiguration,
        storage: DisplayConfigurationStorage
    ) {
        let prefix = "Device.\(configuration.selector.uppercased())"
        if storage.object(forKey: "\(prefix).MacInput") != nil {
            configuration.macInput = storage.integer(forKey: "\(prefix).MacInput")
        }
        if storage.object(forKey: "\(prefix).WindowsInput") != nil {
            configuration.windowsInput = storage.integer(forKey: "\(prefix).WindowsInput")
        }
        if storage.object(forKey: "\(prefix).ReadEnabled") != nil {
            configuration.readEnabled = storage.bool(forKey: "\(prefix).ReadEnabled")
        }
    }
}
