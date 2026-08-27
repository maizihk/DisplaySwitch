import Foundation

struct DisplayConfiguration: Codable, Equatable {
    let id: String?
    let index: Int
    var name: String
    var selector: String
    var macInput: Int?
    var windowsInput: Int?
    var readEnabled: Bool

    init(id: String? = nil, index: Int, name: String, selector: String, macInput: Int?, windowsInput: Int?, readEnabled: Bool) {
        self.id = id
        self.index = index
        self.name = name
        self.selector = selector
        self.macInput = macInput
        self.windowsInput = windowsInput
        self.readEnabled = readEnabled
    }
}

struct DetectedDisplay: Equatable {
    let index: Int
    let name: String
    let systemUUID: String

    static func parseList(_ output: String) -> [DetectedDisplay] {
        let pattern = #"^\[(\d+)\]\s+(.+?)\s+\(([0-9A-Fa-f-]{36})\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(whereSeparator: { $0.isNewline }).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges == 4,
                  let indexRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let uuidRange = Range(match.range(at: 3), in: line),
                  let index = Int(line[indexRange]) else { return nil }
            return DetectedDisplay(index: index,
                                   name: String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                                   systemUUID: String(line[uuidRange]).uppercased())
        }.sorted { $0.index < $1.index }
    }
}

// Retained only for one-way migration from the previous local schema.
struct DisplayConfigurationDocument: Codable, Equatable {
    let schemaVersion: Int
    let displays: [DisplayConfiguration]
}

struct DisplayConfigurationV3Display: Codable, Equatable {
    let id: String
    var name: String
    var selector: String
    var localInput: Int?
    var readEnabled: Bool
    var brightnessEnabled: Bool
    var contrastEnabled: Bool
    var volumeEnabled: Bool
}

struct DisplayInputMapping: Codable, Equatable {
    let displayID: String
    var peerInput: Int
}

struct CollaborationTriggerDevice: Codable, Equatable {
    var kind: String
    var localReference: String
    var displayName: String
}

struct CollaborationProfile: Codable, Equatable {
    var id: String
    var name: String
    var peerHost: String
    var peerPort: Int
    var pairingCode: String
    var peerEndpointID: String?
    var peerProtocolVersion: Int?
    var coordinationEnabled: Bool
    var displayInputs: [DisplayInputMapping]
    var triggerDevices: [CollaborationTriggerDevice]
}

struct DisplayConfigurationStoreV3Document: Codable, Equatable {
    let schemaVersion: Int
    let localEndpointID: String
    var localDeviceName: String
    var listenPort: Int
    var displays: [DisplayConfigurationV3Display]
    var collaborationProfiles: [CollaborationProfile]
}

enum DisplayConfigurationStoreError: Error, Equatable, LocalizedError {
    case corruptedData
    case unsupportedSchemaVersion(Int)
    case encodingFailed
    case writeFailed
    case previousFailureRequiresReview
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .corruptedData: return "显示器配置数据已损坏或格式不完整。"
        case .unsupportedSchemaVersion(let version): return "显示器配置版本 \(version) 不受当前 App 支持。"
        case .encodingFailed: return "无法编码本机配置。"
        case .writeFailed: return "无法安全写入本机配置。"
        case .previousFailureRequiresReview: return "上次配置迁移或保存失败，需要用户检查。"
        case .invalidConfiguration: return "配置包含重复标识、重复名称或非法字段。"
        }
    }
}

enum DisplayConfigurationSafetyState: Equatable {
    case ready
    case requiresUserReview(DisplayConfigurationStoreError)
}

struct DisplayConfigurationLoadResult: Equatable {
    let configurations: [DisplayConfiguration]
    let collaborationProfiles: [CollaborationProfile]
    let document: DisplayConfigurationStoreV3Document
    let safetyState: DisplayConfigurationSafetyState
}

enum ConfigurationSideEffect: CaseIterable, Hashable { case usb, ddc, wake, network }

