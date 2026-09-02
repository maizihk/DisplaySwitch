import Foundation

struct DisplayConfiguration: Codable, Equatable {
    let id: String?
    let index: Int
    var name: String
    var selector: String
    var localInput: Int?
    var targetInput: Int?
    var readEnabled: Bool

    init(id: String? = nil, index: Int, name: String, selector: String, localInput: Int?, targetInput: Int?, readEnabled: Bool) {
        self.id = id
        self.index = index
        self.name = name
        self.selector = selector
        self.localInput = localInput
        self.targetInput = targetInput
        self.readEnabled = readEnabled
    }
}

struct DetectedDisplay: Equatable {
    let index: Int
    let name: String
    let systemUUID: String

}

struct DisplayDetectionReconciliation: Equatable {
    let persistedConfigurations: [DisplayConfiguration]
    let onlineConfigurations: [DisplayConfiguration]
}

struct DisplayDeletionMutation: Equatable {
    let document: DisplayConfigurationStoreV5Document
    let removedStableID: String
    let removedSelector: String
}

enum DisplayDeletionConfirmationPolicy {
    static func shouldProceed(userConfirmed: Bool) -> Bool { userConfirmed }
}

enum DisplayDeletionPlanner {
    static func removing(
        stableID: String,
        from document: DisplayConfigurationStoreV5Document
    ) -> DisplayDeletionMutation? {
        guard let removed = document.displays.first(where: {
            $0.id.caseInsensitiveCompare(stableID) == .orderedSame
        }) else { return nil }

        var updated = document
        updated.displays.removeAll {
            $0.id.caseInsensitiveCompare(removed.id) == .orderedSame
        }
        updated.usbSwitch.displayInputs.removeAll {
            $0.displayID.caseInsensitiveCompare(removed.id) == .orderedSame
        }
        if !DisplayConfigurationStore.isCompleteUSBConfiguration(
            updated.usbSwitch,
            displays: updated.displays
        ) {
            updated.usbSwitch.enabled = false
        }

        updated.collaborationProfiles = updated.collaborationProfiles.map { profile in
            var value = profile
            value.displayInputs.removeAll {
                $0.displayID.caseInsensitiveCompare(removed.id) == .orderedSame
            }
            return DisplayConfigurationStore.profileForSafeSave(
                value,
                displays: updated.displays
            ).profile
        }
        if updated.usbSwitch.collaborationWakeEnabled,
           !DisplayConfigurationStore.isValidCollaborationWakeSelection(
               updated.usbSwitch,
               document: updated
           ) {
            updated.usbSwitch.collaborationWakeEnabled = false
        }

        return DisplayDeletionMutation(
            document: updated,
            removedStableID: removed.id,
            removedSelector: removed.selector
        )
    }
}

struct DisplayDeletionAvailability: Equatable {
    enum DetectionState: Equatable {
        case notChecked
        case detecting
        case untrusted
        case trusted
    }

    let detectionState: DetectionState
    let offlineStableIDs: Set<String>

    static let notChecked = DisplayDeletionAvailability(
        detectionState: .notChecked,
        offlineStableIDs: []
    )

    func allowsDeletion(stableID: String) -> Bool {
        detectionState == .trusted && offlineStableIDs.contains(stableID.lowercased())
    }
}

final class DisplayDeletionAvailabilityTracker {
    private var consecutiveTrustedMisses: [String: Int] = [:]
    private(set) var availability: DisplayDeletionAvailability = .notChecked

    func beginDetection() {
        availability = DisplayDeletionAvailability(detectionState: .detecting, offlineStableIDs: [])
    }

    func recordFailureOrUntrustedResult() {
        consecutiveTrustedMisses.removeAll()
        availability = DisplayDeletionAvailability(detectionState: .untrusted, offlineStableIDs: [])
    }