final class ConfigurationSafetyGate {
    private let lock = NSLock()
    private var storedState: DisplayConfigurationSafetyState
    init(state: DisplayConfigurationSafetyState = .ready) { storedState = state }
    var state: DisplayConfigurationSafetyState { lock.lock(); defer { lock.unlock() }; return storedState }
    func apply(_ result: DisplayConfigurationLoadResult) { setState(result.safetyState) }
    func requireUserReview(_ error: DisplayConfigurationStoreError) { setState(.requiresUserReview(error)) }
    func allows(_ sideEffect: ConfigurationSideEffect) -> Bool { state == .ready }
    private func setState(_ state: DisplayConfigurationSafetyState) { lock.lock(); storedState = state; lock.unlock() }
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
        let previous = defaults.data(forKey: key)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            throw DisplayConfigurationStoreError.writeFailed
        }
    }
}

enum LocalProfileIssue: String, Equatable, Hashable {
    case missingName, missingHost, invalidPort, invalidPairingCode, missingDisplayMapping, orphanedDisplayMapping
}

struct LocalProfileInspection: Equatable {
    let issues: [LocalProfileIssue]
    let ddcUnavailableDisplayIDs: [String]
    var isComplete: Bool { issues.isEmpty && ddcUnavailableDisplayIDs.isEmpty }
}

enum PeerIdentityCheck: Equatable {
    case unchanged
    case firstConfirmationRequired(endpointID: String, protocolVersion: Int)
    case changeConfirmationRequired(previousEndpointID: String, endpointID: String, protocolVersion: Int)
    case invalid
}

enum DisplayConfigurationStore {
    static let storageKey = "Displays.Configuration.v3"
    static let legacyDocumentStorageKey = "Displays.Configuration.v2"
    static let legacyArrayStorageKey = "Displays.Configuration.v1"
    static let requiresReviewKey = "Displays.Configuration.RequiresReview"
    static let currentSchemaVersion = 3

    typealias DocumentEncoder = (DisplayConfigurationStoreV3Document) throws -> Data
    typealias DocumentDecoder = (Data) throws -> DisplayConfigurationStoreV3Document

    private static let defaultPort = 49731
    private static let profileNameLimit = 32
    private static let displayNameLimit = 64
    private static let textLimit = 255
    private static let legacyPeer = (host: "Peer.Host", port: "Peer.Port", code: "Peer.PairingCode", enabled: "Peer.Enabled")

    private struct VersionProbe: Decodable { let schemaVersion: Int }
    private struct LegacyUSBDevice: Decodable {
        let vendorID: Int
        let productID: Int
        let name: String
        let serialNumber: String?
        var displayName: String {
            let identifier = String(format: "%04X:%04X", vendorID, productID)
            guard let serialNumber, !serialNumber.isEmpty else { return "\(name)（\(identifier)）" }
            return "\(name)（\(identifier)，序列号 \(serialNumber)）"
        }
    }

    static func load(defaults: UserDefaults = .standard) -> DisplayConfigurationLoadResult {
        load(storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults))
    }

    static func load(storage: DisplayConfigurationStorage,
                     decodeDocument: DocumentDecoder = { try JSONDecoder().decode(DisplayConfigurationStoreV3Document.self, from: $0) },
                     encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }) -> DisplayConfigurationLoadResult {
        let priorFailure = storage.bool(forKey: requiresReviewKey)
        if let data = storage.data(forKey: storageKey) {
            do {
                let version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
                guard version == currentSchemaVersion else { throw DisplayConfigurationStoreError.unsupportedSchemaVersion(version) }
                let document = try validate(decodeDocument(data))
                return result(document, priorFailure ? .requiresUserReview(.previousFailureRequiresReview) : .ready)
            } catch let error as DisplayConfigurationStoreError { return failed(error, storage: storage) }
            catch { return failed(.corruptedData, storage: storage) }
        }
        if let data = storage.data(forKey: legacyDocumentStorageKey) {
            do {
                let version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
                guard version == 2 else { throw DisplayConfigurationStoreError.unsupportedSchemaVersion(version) }
                let old = try JSONDecoder().decode(DisplayConfigurationDocument.self, from: data)
                return migrate(old.displays, storage: storage, encoder: encodeDocument, priorFailure: priorFailure)
            } catch let error as DisplayConfigurationStoreError { return failed(error, storage: storage) }
            catch { return failed(.corruptedData, storage: storage) }
        }
        if let data = storage.data(forKey: legacyArrayStorageKey) {
            do {
                let old = try JSONDecoder().decode([DisplayConfiguration].self, from: data)
                return migrate(old, storage: storage, encoder: encodeDocument, priorFailure: priorFailure)
            } catch { return failed(.corruptedData, storage: storage) }
        }
        if hasLegacyDisplayKeys(storage) {
            return migrate(loadLegacyDisplays(storage), storage: storage, encoder: encodeDocument, priorFailure: priorFailure)
        }
        let fresh = freshDocument()
        do {
            try persist(fresh, storage: storage, encoder: encodeDocument)
            return result(fresh, priorFailure ? .requiresUserReview(.previousFailureRequiresReview) : .ready)
        } catch let error as DisplayConfigurationStoreError {
            storage.set(true, forKey: requiresReviewKey)
            return result(fresh, .requiresUserReview(error))
        } catch {
            storage.set(true, forKey: requiresReviewKey)
            return result(fresh, .requiresUserReview(.writeFailed))
        }
    }

    static func saveAll(_ configurations: [DisplayConfiguration],
                        collaborationProfiles: [CollaborationProfile]? = nil,
                        defaults: UserDefaults = .standard,
                        clearSafetyMarker: Bool = true,
                        encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }) throws {
        try saveAll(configurations, collaborationProfiles: collaborationProfiles,
                    storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults),
                    clearSafetyMarker: clearSafetyMarker, encodeDocument: encodeDocument)
    }

    static func saveAll(_ configurations: [DisplayConfiguration],
                        collaborationProfiles: [CollaborationProfile]? = nil,
                        storage: DisplayConfigurationStorage,
                        clearSafetyMarker: Bool = true,
                        encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }) throws {
        let current = load(storage: storage)
        let displays = try convert(configurations, preserving: current.document.displays)
        var profiles = collaborationProfiles ?? current.collaborationProfiles
        if collaborationProfiles == nil, !profiles.isEmpty {
            profiles[0].displayInputs = mergeLegacyInputs(configurations, displays: displays, existing: profiles[0].displayInputs)
        }
        let document = DisplayConfigurationStoreV3Document(schemaVersion: currentSchemaVersion,
            localEndpointID: current.document.localEndpointID, localDeviceName: current.document.localDeviceName,
            listenPort: current.document.listenPort, displays: displays, collaborationProfiles: profiles)
        try saveDocument(document, storage: storage, clearSafetyMarker: clearSafetyMarker, encodeDocument: encodeDocument)
    }

    static func saveDocument(_ document: DisplayConfigurationStoreV3Document,
                             defaults: UserDefaults = .standard,
                             clearSafetyMarker: Bool = true) throws {
        try saveDocument(document, storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults), clearSafetyMarker: clearSafetyMarker)
    }

    static func saveDocument(_ document: DisplayConfigurationStoreV3Document,
                             storage: DisplayConfigurationStorage,
                             clearSafetyMarker: Bool = true,
                             encodeDocument: DocumentEncoder = { try JSONEncoder().encode($0) }) throws {
        do {
            try persist(try validate(document), storage: storage, encoder: encodeDocument)
            if clearSafetyMarker { storage.removeObject(forKey: requiresReviewKey) }
        } catch let error as DisplayConfigurationStoreError {
            storage.set(true, forKey: requiresReviewKey)
            throw error
        } catch {
            storage.set(true, forKey: requiresReviewKey)
            throw DisplayConfigurationStoreError.writeFailed
        }
    }

    static func merge(detected: [DetectedDisplay], existing: [DisplayConfiguration], defaults: UserDefaults = .standard) throws -> [DisplayConfiguration] {
        var used = Set<Int>()
        let merged = detected.sorted { $0.index < $1.index }.enumerated().map { offset, item in
            let exact = existing.indices.first { !used.contains($0) && existing[$0].selector.caseInsensitiveCompare(item.systemUUID) == .orderedSame }
            let legacyNames = existing.indices.filter { !used.contains($0) && Int(existing[$0].selector) != nil && existing[$0].name.caseInsensitiveCompare(item.name) == .orderedSame }
            let match = exact ?? (legacyNames.count == 1 ? legacyNames[0] : nil)
            if let match { used.insert(match) }
            let prior = match.map { existing[$0] }
            return DisplayConfiguration(id: prior?.id, index: offset + 1, name: item.name,
                selector: item.systemUUID.uppercased(), macInput: prior?.macInput,
                windowsInput: prior?.windowsInput, readEnabled: prior?.readEnabled ?? false)
        }
        try saveAll(merged, defaults: defaults, clearSafetyMarker: false)
        return merged
    }

    static func defaultConfiguration(index: Int, legacyDefaults: Bool = true) -> DisplayConfiguration {
        DisplayConfiguration(index: index, name: "显示器 \(index)", selector: "\(index)",
            macInput: legacyDefaults ? (index == 1 ? 15 : 17) : nil,
            windowsInput: legacyDefaults ? (index == 1 ? 18 : 15) : nil,
            readEnabled: legacyDefaults && index == 1)
    }

    static func inspectProfile(_ profile: CollaborationProfile,
                               displays: [DisplayConfigurationV3Display],
                               ddcAvailableDisplayIDs: Set<String>) -> LocalProfileInspection {
        var issues = Set<LocalProfileIssue>()
        if clean(profile.name, limit: profileNameLimit) == nil { issues.insert(.missingName) }
        if clean(profile.peerHost, limit: 253) == nil { issues.insert(.missingHost) }
        if !(1...65535).contains(profile.peerPort) { issues.insert(.invalidPort) }
        if !validPairing(profile.pairingCode, allowEmpty: false) { issues.insert(.invalidPairingCode) }
        let known = Set(displays.map { $0.id.lowercased() })
        let mapped = Set(profile.displayInputs.map { $0.displayID.lowercased() })
        if !known.isSubset(of: mapped) { issues.insert(.missingDisplayMapping) }
        if !mapped.isSubset(of: known) { issues.insert(.orphanedDisplayMapping) }
        let unavailable = displays.map(\.id).filter { !ddcAvailableDisplayIDs.contains($0.lowercased()) }
        return LocalProfileInspection(issues: issues.sorted { $0.rawValue < $1.rawValue }, ddcUnavailableDisplayIDs: unavailable)
    }

    static func checkPeerIdentity(_ profile: CollaborationProfile, endpointID: String, protocolVersion: Int) -> PeerIdentityCheck {
        guard let candidate = uuid(endpointID), protocolVersion == 1 || protocolVersion == 2 else { return .invalid }
        guard let previous = profile.peerEndpointID else {
            return .firstConfirmationRequired(endpointID: candidate, protocolVersion: protocolVersion)
        }
        guard let old = uuid(previous) else { return .invalid }
        if old.caseInsensitiveCompare(candidate) == .orderedSame && profile.peerProtocolVersion == protocolVersion { return .unchanged }
        return .changeConfirmationRequired(previousEndpointID: old, endpointID: candidate, protocolVersion: protocolVersion)
    }

    private static func migrate(_ legacy: [DisplayConfiguration], storage: DisplayConfigurationStorage,
                                encoder: DocumentEncoder, priorFailure: Bool) -> DisplayConfigurationLoadResult {
        do {
            let displays = try convert(legacy, preserving: [])
            var profile = defaultProfile(name: "Windows")
            profile.peerHost = clean(storage.string(forKey: legacyPeer.host), limit: 253) ?? ""
            let storedPort = storage.object(forKey: legacyPeer.port) == nil ? defaultPort : storage.integer(forKey: legacyPeer.port)
            profile.peerPort = (1...65535).contains(storedPort) ? storedPort : defaultPort
            profile.pairingCode = normalizedPairing(storage.string(forKey: legacyPeer.code) ?? "")
            profile.coordinationEnabled = storage.bool(forKey: legacyPeer.enabled)
            profile.triggerDevices = migrateTrigger(storage)
            profile.displayInputs = zip(legacy, displays).compactMap { old, display in
                validInput(old.windowsInput).map { DisplayInputMapping(displayID: display.id, peerInput: $0) }
            }
            let document = try validate(DisplayConfigurationStoreV3Document(schemaVersion: currentSchemaVersion,
                localEndpointID: UUID().uuidString, localDeviceName: "本机", listenPort: defaultPort,
                displays: displays, collaborationProfiles: [profile]))
            try persist(document, storage: storage, encoder: encoder)
            return result(document, priorFailure ? .requiresUserReview(.previousFailureRequiresReview) : .ready)
        } catch let error as DisplayConfigurationStoreError { return failed(error, storage: storage, recovery: legacy) }
        catch { return failed(.writeFailed, storage: storage, recovery: legacy) }
    }

    private static func persist(_ document: DisplayConfigurationStoreV3Document,
                                storage: DisplayConfigurationStorage, encoder: DocumentEncoder) throws {
        let data: Data
        do { data = try encoder(document) }
        catch let error as DisplayConfigurationStoreError { throw error }
        catch { throw DisplayConfigurationStoreError.encodingFailed }
        do { try storage.writeDocument(data, forKey: storageKey) }
        catch { throw DisplayConfigurationStoreError.writeFailed }
    }

    private static func failed(_ error: DisplayConfigurationStoreError, storage: DisplayConfigurationStorage,
                               recovery: [DisplayConfiguration] = []) -> DisplayConfigurationLoadResult {
        storage.set(true, forKey: requiresReviewKey)
        var document = freshDocument()
        if !recovery.isEmpty, let displays = try? convert(recovery, preserving: []) {
            document.displays = displays
            document.collaborationProfiles[0].displayInputs = zip(recovery, displays).compactMap { old, display in
                validInput(old.windowsInput).map { DisplayInputMapping(displayID: display.id, peerInput: $0) }
            }
        }
        return result(document, .requiresUserReview(error))
    }

    private static func result(_ document: DisplayConfigurationStoreV3Document,
                               _ state: DisplayConfigurationSafetyState) -> DisplayConfigurationLoadResult {
        DisplayConfigurationLoadResult(configurations: legacyView(document), collaborationProfiles: document.collaborationProfiles,
                                       document: document, safetyState: state)
    }

    private static func freshDocument() -> DisplayConfigurationStoreV3Document {
        DisplayConfigurationStoreV3Document(schemaVersion: currentSchemaVersion, localEndpointID: UUID().uuidString,
            localDeviceName: "本机", listenPort: defaultPort, displays: [], collaborationProfiles: [defaultProfile()])
    }

    private static func defaultProfile(name: String = "配置 1") -> CollaborationProfile {
        CollaborationProfile(id: UUID().uuidString, name: name, peerHost: "", peerPort: defaultPort,
            pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil, coordinationEnabled: false,
            displayInputs: [], triggerDevices: [])
    }

    private static func validate(_ document: DisplayConfigurationStoreV3Document) throws -> DisplayConfigurationStoreV3Document {
        guard document.schemaVersion == currentSchemaVersion else { throw DisplayConfigurationStoreError.unsupportedSchemaVersion(document.schemaVersion) }
        guard let endpoint = uuid(document.localEndpointID), let deviceName = clean(document.localDeviceName, limit: 32),
              (1...65535).contains(document.listenPort), !document.collaborationProfiles.isEmpty else {
            throw DisplayConfigurationStoreError.invalidConfiguration
        }
        var displayIDs = Set<String>()
        let displays = try document.displays.map { display -> DisplayConfigurationV3Display in
            guard let id = uuid(display.id), displayIDs.insert(id.lowercased()).inserted,
                  let name = clean(display.name, limit: displayNameLimit), let selector = clean(display.selector, limit: textLimit),
                  display.localInput == nil || validInput(display.localInput) != nil else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            return DisplayConfigurationV3Display(id: id, name: name, selector: selector, localInput: display.localInput,
                readEnabled: display.readEnabled, brightnessEnabled: display.brightnessEnabled,
                contrastEnabled: display.contrastEnabled, volumeEnabled: display.volumeEnabled)
        }
        var profileIDs = Set<String>()
        var profileNames = Set<String>()
        let profiles = try document.collaborationProfiles.map { profile -> CollaborationProfile in
            let foldedName = normalizedPairing(profile.name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard let id = uuid(profile.id), profileIDs.insert(id.lowercased()).inserted,
                  let name = clean(profile.name, limit: profileNameLimit), profileNames.insert(foldedName).inserted,
                  profile.peerHost.isEmpty || clean(profile.peerHost, limit: 253) != nil,
                  (1...65535).contains(profile.peerPort), validPairing(profile.pairingCode, allowEmpty: true),
                  profile.peerEndpointID == nil || uuid(profile.peerEndpointID) != nil,
                  profile.peerProtocolVersion == nil || profile.peerProtocolVersion == 1 || profile.peerProtocolVersion == 2 else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            var mappingIDs = Set<String>()
            let mappings = try profile.displayInputs.map { item -> DisplayInputMapping in
                guard let displayID = uuid(item.displayID), mappingIDs.insert(displayID.lowercased()).inserted,
                      let input = validInput(item.peerInput) else { throw DisplayConfigurationStoreError.invalidConfiguration }
                return DisplayInputMapping(displayID: displayID, peerInput: input)
            }
            let triggers = try profile.triggerDevices.map { item -> CollaborationTriggerDevice in
                let kind = item.kind.lowercased()
                guard (kind == "usb" || kind == "bluetooth"), let reference = clean(item.localReference, limit: textLimit) else {
                    throw DisplayConfigurationStoreError.invalidConfiguration
                }
                let displayName = item.displayName.isEmpty ? "" : (clean(item.displayName, limit: displayNameLimit) ?? "")
                if !item.displayName.isEmpty && displayName.isEmpty { throw DisplayConfigurationStoreError.invalidConfiguration }
                return CollaborationTriggerDevice(kind: kind, localReference: reference, displayName: displayName)
            }
            return CollaborationProfile(id: id, name: name,
                peerHost: profile.peerHost.isEmpty ? "" : clean(profile.peerHost, limit: 253)!, peerPort: profile.peerPort,
                pairingCode: normalizedPairing(profile.pairingCode), peerEndpointID: profile.peerEndpointID.flatMap(uuid),
                peerProtocolVersion: profile.peerProtocolVersion, coordinationEnabled: profile.coordinationEnabled,
                displayInputs: mappings, triggerDevices: triggers)
        }
        return DisplayConfigurationStoreV3Document(schemaVersion: currentSchemaVersion, localEndpointID: endpoint,
            localDeviceName: deviceName, listenPort: document.listenPort, displays: displays, collaborationProfiles: profiles)
    }

    private static func convert(_ configurations: [DisplayConfiguration],
                                preserving existing: [DisplayConfigurationV3Display]) throws -> [DisplayConfigurationV3Display] {
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id.lowercased(), $0) })
        let bySelector = Dictionary(grouping: existing, by: { $0.selector.lowercased() })
        var used = Set<String>()
        return try configurations.enumerated().map { offset, item in
            guard let name = clean(item.name, limit: displayNameLimit), let selector = clean(item.selector, limit: textLimit),
                  item.macInput == nil || validInput(item.macInput) != nil else { throw DisplayConfigurationStoreError.invalidConfiguration }
            let prior = item.id.flatMap(uuid).flatMap { byID[$0.lowercased()] }
                ?? (bySelector[selector.lowercased()]?.count == 1 ? bySelector[selector.lowercased()]?.first : nil)
                ?? (existing.indices.contains(offset) && Int(item.selector) != nil ? existing[offset] : nil)
            let id = item.id.flatMap(uuid) ?? prior?.id ?? UUID().uuidString
            guard used.insert(id.lowercased()).inserted else { throw DisplayConfigurationStoreError.invalidConfiguration }
            return DisplayConfigurationV3Display(id: id, name: name, selector: selector, localInput: item.macInput,
                readEnabled: item.readEnabled, brightnessEnabled: prior?.brightnessEnabled ?? true,
                contrastEnabled: prior?.contrastEnabled ?? true, volumeEnabled: prior?.volumeEnabled ?? true)
        }
    }

    private static func legacyView(_ document: DisplayConfigurationStoreV3Document) -> [DisplayConfiguration] {
        let mappings = Dictionary(uniqueKeysWithValues: document.collaborationProfiles.first?.displayInputs.map { ($0.displayID.lowercased(), $0.peerInput) } ?? [])
        return document.displays.enumerated().map { index, display in
            DisplayConfiguration(id: display.id, index: index + 1, name: display.name, selector: display.selector,
                macInput: display.localInput, windowsInput: mappings[display.id.lowercased()], readEnabled: display.readEnabled)
        }
    }

    private static func mergeLegacyInputs(_ configurations: [DisplayConfiguration], displays: [DisplayConfigurationV3Display],
                                          existing: [DisplayInputMapping]) -> [DisplayInputMapping] {
        let currentIDs = Set(displays.map { $0.id.lowercased() })
        var result = existing.filter { !currentIDs.contains($0.displayID.lowercased()) }
        for (old, display) in zip(configurations, displays) {
            if let input = validInput(old.windowsInput) { result.append(DisplayInputMapping(displayID: display.id, peerInput: input)) }
        }
        return result
    }

    private static func hasLegacyDisplayKeys(_ storage: DisplayConfigurationStorage) -> Bool {
        (1...2).contains { index in
            ["Name", "Selector", "MacInput", "WindowsInput", "ReadEnabled"].contains {
                storage.object(forKey: "Display.\(index).\($0)") != nil
            }
        }
    }

    private static func loadLegacyDisplays(_ storage: DisplayConfigurationStorage) -> [DisplayConfiguration] {
        (1...2).map { index in
            let fallback = defaultConfiguration(index: index)
            let prefix = "Display.\(index)"
            return DisplayConfiguration(index: index,
                name: storage.string(forKey: "\(prefix).Name") ?? fallback.name,
                selector: storage.string(forKey: "\(prefix).Selector") ?? fallback.selector,
                macInput: storage.object(forKey: "\(prefix).MacInput") == nil ? fallback.macInput : storage.integer(forKey: "\(prefix).MacInput"),
                windowsInput: storage.object(forKey: "\(prefix).WindowsInput") == nil ? fallback.windowsInput : storage.integer(forKey: "\(prefix).WindowsInput"),
                readEnabled: storage.object(forKey: "\(prefix).ReadEnabled") == nil ? fallback.readEnabled : storage.bool(forKey: "\(prefix).ReadEnabled"))
        }
    }

    private static func migrateTrigger(_ storage: DisplayConfigurationStorage) -> [CollaborationTriggerDevice] {
        guard let data = storage.data(forKey: "USBAutomation.Device"),
              let device = try? JSONDecoder().decode(LegacyUSBDevice.self, from: data) else { return [] }
        let reference = "\(device.vendorID):\(device.productID)"
        return [CollaborationTriggerDevice(kind: "usb", localReference: reference, displayName: device.displayName)]
    }

    private static func validInput(_ value: Int?) -> Int? {
        guard let value, (0...65535).contains(value) else { return nil }
        return value
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= limit,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return normalized
    }

    private static func normalizedPairing(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validPairing(_ value: String, allowEmpty: Bool) -> Bool {
        let normalized = normalizedPairing(value)
        if normalized.isEmpty { return allowEmpty }
        return (8...128).contains(normalized.utf8.count)
            && !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func uuid(_ value: String?) -> String? {
        guard let value, let parsed = UUID(uuidString: value) else { return nil }
        return parsed.uuidString
    }
}