    func recordSuccessfulDetection(
        detected: [DetectedDisplay],
        savedDisplays: [DisplayConfigurationV4Display]
    ) {
        let normalizedSelectors = detected.map {
            $0.systemUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !normalizedSelectors.isEmpty,
              normalizedSelectors.allSatisfy({ !$0.isEmpty }),
              Set(normalizedSelectors).count == normalizedSelectors.count else {
            recordFailureOrUntrustedResult()
            return
        }

        let online = Set(normalizedSelectors)
        var nextMisses: [String: Int] = [:]
        var offline = Set<String>()
        for display in savedDisplays {
            let selector = display.selector.lowercased()
            if online.contains(selector) {
                nextMisses[selector] = 0
            } else {
                let misses = (consecutiveTrustedMisses[selector] ?? 0) + 1
                nextMisses[selector] = misses
                if misses >= 2 {
                    offline.insert(display.id.lowercased())
                }
            }
        }
        consecutiveTrustedMisses = nextMisses
        availability = DisplayDeletionAvailability(
            detectionState: .trusted,
            offlineStableIDs: offline
        )
    }

    func remove(stableID: String) {
        availability = DisplayDeletionAvailability(
            detectionState: availability.detectionState,
            offlineStableIDs: availability.offlineStableIDs.subtracting([stableID.lowercased()])
        )
    }
}

struct DisplayConfigurationV4Display: Codable, Equatable {
    let id: String
    var name: String
    var selector: String
    var localInput: Int?
    var readEnabled: Bool
    var brightnessEnabled: Bool
    var contrastEnabled: Bool
    var volumeEnabled: Bool
    var brightnessShowInTray: Bool
    var contrastShowInTray: Bool
    var volumeShowInTray: Bool

    init(id: String, name: String, selector: String, localInput: Int?, readEnabled: Bool,
         brightnessEnabled: Bool = false, contrastEnabled: Bool = false,
         volumeEnabled: Bool = false, brightnessShowInTray: Bool = false,
         contrastShowInTray: Bool = false, volumeShowInTray: Bool = false) {
        self.id = id
        self.name = name
        self.selector = selector
        self.localInput = localInput
        self.readEnabled = readEnabled
        self.brightnessEnabled = brightnessEnabled
        self.contrastEnabled = contrastEnabled
        self.volumeEnabled = volumeEnabled
        self.brightnessShowInTray = brightnessShowInTray
        self.contrastShowInTray = contrastShowInTray
        self.volumeShowInTray = volumeShowInTray
    }
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

struct USBDisplayInputMapping: Codable, Equatable {
    let displayID: String
    var targetInput: Int
}

enum InputSourceValuePolicy {
    static let safeRange = 1...65_535

    enum FieldValue: Equatable {
        case empty
        case valid(Int)
        case invalid
    }

    static func isSafe(_ value: Int) -> Bool {
        safeRange.contains(value)
    }

    static func nativeValue(_ value: Int) -> UInt16? {
        guard isSafe(value) else { return nil }
        return UInt16(value)
    }

    static func parseField(_ text: String) -> FieldValue {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .empty }
        guard let value = Int(normalized), isSafe(value) else { return .invalid }
        return .valid(value)
    }
}

struct USBSwitchConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var triggerDevice: CollaborationTriggerDevice?
    var collaborationWakeEnabled: Bool = false
    var collaborationProfileID: String?
    var displayInputs: [USBDisplayInputMapping] = []

    static let disabled = USBSwitchConfiguration()
}

struct DisplayConfigurationStoreV5Document: Codable, Equatable {
    let schemaVersion: Int
    let localEndpointID: String
    var localDeviceName: String
    var listenPort: Int
    var linkAllDisplays: Bool
    var displays: [DisplayConfigurationV4Display]
    var collaborationProfiles: [CollaborationProfile]
    var usbSwitch: USBSwitchConfiguration = .disabled
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
    let document: DisplayConfigurationStoreV5Document
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

    var userFacingDescription: String {
        switch self {
        case .missingName:
            return "请填写配置名称。"
        case .missingHost:
            return "请填写对端地址。"
        case .invalidPort:
            return "通信端口必须在 1–65535 之间。"
        case .invalidPairingCode:
            return "配对码必须为 8–128 个 UTF-8 字节。"
        case .missingDisplayMapping:
            return "请至少为一台显示器填写 1–65535 的对端输入源。"
        case .orphanedDisplayMapping:
            return "存在不再对应当前显示器的旧输入源映射，请重新保存配置。"
        }
    }
}

struct LocalProfileInspection: Equatable {
    let issues: [LocalProfileIssue]
    let ddcUnavailableDisplayIDs: [String]
    var isComplete: Bool { issues.isEmpty && ddcUnavailableDisplayIDs.isEmpty }
}

struct CollaborationProfileSaveDecision: Equatable {
    let profile: CollaborationProfile
    let disabledBecauseIncomplete: Bool
}

final class USBLearningSafetyGate {
    private let lock = NSLock()
    private var active = false

    func begin() {
        lock.lock()
        active = true
        lock.unlock()
    }

    @discardableResult
    func end() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasActive = active
        active = false
        return wasActive
    }

    func allows(_ sideEffect: ConfigurationSideEffect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !active
    }
}

enum PeerIdentityCheck: Equatable {
    case unchanged
    case firstConfirmationRequired(endpointID: String, protocolVersion: Int)
    case changeConfirmationRequired(previousEndpointID: String, endpointID: String, protocolVersion: Int)
    case invalid

    var requiresConfirmation: Bool {
        switch self {
        case .firstConfirmationRequired, .changeConfirmationRequired: return true
        case .unchanged, .invalid: return false
        }
    }
}

enum DisplayConfigurationStore {
    static let storageKey = "Displays.Configuration.v5"
    static let legacyV4StorageKey = "Displays.Configuration.v4"
    static let legacyV3StorageKey = "Displays.Configuration.v3"
    static let legacyBackupStorageKey = "Displays.Configuration.pre-v5.backup"
    static let legacyDocumentStorageKey = "Displays.Configuration.v2"
    static let legacyArrayStorageKey = "Displays.Configuration.v1"
    static let requiresReviewKey = "Displays.Configuration.RequiresReview"
    static let currentSchemaVersion = 5

    typealias DocumentEncoder = (DisplayConfigurationStoreV5Document) throws -> Data
    typealias DocumentDecoder = (Data) throws -> DisplayConfigurationStoreV5Document

    private struct LegacyV4Document: Codable {
        let schemaVersion: Int
        let localEndpointID: String
        var localDeviceName: String
        var listenPort: Int
        var linkAllDisplays: Bool
        var usbAutomationEnabled: Bool
        var usbSwitchDisplaysOnArrival: Bool
        var displays: [DisplayConfigurationV4Display]
        var collaborationProfiles: [CollaborationProfile]
    }

    private static let defaultPort = 49731
    private static let profileNameLimit = 32
    private static let displayNameLimit = 64
    private static let textLimit = 255
    private struct VersionProbe: Decodable { let schemaVersion: Int }

    static func load(defaults: UserDefaults = .standard) -> DisplayConfigurationLoadResult {
        load(storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults))
    }

    static func load(storage: DisplayConfigurationStorage,
                     decodeDocument: DocumentDecoder = { try JSONDecoder().decode(DisplayConfigurationStoreV5Document.self, from: $0) },
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
        if let data = storage.data(forKey: legacyV4StorageKey) {
            return migrateV4Configuration(data: data, storage: storage, encoder: encodeDocument,
                                          priorFailure: priorFailure)
        }
        if let legacyData = firstLegacyDocument(in: storage) {
            return replaceLegacyConfiguration(
                legacyData: legacyData,
                storage: storage,
                encoder: encodeDocument,
                priorFailure: priorFailure
            )
        }
        if hasLegacyDisplayKeys(storage) {
            return replaceLegacyConfiguration(
                legacyData: Data("legacy-key-value-configuration".utf8),
                storage: storage,
                encoder: encodeDocument,
                priorFailure: priorFailure
            )
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
        let profiles = collaborationProfiles ?? current.collaborationProfiles
        let document = DisplayConfigurationStoreV5Document(schemaVersion: currentSchemaVersion,
            localEndpointID: current.document.localEndpointID, localDeviceName: current.document.localDeviceName,
            listenPort: current.document.listenPort,
            linkAllDisplays: current.document.linkAllDisplays,
            displays: displays, collaborationProfiles: profiles, usbSwitch: current.document.usbSwitch)
        try saveDocument(document, storage: storage, clearSafetyMarker: clearSafetyMarker, encodeDocument: encodeDocument)
    }

    static func saveDocument(_ document: DisplayConfigurationStoreV5Document,
                             defaults: UserDefaults = .standard,
                             clearSafetyMarker: Bool = true) throws {
        try saveDocument(document, storage: UserDefaultsDisplayConfigurationStorage(defaults: defaults), clearSafetyMarker: clearSafetyMarker)
    }

    static func saveDocument(_ document: DisplayConfigurationStoreV5Document,
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

    static func reconcileDetectedDisplays(
        detected: [DetectedDisplay],
        existing: [DisplayConfiguration]
    ) -> DisplayDetectionReconciliation {
        var used = Set<Int>()
        let online = detected.sorted { $0.index < $1.index }.enumerated().map { offset, item in
            let exact = existing.indices.first { !used.contains($0) && existing[$0].selector.caseInsensitiveCompare(item.systemUUID) == .orderedSame }
            let legacyNames = existing.indices.filter { !used.contains($0) && Int(existing[$0].selector) != nil && existing[$0].name.caseInsensitiveCompare(item.name) == .orderedSame }
            let match = exact ?? (legacyNames.count == 1 ? legacyNames[0] : nil)
            if let match { used.insert(match) }
            let prior = match.map { existing[$0] }
            return DisplayConfiguration(id: prior?.id, index: offset + 1, name: item.name,
                selector: item.systemUUID.uppercased(), localInput: prior?.localInput,
                targetInput: nil, readEnabled: prior?.readEnabled ?? false)
        }
        let offline = existing.indices.filter { !used.contains($0) }.map { existing[$0] }
        let persisted = (online + offline).enumerated().map { offset, configuration in
            DisplayConfiguration(
                id: configuration.id,
                index: offset + 1,
                name: configuration.name,
                selector: configuration.selector,
                localInput: configuration.localInput,
                targetInput: configuration.targetInput,
                readEnabled: configuration.readEnabled
            )
        }
        let persistedByStableID = Dictionary(uniqueKeysWithValues: persisted.map {
            (($0.id ?? $0.selector).lowercased(), $0)
        })
        let resolvedOnline = online.compactMap {
            persistedByStableID[($0.id ?? $0.selector).lowercased()]
        }
        return DisplayDetectionReconciliation(
            persistedConfigurations: persisted,
            onlineConfigurations: resolvedOnline
        )
    }

    static func merge(detected: [DetectedDisplay], existing: [DisplayConfiguration], defaults: UserDefaults = .standard) throws -> [DisplayConfiguration] {
        let reconciliation = reconcileDetectedDisplays(detected: detected, existing: existing)
        try saveAll(reconciliation.persistedConfigurations, defaults: defaults, clearSafetyMarker: false)
        return reconciliation.persistedConfigurations
    }

    static func defaultConfiguration(index: Int) -> DisplayConfiguration {
        DisplayConfiguration(index: index, name: "显示器 \(index)", selector: "\(index)",
            localInput: nil, targetInput: nil, readEnabled: false)
    }

    static func inspectProfile(_ profile: CollaborationProfile,
                               displays: [DisplayConfigurationV4Display],
                               ddcAvailableDisplayIDs: Set<String>) -> LocalProfileInspection {
        var issues = Set<LocalProfileIssue>()
        if clean(profile.name, limit: profileNameLimit) == nil { issues.insert(.missingName) }
        if clean(profile.peerHost, limit: 253) == nil { issues.insert(.missingHost) }
        if !(1...65535).contains(profile.peerPort) { issues.insert(.invalidPort) }
        if !validPairing(profile.pairingCode, allowEmpty: false) { issues.insert(.invalidPairingCode) }
        let known = Set(displays.map { $0.id.lowercased() })
        let mapped = Set(profile.displayInputs.map { $0.displayID.lowercased() })
        let validMapped = Set(profile.displayInputs.compactMap { mapping in
            InputSourceValuePolicy.isSafe(mapping.peerInput) ? mapping.displayID.lowercased() : nil
        })
        if known.isEmpty || validMapped.isEmpty || validMapped.count != profile.displayInputs.count {
            issues.insert(.missingDisplayMapping)
        }
        if !mapped.isSubset(of: known) { issues.insert(.orphanedDisplayMapping) }
        let unavailable = displays.map(\.id).filter { !ddcAvailableDisplayIDs.contains($0.lowercased()) }
        return LocalProfileInspection(issues: issues.sorted { $0.rawValue < $1.rawValue }, ddcUnavailableDisplayIDs: unavailable)
    }

    static func profileForSafeSave(_ profile: CollaborationProfile,
                                   displays: [DisplayConfigurationV4Display]) -> CollaborationProfileSaveDecision {
        guard profile.coordinationEnabled else {
            return CollaborationProfileSaveDecision(profile: profile, disabledBecauseIncomplete: false)
        }
        let known = Set(displays.map { $0.id.lowercased() })
        let inspection = inspectProfile(profile, displays: displays, ddcAvailableDisplayIDs: known)
        guard !inspection.issues.isEmpty else {
            return CollaborationProfileSaveDecision(profile: profile, disabledBecauseIncomplete: false)
        }
        var safeProfile = profile
        safeProfile.coordinationEnabled = false
        return CollaborationProfileSaveDecision(profile: safeProfile, disabledBecauseIncomplete: true)
    }

    static func menuEligibleProfiles(in document: DisplayConfigurationStoreV5Document) -> [CollaborationProfile] {
        let knownDisplayIDs = Set(document.displays.map { $0.id.lowercased() })
        return document.collaborationProfiles.filter { profile in
            profile.coordinationEnabled
                && inspectProfile(profile, displays: document.displays,
                                  ddcAvailableDisplayIDs: knownDisplayIDs).issues.isEmpty
        }
    }

    static func checkPeerIdentity(_ profile: CollaborationProfile, endpointID: String, protocolVersion: Int) -> PeerIdentityCheck {
        guard let candidate = uuid(endpointID), protocolVersion == 2 else { return .invalid }
        guard let previous = profile.peerEndpointID else {
            return .firstConfirmationRequired(endpointID: candidate, protocolVersion: protocolVersion)
        }
        guard let old = uuid(previous) else { return .invalid }
        if old.caseInsensitiveCompare(candidate) == .orderedSame && profile.peerProtocolVersion == protocolVersion { return .unchanged }
        return .changeConfirmationRequired(previousEndpointID: old, endpointID: candidate, protocolVersion: protocolVersion)
    }

    static func isCompleteUSBConfiguration(_ usbSwitch: USBSwitchConfiguration,
                                           displays: [DisplayConfigurationV4Display]) -> Bool {
        guard usbSwitch.triggerDevice?.kind.caseInsensitiveCompare("usb") == .orderedSame else { return false }
        let known = Set(displays.map { $0.id.lowercased() })
        return usbSwitch.displayInputs.contains {
            known.contains($0.displayID.lowercased()) && InputSourceValuePolicy.isSafe($0.targetInput)
        }
    }

    static func isValidCollaborationWakeSelection(_ usbSwitch: USBSwitchConfiguration,
                                                  document: DisplayConfigurationStoreV5Document) -> Bool {
        guard usbSwitch.collaborationWakeEnabled,
              let profileID = usbSwitch.collaborationProfileID,
              let profile = document.collaborationProfiles.first(where: {
                  $0.id.caseInsensitiveCompare(profileID) == .orderedSame
              }), profile.coordinationEnabled,
              profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID) != nil,
              profile.peerProtocolVersion == 2 else { return false }
        let known = Set(document.displays.map { $0.id.lowercased() })
        return inspectProfile(profile, displays: document.displays,
                              ddcAvailableDisplayIDs: known).issues.isEmpty
    }

    private static func migrateV4Configuration(data: Data, storage: DisplayConfigurationStorage,
                                               encoder: DocumentEncoder, priorFailure: Bool) -> DisplayConfigurationLoadResult {
        do {
            let version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
            guard version == 4 else { throw DisplayConfigurationStoreError.unsupportedSchemaVersion(version) }
            let legacy = try JSONDecoder().decode(LegacyV4Document.self, from: data)
            if storage.data(forKey: legacyBackupStorageKey) == nil {
                storage.set(data, forKey: legacyBackupStorageKey)
                guard storage.data(forKey: legacyBackupStorageKey) == data else {
                    throw DisplayConfigurationStoreError.writeFailed
                }
            }
            let document = DisplayConfigurationStoreV5Document(
                schemaVersion: currentSchemaVersion,
                localEndpointID: legacy.localEndpointID,
                localDeviceName: legacy.localDeviceName,
                listenPort: legacy.listenPort,
                linkAllDisplays: legacy.linkAllDisplays,
                displays: legacy.displays,
                collaborationProfiles: legacy.collaborationProfiles,
                usbSwitch: .disabled
            )
            let validated = try validate(document)
            try persist(validated, storage: storage, encoder: encoder)
            return result(validated, priorFailure ? .requiresUserReview(.previousFailureRequiresReview) : .ready)
        } catch let error as DisplayConfigurationStoreError { return failed(error, storage: storage) }
        catch { return failed(.corruptedData, storage: storage) }
    }

    private static func replaceLegacyConfiguration(
        legacyData: Data,
        storage: DisplayConfigurationStorage,
        encoder: DocumentEncoder,
        priorFailure: Bool
    ) -> DisplayConfigurationLoadResult {
        do {
            if storage.data(forKey: legacyBackupStorageKey) == nil {
                storage.set(legacyData, forKey: legacyBackupStorageKey)
                guard storage.data(forKey: legacyBackupStorageKey) == legacyData else {
                    throw DisplayConfigurationStoreError.writeFailed
                }
            }
            let document = freshDocument()
            try persist(document, storage: storage, encoder: encoder)
            return result(document, priorFailure ? .requiresUserReview(.previousFailureRequiresReview) : .ready)
        } catch let error as DisplayConfigurationStoreError { return failed(error, storage: storage) }
        catch { return failed(.writeFailed, storage: storage) }
    }

    private static func persist(_ document: DisplayConfigurationStoreV5Document,
                                storage: DisplayConfigurationStorage, encoder: DocumentEncoder) throws {
        let data: Data
        do { data = try encoder(document) }
        catch let error as DisplayConfigurationStoreError { throw error }
        catch { throw DisplayConfigurationStoreError.encodingFailed }
        let stagingKey = "\(storageKey).staging"
        let previous = storage.data(forKey: storageKey)
        storage.set(data, forKey: stagingKey)
        guard storage.data(forKey: stagingKey) == data else {
            storage.removeObject(forKey: stagingKey)
            throw DisplayConfigurationStoreError.writeFailed
        }
        defer { storage.removeObject(forKey: stagingKey) }
        do {
            try storage.writeDocument(data, forKey: storageKey)
            guard storage.data(forKey: storageKey) == data else {
                throw DisplayConfigurationStoreError.writeFailed
            }
        } catch {
            if let previous { storage.set(previous, forKey: storageKey) }
            else { storage.removeObject(forKey: storageKey) }
            throw DisplayConfigurationStoreError.writeFailed
        }
    }

    private static func failed(_ error: DisplayConfigurationStoreError,
                               storage: DisplayConfigurationStorage) -> DisplayConfigurationLoadResult {
        storage.set(true, forKey: requiresReviewKey)
        return result(freshDocument(), .requiresUserReview(error))
    }

    private static func result(_ document: DisplayConfigurationStoreV5Document,
                               _ state: DisplayConfigurationSafetyState) -> DisplayConfigurationLoadResult {
        DisplayConfigurationLoadResult(configurations: legacyView(document), collaborationProfiles: document.collaborationProfiles,
                                       document: document, safetyState: state)
    }

    private static func freshDocument() -> DisplayConfigurationStoreV5Document {
        DisplayConfigurationStoreV5Document(schemaVersion: currentSchemaVersion, localEndpointID: UUID().uuidString,
            localDeviceName: "本机", listenPort: defaultPort,
            linkAllDisplays: false, displays: [], collaborationProfiles: [defaultProfile()], usbSwitch: .disabled)
    }

    private static func defaultProfile(name: String = "配置 1") -> CollaborationProfile {
        CollaborationProfile(id: UUID().uuidString, name: name, peerHost: "", peerPort: defaultPort,
            pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil, coordinationEnabled: false,
            displayInputs: [], triggerDevices: [])
    }

    private static func validate(_ document: DisplayConfigurationStoreV5Document) throws -> DisplayConfigurationStoreV5Document {
        guard document.schemaVersion == currentSchemaVersion else { throw DisplayConfigurationStoreError.unsupportedSchemaVersion(document.schemaVersion) }
        guard let endpoint = uuid(document.localEndpointID), let deviceName = clean(document.localDeviceName, limit: 32),
              (1...65535).contains(document.listenPort), !document.collaborationProfiles.isEmpty else {
            throw DisplayConfigurationStoreError.invalidConfiguration
        }
        var displayIDs = Set<String>()
        let displays = try document.displays.map { display -> DisplayConfigurationV4Display in
            guard let id = uuid(display.id), displayIDs.insert(id.lowercased()).inserted,
                  let name = clean(display.name, limit: displayNameLimit), let selector = clean(display.selector, limit: textLimit),
                  display.localInput == nil || display.localInput == 0 || validInput(display.localInput) != nil else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            // Older documents could persist 0 even though it is not a valid DDC input source.
            // Preserve the document, but load that sentinel as an absent mapping so it can never be written.
            let localInput = display.localInput == 0 ? nil : display.localInput
            return DisplayConfigurationV4Display(id: id, name: name, selector: selector, localInput: localInput,
                readEnabled: display.readEnabled, brightnessEnabled: display.brightnessEnabled,
                contrastEnabled: display.contrastEnabled, volumeEnabled: display.volumeEnabled,
                brightnessShowInTray: display.brightnessShowInTray,
                contrastShowInTray: display.contrastShowInTray,
                volumeShowInTray: display.volumeShowInTray)
        }
        var profileIDs = Set<String>()
        var profileNames = Set<String>()
        let profiles = try document.collaborationProfiles.map { profile -> CollaborationProfile in
            guard let name = clean(profile.name, limit: profileNameLimit) else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            let foldedName = name.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard let id = uuid(profile.id), profileIDs.insert(id.lowercased()).inserted,
                  profileNames.insert(foldedName).inserted,
                  profile.peerHost.isEmpty || clean(profile.peerHost, limit: 253) != nil,
                  (1...65535).contains(profile.peerPort), validPairing(profile.pairingCode, allowEmpty: true),
                  profile.peerEndpointID == nil || uuid(profile.peerEndpointID) != nil,
                  profile.peerProtocolVersion == nil || profile.peerProtocolVersion == 2 else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            var mappingIDs = Set<String>()
            let mappings = try profile.displayInputs.compactMap { item -> DisplayInputMapping? in
                guard let displayID = uuid(item.displayID) else {
                    throw DisplayConfigurationStoreError.invalidConfiguration
                }
                guard item.peerInput != 0 else { return nil }
                guard mappingIDs.insert(displayID.lowercased()).inserted,
                      InputSourceValuePolicy.isSafe(item.peerInput) else {
                    throw DisplayConfigurationStoreError.invalidConfiguration
                }
                let input = item.peerInput
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
        return DisplayConfigurationStoreV5Document(schemaVersion: currentSchemaVersion, localEndpointID: endpoint,
            localDeviceName: deviceName, listenPort: document.listenPort,
            linkAllDisplays: document.linkAllDisplays,
            displays: displays, collaborationProfiles: profiles,
            usbSwitch: try validateUSBSwitch(document.usbSwitch))
    }

    private static func validateUSBSwitch(_ value: USBSwitchConfiguration) throws -> USBSwitchConfiguration {
        let trigger: CollaborationTriggerDevice?
        if let item = value.triggerDevice {
            guard item.kind.caseInsensitiveCompare("usb") == .orderedSame,
                  let reference = clean(item.localReference, limit: textLimit) else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            let displayName = item.displayName.isEmpty ? "" : (clean(item.displayName, limit: displayNameLimit) ?? "")
            if !item.displayName.isEmpty && displayName.isEmpty { throw DisplayConfigurationStoreError.invalidConfiguration }
            trigger = CollaborationTriggerDevice(kind: "usb", localReference: reference, displayName: displayName)
        } else {
            trigger = nil
        }
        var mappingIDs = Set<String>()
        let mappings = try value.displayInputs.compactMap { item -> USBDisplayInputMapping? in
            guard let displayID = uuid(item.displayID) else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            guard item.targetInput != 0 else { return nil }
            guard mappingIDs.insert(displayID.lowercased()).inserted,
                  InputSourceValuePolicy.isSafe(item.targetInput) else {
                throw DisplayConfigurationStoreError.invalidConfiguration
            }
            let input = item.targetInput
            return USBDisplayInputMapping(displayID: displayID, targetInput: input)
        }
        let profileID = value.collaborationProfileID.flatMap(uuid)
        if value.collaborationProfileID != nil, profileID == nil {
            throw DisplayConfigurationStoreError.invalidConfiguration
        }
        if value.collaborationWakeEnabled, profileID == nil {
            throw DisplayConfigurationStoreError.invalidConfiguration
        }
        let enabled = value.enabled && trigger != nil && !mappings.isEmpty
        return USBSwitchConfiguration(enabled: enabled, triggerDevice: trigger,
            collaborationWakeEnabled: value.collaborationWakeEnabled,
            collaborationProfileID: profileID, displayInputs: mappings)
    }

    private static func convert(_ configurations: [DisplayConfiguration],
                                preserving existing: [DisplayConfigurationV4Display]) throws -> [DisplayConfigurationV4Display] {
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id.lowercased(), $0) })
        let bySelector = Dictionary(grouping: existing, by: { $0.selector.lowercased() })
        var used = Set<String>()
        return try configurations.enumerated().map { offset, item in
            guard let name = clean(item.name, limit: displayNameLimit), let selector = clean(item.selector, limit: textLimit),
                  item.localInput == nil || validInput(item.localInput) != nil else { throw DisplayConfigurationStoreError.invalidConfiguration }
            let prior = item.id.flatMap(uuid).flatMap { byID[$0.lowercased()] }
                ?? (bySelector[selector.lowercased()]?.count == 1 ? bySelector[selector.lowercased()]?.first : nil)
                ?? (existing.indices.contains(offset) && Int(item.selector) != nil ? existing[offset] : nil)
            let id = item.id.flatMap(uuid) ?? prior?.id ?? UUID().uuidString
            guard used.insert(id.lowercased()).inserted else { throw DisplayConfigurationStoreError.invalidConfiguration }
            return DisplayConfigurationV4Display(id: id, name: name, selector: selector, localInput: item.localInput,
                readEnabled: item.readEnabled, brightnessEnabled: prior?.brightnessEnabled ?? false,
                contrastEnabled: prior?.contrastEnabled ?? false, volumeEnabled: prior?.volumeEnabled ?? false,
                brightnessShowInTray: prior?.brightnessShowInTray ?? false,
                contrastShowInTray: prior?.contrastShowInTray ?? false,
                volumeShowInTray: prior?.volumeShowInTray ?? false)
        }
    }

    private static func legacyView(_ document: DisplayConfigurationStoreV5Document) -> [DisplayConfiguration] {
        return document.displays.enumerated().map { index, display in
            DisplayConfiguration(id: display.id, index: index + 1, name: display.name, selector: display.selector,
                localInput: display.localInput, targetInput: nil, readEnabled: display.readEnabled)
        }
    }

    private static func hasLegacyDisplayKeys(_ storage: DisplayConfigurationStorage) -> Bool {
        (1...2).contains { index in
            ["Name", "Selector", "MacInput", "WindowsInput", "ReadEnabled"].contains {
                storage.object(forKey: "Display.\(index).\($0)") != nil
            }
        }
    }

    private static func firstLegacyDocument(in storage: DisplayConfigurationStorage) -> Data? {
        [legacyV3StorageKey, legacyDocumentStorageKey, legacyArrayStorageKey]
            .compactMap { storage.data(forKey: $0) }
            .first
    }

    private static func validInput(_ value: Int?) -> Int? {
        guard let value, InputSourceValuePolicy.isSafe(value) else { return nil }
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
