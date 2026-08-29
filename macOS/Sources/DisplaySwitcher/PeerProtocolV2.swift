import CommonCrypto
import Foundation
import Security

enum V2MessageType: String, Codable, CaseIterable {
    case statusProbe = "status_probe"
    case statusResponse = "status_response"
    case wakeDisplay = "wake_display"
    case handoverRequest = "handover_request"
    case targetReady = "target_ready"
    case committed
    case cancelled
}

enum V2HandoverIntent: String, Codable {
    case manual
}

enum V2CancellationReason: String, Codable {
    case configurationChanged = "configuration_changed"
    case userCancelled = "user_cancelled"
    case peerUnavailable = "peer_unavailable"
}

enum V2SourcePlatform: String, Codable {
    case macos
    case windows
}

struct V2Message: Codable, Equatable {
    let version: Int
    let type: V2MessageType
    let eventID: String
    let sourceEndpointID: String
    let targetEndpointID: String?
    let sourcePlatform: V2SourcePlatform
    let timestamp: Int64
    let nonce: String
    var authTag: String
    let intent: V2HandoverIntent?
    let wakeSucceeded: Bool?
    let switchSucceeded: Bool?
    let reason: V2CancellationReason?

    init(
        type: V2MessageType,
        eventID: String,
        sourceEndpointID: String,
        targetEndpointID: String?,
        sourcePlatform: V2SourcePlatform,
        timestamp: Int64,
        nonce: String,
        authTag: String = "",
        intent: V2HandoverIntent? = nil,
        wakeSucceeded: Bool? = nil,
        switchSucceeded: Bool? = nil,
        reason: V2CancellationReason? = nil
    ) {
        version = 2
        self.type = type
        self.eventID = eventID.lowercased()
        self.sourceEndpointID = sourceEndpointID.lowercased()
        self.targetEndpointID = targetEndpointID?.lowercased()
        self.sourcePlatform = sourcePlatform
        self.timestamp = timestamp
        self.nonce = nonce
        self.authTag = authTag
        self.intent = intent
        self.wakeSucceeded = wakeSucceeded
        self.switchSucceeded = switchSucceeded
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case version, type, eventID, sourceEndpointID, targetEndpointID, sourcePlatform
        case timestamp, nonce, authTag, intent, wakeSucceeded, switchSucceeded, reason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(sourceEndpointID, forKey: .sourceEndpointID)
        if let targetEndpointID {
            try container.encode(targetEndpointID, forKey: .targetEndpointID)
        } else {
            try container.encodeNil(forKey: .targetEndpointID)
        }
        try container.encode(sourcePlatform, forKey: .sourcePlatform)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(authTag, forKey: .authTag)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(wakeSucceeded, forKey: .wakeSucceeded)
        try container.encodeIfPresent(switchSucceeded, forKey: .switchSucceeded)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    func canonicalAuthenticationData() -> Data {
        let lines = [
            "DisplaySwitch/v2",
            "version:2",
            "type:\(type.rawValue)",
            "eventID:\(eventID.lowercased())",
            "sourceEndpointID:\(sourceEndpointID.lowercased())",
            "targetEndpointID:\(targetEndpointID?.lowercased() ?? "null")",
            "sourcePlatform:\(sourcePlatform.rawValue)",
            "timestamp:\(timestamp)",
            "nonce:\(nonce)",
            "intent:\(intent?.rawValue ?? "null")",
            "wakeSucceeded:\(Self.canonicalBoolean(wakeSucceeded))",
            "switchSucceeded:\(Self.canonicalBoolean(switchSucceeded))",
            "reason:\(reason?.rawValue ?? "null")"
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func canonicalBoolean(_ value: Bool?) -> String {
        guard let value else { return "null" }
        return value ? "true" : "false"
    }
}

enum V2CryptoError: Error, Equatable {
    case invalidPairingCode
    case invalidEndpointID
    case keyDerivationFailed(Int32)
    case randomGenerationFailed(Int32)
}

enum V2Crypto {
    static let iterations: UInt32 = 200_000
    static let keyLength = 32

    static func normalizedPairingCodeData(_ pairingCode: String) throws -> Data {
        let normalized = pairingCode.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(normalized.utf8)
        guard (8...128).contains(data.count) else { throw V2CryptoError.invalidPairingCode }
        return data
    }

    static func deriveKey(pairingCode: String, sourceEndpointID: String) throws -> Data {
        try deriveKey(inputSecret: normalizedPairingCodeData(pairingCode), sourceEndpointID: sourceEndpointID)
    }

    static func deriveKey(inputSecret: Data, sourceEndpointID: String) throws -> Data {
        guard let endpoint = normalizedUUID(sourceEndpointID) else { throw V2CryptoError.invalidEndpointID }
        let salt = Data("DisplaySwitch-v2-auth|\(endpoint)".utf8)
        var output = Data(count: keyLength)
        let result: Int32 = output.withUnsafeMutableBytes { outputBytes in
            inputSecret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretBytes.bindMemory(to: Int8.self).baseAddress,
                        inputSecret.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw V2CryptoError.keyDerivationFailed(result) }
        return output
    }

    static func authenticationTag(for message: V2Message, key: Data) -> String {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        let input = message.canonicalAuthenticationData()
        digest.withUnsafeMutableBytes { digestBytes in
            key.withUnsafeBytes { keyBytes in
                input.withUnsafeBytes { inputBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress,
                        key.count,
                        inputBytes.baseAddress,
                        input.count,
                        digestBytes.baseAddress
                    )
                }
            }
        }
        return base64URLEncode(digest)
    }

    static func authenticate(_ message: V2Message, key: Data) -> Bool {
        guard let supplied = base64URLDecode(message.authTag), supplied.count == keyLength,
              let expected = base64URLDecode(authenticationTag(for: message, key: key)) else { return false }
        return constantTimeEqual(supplied, expected)
    }

    static func makeNonce() throws -> String {
        var bytes = Data(count: 16)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw V2CryptoError.randomGenerationFailed(result) }
        return base64URLEncode(bytes)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        guard value.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
                .contains($0)
        }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    static func normalizedUUID(_ value: String) -> String? {
        guard value.count == 36, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

enum V2MessageValidationReason: String, Equatable {
    case accepted
    case parseError = "parse_error"
    case missingField = "missing_field"
    case invalidFieldType = "invalid_field_type"
    case unsupportedVersion = "unsupported_version"
    case unknownType = "unknown_type"
    case invalidEventID = "invalid_event_id"
    case unknownSource = "unknown_source"
    case wrongTarget = "wrong_target"
    case timestampOutOfWindow = "timestamp_out_of_window"
    case invalidNonce = "invalid_nonce"
    case invalidAuthTag = "invalid_auth_tag"
    case authenticationFailed = "authentication_failed"
    case invalidTypeFields = "invalid_type_fields"
}

struct V2MessageValidationContext {
    let now: Int64
    let localEndpointID: String
    let knownSourceEndpointID: String
    let authenticationKey: Data
}

struct V2MessageValidationResult {
    let message: V2Message?
    let reason: V2MessageValidationReason
    var accepted: Bool { reason == .accepted }
    var refreshPeer: Bool { accepted }
    var replyTypes: [V2MessageType] {
        message?.type == .statusProbe && accepted ? [.statusResponse] : []
    }
}

enum V2MessageValidator {
    private static let requiredFields: Set<String> = [
        "version", "type", "eventID", "sourceEndpointID", "targetEndpointID",
        "sourcePlatform", "timestamp", "nonce", "authTag"
    ]
    private static let specificFields: Set<String> = [
        "intent", "wakeSucceeded", "switchSucceeded", "reason"
    ]

    static func validate(data: Data, context: V2MessageValidationContext) -> V2MessageValidationResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return result(.parseError)
        }
        guard requiredFields.isSubset(of: Set(dictionary.keys)) else { return result(.missingField) }
        guard let version = integer(dictionary["version"]),
              let typeText = dictionary["type"] as? String,
              let eventID = dictionary["eventID"] as? String,
              let sourceEndpointID = dictionary["sourceEndpointID"] as? String,
              dictionary["targetEndpointID"] is NSNull || dictionary["targetEndpointID"] is String,
              let platformText = dictionary["sourcePlatform"] as? String,
              let timestamp = integer(dictionary["timestamp"]),
              let nonce = dictionary["nonce"] as? String,
              let authTag = dictionary["authTag"] as? String else {
            return result(.invalidFieldType)
        }
        guard version == 2 else { return result(.unsupportedVersion) }
        guard let type = V2MessageType(rawValue: typeText) else { return result(.unknownType) }
        guard let normalizedEventID = V2Crypto.normalizedUUID(eventID) else { return result(.invalidEventID) }
        guard let normalizedSource = V2Crypto.normalizedUUID(sourceEndpointID) else { return result(.unknownSource) }
        let targetText = dictionary["targetEndpointID"] as? String
        let normalizedTarget: String?
        if let targetText {
            guard let target = V2Crypto.normalizedUUID(targetText) else { return result(.wrongTarget) }
            normalizedTarget = target
        } else {
            normalizedTarget = nil
        }
        guard normalizedSource == V2Crypto.normalizedUUID(context.knownSourceEndpointID) else {
            return result(.unknownSource)
        }
        guard let localEndpoint = V2Crypto.normalizedUUID(context.localEndpointID) else {
            return result(.wrongTarget)
        }
        if type == .statusProbe {
            guard normalizedTarget == nil || normalizedTarget == localEndpoint else { return result(.wrongTarget) }
        } else {
            guard normalizedTarget == localEndpoint else { return result(.wrongTarget) }
        }
        guard timestamp >= 0, abs(timestamp - context.now) <= 10 else { return result(.timestampOutOfWindow) }
        guard nonce.count == 22, V2Crypto.base64URLDecode(nonce)?.count == 16 else { return result(.invalidNonce) }
        guard authTag.count == 43, V2Crypto.base64URLDecode(authTag)?.count == 32 else { return result(.invalidAuthTag) }
        guard let platform = V2SourcePlatform(rawValue: platformText),
              let fields = decodeSpecificFields(type: type, dictionary: dictionary) else {
            return result(.invalidTypeFields)
        }
        let message = V2Message(
            type: type,
            eventID: normalizedEventID,
            sourceEndpointID: normalizedSource,
            targetEndpointID: normalizedTarget,
            sourcePlatform: platform,
            timestamp: timestamp,
            nonce: nonce,
            authTag: authTag,
            intent: fields.intent,
            wakeSucceeded: fields.wakeSucceeded,
            switchSucceeded: fields.switchSucceeded,
            reason: fields.reason
        )
        guard V2Crypto.authenticate(message, key: context.authenticationKey) else {
            return V2MessageValidationResult(message: message, reason: .authenticationFailed)
        }
        return V2MessageValidationResult(message: message, reason: .accepted)
    }

    private struct SpecificFields {
        let intent: V2HandoverIntent?
        let wakeSucceeded: Bool?
        let switchSucceeded: Bool?
        let reason: V2CancellationReason?
    }

    private static func decodeSpecificFields(type: V2MessageType, dictionary: [String: Any]) -> SpecificFields? {
        let present = specificFields.intersection(dictionary.keys)
        switch type {
        case .statusProbe, .statusResponse, .wakeDisplay:
            guard present.isEmpty else { return nil }
            return SpecificFields(intent: nil, wakeSucceeded: nil, switchSucceeded: nil, reason: nil)
        case .handoverRequest:
            guard present == ["intent"], let raw = dictionary["intent"] as? String,
                  let value = V2HandoverIntent(rawValue: raw) else { return nil }
            return SpecificFields(intent: value, wakeSucceeded: nil, switchSucceeded: nil, reason: nil)
        case .targetReady:
            guard present == ["wakeSucceeded"], let value = boolean(dictionary["wakeSucceeded"]) else { return nil }
            return SpecificFields(intent: nil, wakeSucceeded: value, switchSucceeded: nil, reason: nil)
        case .committed:
            guard present == ["switchSucceeded"], let value = boolean(dictionary["switchSucceeded"]) else { return nil }
            return SpecificFields(intent: nil, wakeSucceeded: nil, switchSucceeded: value, reason: nil)
        case .cancelled:
            guard present == ["reason"], let raw = dictionary["reason"] as? String,
                  let value = V2CancellationReason(rawValue: raw) else { return nil }
            return SpecificFields(intent: nil, wakeSucceeded: nil, switchSucceeded: nil, reason: value)
        }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int64.min), double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func result(_ reason: V2MessageValidationReason) -> V2MessageValidationResult {
        V2MessageValidationResult(message: nil, reason: reason)
    }
}

enum V2ReplayDisposition: Equatable {
    case new
    case duplicate
    case nonceReuse
}

struct V2NonceReplayCache {
    private struct Entry {
        let fingerprint: Data
        let seenAtMs: Int64
    }
    private var entries: [String: Entry] = [:]
    private let retentionMs: Int64

    init(retentionMs: Int64 = 20_000) {
        self.retentionMs = max(20_000, retentionMs)
    }

    mutating func classify(_ message: V2Message, nowMs: Int64) -> V2ReplayDisposition {
        entries = entries.filter { nowMs - $0.value.seenAtMs <= retentionMs }
        let key = "\(message.sourceEndpointID.lowercased()):\(message.nonce)"
        var fingerprint = message.canonicalAuthenticationData()
        fingerprint.append(Data(message.authTag.utf8))
        if let existing = entries[key] {
            return V2Crypto.constantTimeEqual(existing.fingerprint, fingerprint) ? .duplicate : .nonceReuse
        }
        entries[key] = Entry(fingerprint: fingerprint, seenAtMs: nowMs)
        if entries.count > 4_096, let oldest = entries.min(by: { $0.value.seenAtMs < $1.value.seenAtMs })?.key {
            entries.removeValue(forKey: oldest)
        }
        return .new
    }

    mutating func reset() { entries.removeAll(keepingCapacity: true) }
}

enum PeerProtocolVersionDispatcher {
    enum Version: Equatable { case v2, unsupported(Int) }

    static func version(in data: Data) -> Version? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let number = dictionary["version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        switch number.intValue {
        case 2: return .v2
        default: return .unsupported(number.intValue)
        }
    }
}

enum PeerCapabilityInspectionResult: Equatable {
    case v2(endpointID: String)
    case authenticationFailed
    case noResponse
}

enum V2PeerCapabilityInspectionResponse: Equatable {
    case accepted(endpointID: String)
    case authenticationFailed
    case rejected
}

enum V2PeerCapabilityInspectionRejectionReason: Equatable {
    case invalidExpectedEventID
    case missingEventID
    case eventIDMismatch
    case missingSourceEndpoint
    case sourceEndpointMismatch
    case keyDerivationFailed
    case validation(V2MessageValidationReason)
    case wrongMessageType
    case wrongTarget

    var diagnosticCode: String {
        switch self {
        case .invalidExpectedEventID: return "invalid-expected-event-id"
        case .missingEventID: return "missing-event-id"
        case .eventIDMismatch: return "event-id-mismatch"
        case .missingSourceEndpoint: return "missing-source-endpoint"
        case .sourceEndpointMismatch: return "source-endpoint-mismatch"
        case .keyDerivationFailed: return "key-derivation-failed"
        case .validation(let reason): return "validation-\(reason.rawValue.replacingOccurrences(of: "_", with: "-"))"
        case .wrongMessageType: return "wrong-message-type"
        case .wrongTarget: return "wrong-target-endpoint"
        }
    }
}

enum V2PeerCapabilityInspectionDetailedResponse: Equatable {
    case accepted(endpointID: String)
    case authenticationFailed
    case rejected(V2PeerCapabilityInspectionRejectionReason)
}

enum V2PeerCapabilityInspection {
    static func statusProbe(
        eventID: String,
        localEndpointID: String,
        profile: CollaborationProfile,
        timestamp: Int64,
        nonce: String
    ) throws -> V2Message {
        let targetEndpointID: String?
        if profile.peerProtocolVersion == 2 {
            targetEndpointID = profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID)
        } else {
            targetEndpointID = nil
        }
        let key = try V2Crypto.deriveKey(
            pairingCode: profile.pairingCode,
            sourceEndpointID: localEndpointID
        )
        var message = V2Message(
            type: .statusProbe,
            eventID: eventID,
            sourceEndpointID: localEndpointID,
            targetEndpointID: targetEndpointID,
            sourcePlatform: .macos,
            timestamp: timestamp,
            nonce: nonce
        )
        message.authTag = V2Crypto.authenticationTag(for: message, key: key)
        return message
    }

    static func validateResponse(
        data: Data,
        profile: CollaborationProfile,
        eventID: String,
        localEndpointID: String,
        now: Int64
    ) -> V2PeerCapabilityInspectionResponse {
        switch validateResponseDetailed(
            data: data,
            profile: profile,
            eventID: eventID,
            localEndpointID: localEndpointID,
            now: now
        ) {
        case .accepted(let endpointID): return .accepted(endpointID: endpointID)
        case .authenticationFailed: return .authenticationFailed
        case .rejected: return .rejected
        }
    }

    static func validateResponseDetailed(
        data: Data,
        profile: CollaborationProfile,
        eventID: String,
        localEndpointID: String,
        now: Int64
    ) -> V2PeerCapabilityInspectionDetailedResponse {
        guard let expectedEventID = V2Crypto.normalizedUUID(eventID) else {
            return .rejected(.invalidExpectedEventID)
        }
        guard let receivedEventID = V2MessageEnvelope.eventID(in: data) else {
            return .rejected(.missingEventID)
        }
        guard receivedEventID == expectedEventID else {
            return .rejected(.eventIDMismatch)
        }
        guard let sourceEndpointID = V2MessageEnvelope.sourceEndpointID(in: data) else {
            return .rejected(.missingSourceEndpoint)
        }

        if profile.peerProtocolVersion == 2,
           let expectedPeerEndpointID = profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID),
           sourceEndpointID != expectedPeerEndpointID {
            return .rejected(.sourceEndpointMismatch)
        }

        guard let key = try? V2Crypto.deriveKey(
            pairingCode: profile.pairingCode,
            sourceEndpointID: sourceEndpointID
        ) else { return .rejected(.keyDerivationFailed) }
        let validation = V2MessageValidator.validate(
            data: data,
            context: V2MessageValidationContext(
                now: now,
                localEndpointID: localEndpointID,
                knownSourceEndpointID: sourceEndpointID,
                authenticationKey: key
            )
        )
        if validation.reason == .authenticationFailed { return .authenticationFailed }
        guard validation.accepted, let message = validation.message else {
            return .rejected(.validation(validation.reason))
        }
        guard message.type == .statusResponse else { return .rejected(.wrongMessageType) }
        guard message.targetEndpointID == V2Crypto.normalizedUUID(localEndpointID) else {
            return .rejected(.wrongTarget)
        }
        return .accepted(endpointID: sourceEndpointID)
    }
}

struct PeerInspectionDiagnosticContext: Equatable {
    let diagnosticID: String
    let eventID: String
    let targetHostToken: String
    let targetPort: Int
    let startedAtMs: Int64
}

struct PeerInspectionEnvelopeSummary: Equatable {
    let version: Int?
    let type: String?
    let eventID: String?
}

enum PeerInspectionEnvelopeProjection {
    static func summary(_ data: Data) -> PeerInspectionEnvelopeSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return PeerInspectionEnvelopeSummary(version: nil, type: nil, eventID: nil)
        }
        let version: Int?
        if let number = dictionary["version"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           !CFNumberIsFloatType(number) {
            version = number.intValue
        } else {
            version = nil
        }
        return PeerInspectionEnvelopeSummary(
            version: version,
            type: dictionary["type"] as? String,
            eventID: (dictionary["eventID"] as? String).flatMap(V2Crypto.normalizedUUID)
        )
    }
}

enum PeerInspectionEventDisposition: Equatable {
    case active(inspectionID: String)
    case late(PeerInspectionDiagnosticContext)
    case unrelated
}

struct PeerInspectionEventTracker {
    private var activeInspectionIDs: [String: String] = [:]
    private var completedContexts: [String: PeerInspectionDiagnosticContext] = [:]
    private let maximumCompletedCount: Int

    init(maximumCompletedCount: Int = 128) {
        self.maximumCompletedCount = max(1, maximumCompletedCount)
    }

    mutating func register(eventID: String, inspectionID: String) {
        activeInspectionIDs[eventID.lowercased()] = inspectionID
    }

    mutating func complete(eventID: String, context: PeerInspectionDiagnosticContext) {
        let normalized = eventID.lowercased()
        activeInspectionIDs.removeValue(forKey: normalized)
        if completedContexts.count >= maximumCompletedCount {
            completedContexts.removeAll(keepingCapacity: true)
        }
        completedContexts[normalized] = context
    }

    func disposition(for eventID: String) -> PeerInspectionEventDisposition {
        let normalized = eventID.lowercased()
        if let inspectionID = activeInspectionIDs[normalized] {
            return .active(inspectionID: inspectionID)
        }
        if let context = completedContexts[normalized] { return .late(context) }
        return .unrelated
    }
}

enum PeerInspectionDatagramSourceValidator {
    static func rejectionReason(sourcePort: Int, expectedPort: Int) -> String? {
        sourcePort == expectedPort ? nil : "source-port-mismatch"
    }
}

enum PeerInspectionDiagnosticEvent: Equatable {
    case listener(result: PeerTransportOperationResult, requestedPort: Int, actualPort: Int?)
    case sendStarted(listeningPort: Int?)
    case sendFinished(PeerTransportOperationResult)
    case datagramReceived(
        sourceHost: String, sourcePort: Int, version: Int?, type: String?, eventIDMatches: Bool
    )
    case responseAccepted
    case responseRejected(String)
    case timeout(receivedDatagrams: Int)
    case completed(String)
}

final class PeerInspectionDiagnosticStore {
    static let shared = PeerInspectionDiagnosticStore()

    private let lock = NSLock()
    private let maximumLineCount: Int
    private let nowMs: () -> Int64
    private var nextInspectionIndex = 1
    private var nextHostIndex = 1
    private var hostTokens: [String: String] = [:]
    private var receivedCountByInspectionID: [String: Int] = [:]
    private var lines: [String] = []

    init(
        maximumLineCount: Int = 1_000,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.maximumLineCount = max(100, maximumLineCount)
        self.nowMs = nowMs
    }

    func begin(eventID: String, targetHost: String, targetPort: Int) -> PeerInspectionDiagnosticContext {
        lock.lock()
        let diagnosticID = "I\(nextInspectionIndex)"
        nextInspectionIndex += 1
        let targetToken = hostTokenLocked(for: targetHost)
        let context = PeerInspectionDiagnosticContext(
            diagnosticID: diagnosticID,
            eventID: eventID.lowercased(),
            targetHostToken: targetToken,
            targetPort: targetPort,
            startedAtMs: nowMs()
        )
        receivedCountByInspectionID[diagnosticID] = 0
        appendLocked(
            "inspection=\(diagnosticID) elapsed-ms=0 stage=begin target=\(targetToken) target-port=\(targetPort) timeout-ms=1000"
        )
        lock.unlock()
        return context
    }

    func record(_ event: PeerInspectionDiagnosticEvent, context: PeerInspectionDiagnosticContext) {
        lock.lock()
        let elapsed = max(0, nowMs() - context.startedAtMs)
        let prefix = "inspection=\(context.diagnosticID) elapsed-ms=\(elapsed)"
        let detail: String
        switch event {
        case let .listener(result, requestedPort, actualPort):
            detail = "stage=listener requested-port=\(requestedPort) actual-port=\(actualPort.map(String.init) ?? "none") result=\(result.safeDescription)"
        case let .sendStarted(listeningPort):
            detail = "stage=send-started target=\(context.targetHostToken) target-port=\(context.targetPort) listening-port=\(listeningPort.map(String.init) ?? "none")"
        case let .sendFinished(result):
            detail = "stage=send-finished result=\(result.safeDescription)"
        case let .datagramReceived(sourceHost, sourcePort, version, type, eventIDMatches):
            receivedCountByInspectionID[context.diagnosticID, default: 0] += 1
            detail = "stage=datagram-received source=\(hostTokenLocked(for: sourceHost)) source-port=\(sourcePort) version=\(version.map(String.init) ?? "invalid") type=\(Self.safeType(type)) event-match=\(eventIDMatches) source-port-match=\(sourcePort == context.targetPort)"
        case .responseAccepted:
            detail = "stage=response-validation result=accepted"
        case let .responseRejected(reason):
            detail = "stage=response-validation result=rejected reason=\(Self.safeReason(reason))"
        case let .timeout(receivedDatagrams):
            detail = "stage=timeout timeout-ms=1000 received-datagrams=\(receivedDatagrams)"
        case let .completed(result):
            detail = "stage=completed result=\(Self.safeReason(result))"
        }
        appendLocked(prefix + " " + detail)
        lock.unlock()
    }

    func receivedDatagramCount(for context: PeerInspectionDiagnosticContext) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCountByInspectionID[context.diagnosticID, default: 0]
    }

    func exportText() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return ([
            "DisplaySwitcher collaboration inspection diagnostic",
            "Session-only anonymized data; no IP, pairing code, auth tag, endpoint ID, or hardware identifier."
        ] + snapshot).joined(separator: "\n")
    }

    private func hostTokenLocked(for host: String) -> String {
        let normalized = host.lowercased()
        if let existing = hostTokens[normalized] { return existing }
        let token = "H\(nextHostIndex)"
        nextHostIndex += 1
        hostTokens[normalized] = token
        return token
    }

    private func appendLocked(_ line: String) {
        lines.append(line)
        if lines.count > maximumLineCount { lines.removeFirst(lines.count - maximumLineCount) }
    }

    private static func safeType(_ value: String?) -> String {
        guard let value, V2MessageType(rawValue: value) != nil else { return value == nil ? "invalid" : "unknown" }
        return value
    }

    private static func safeReason(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=")
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
    }
}

private extension PeerTransportOperationResult {
    var safeDescription: String {
        switch self {
        case .success: return "success"
        case .failure(let category): return "failure-\(category.rawValue)"
        }
    }
}

struct V2ProfileRoute: Equatable {
    let profileID: String
    let endpointID: String
    let host: String
    let port: Int
    let pairingCode: String
}

struct V2EndpointRoutingTable {
    let routesByEndpointID: [String: V2ProfileRoute]
    let rejectedProfileIDs: Set<String>

    static func build(from document: DisplayConfigurationStoreV5Document) -> V2EndpointRoutingTable {
        let knownDisplays = Set(document.displays.map { $0.id.lowercased() })
        var candidates: [V2ProfileRoute] = []
        var rejected = Set<String>()

        for profile in document.collaborationProfiles where profile.coordinationEnabled {
            guard profile.peerProtocolVersion == 2,
                  DisplayConfigurationStore.inspectProfile(
                    profile,
                    displays: document.displays,
                    ddcAvailableDisplayIDs: knownDisplays
                  ).issues.isEmpty,
                  let endpointID = profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID),
                  (try? V2Crypto.normalizedPairingCodeData(profile.pairingCode)) != nil else {
                if profile.peerProtocolVersion == 2 { rejected.insert(profile.id) }
                continue
            }
            candidates.append(V2ProfileRoute(
                profileID: profile.id,
                endpointID: endpointID,
                host: profile.peerHost,
                port: profile.peerPort,
                pairingCode: profile.pairingCode
            ))
        }

        let duplicateEndpoints = Set(
            Dictionary(grouping: candidates, by: \.endpointID)
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        var routes: [String: V2ProfileRoute] = [:]
        for route in candidates {
            if duplicateEndpoints.contains(route.endpointID) {
                rejected.insert(route.profileID)
            } else {
                routes[route.endpointID] = route
            }
        }
        return V2EndpointRoutingTable(routesByEndpointID: routes, rejectedProfileIDs: rejected)
    }

    func route(for endpointID: String) -> V2ProfileRoute? {
        guard let normalized = V2Crypto.normalizedUUID(endpointID) else { return nil }
        return routesByEndpointID[normalized]
    }
}

struct V2UnboundStatusProbeResolution {
    let profileID: String
    let request: V2Message
    let responseData: Data
}

enum V2UnboundStatusProbeResolver {
    static func eligibleProfiles(in document: DisplayConfigurationStoreV5Document) -> [CollaborationProfile] {
        let knownDisplays = Set(document.displays.map { $0.id.lowercased() })
        return document.collaborationProfiles.filter { profile in
            profile.peerEndpointID == nil
                && DisplayConfigurationStore.inspectProfile(
                    profile,
                    displays: document.displays,
                    ddcAvailableDisplayIDs: knownDisplays
                ).issues.isEmpty
                && (try? V2Crypto.normalizedPairingCodeData(profile.pairingCode)) != nil
        }
    }

    static func resolve(
        data: Data,
        document: DisplayConfigurationStoreV5Document,
        routingTable: V2EndpointRoutingTable,
        now: Int64,
        responseNonce: String
    ) -> V2UnboundStatusProbeResolution? {
        guard let sourceEndpointID = V2MessageEnvelope.sourceEndpointID(in: data),
              routingTable.route(for: sourceEndpointID) == nil,
              V2Crypto.base64URLDecode(responseNonce)?.count == 16 else { return nil }

        // A configured identity which is absent from the usable routing table is a conflict,
        // not an invitation to replace or bootstrap that identity through another profile.
        let conflictsWithConfiguredEndpoint = document.collaborationProfiles.contains { profile in
            profile.peerEndpointID.flatMap(V2Crypto.normalizedUUID) == sourceEndpointID
        }
        guard !conflictsWithConfiguredEndpoint else { return nil }

        let candidates = eligibleProfiles(in: document)

        let matches: [(CollaborationProfile, V2Message)] = candidates.compactMap { profile in
            guard let key = try? V2Crypto.deriveKey(
                pairingCode: profile.pairingCode,
                sourceEndpointID: sourceEndpointID
            ) else { return nil }
            let validation = V2MessageValidator.validate(
                data: data,
                context: V2MessageValidationContext(
                    now: now,
                    localEndpointID: document.localEndpointID,
                    knownSourceEndpointID: sourceEndpointID,
                    authenticationKey: key
                )
            )
            guard validation.accepted, let message = validation.message,
                  message.type == .statusProbe else { return nil }
            return (profile, message)
        }
        guard matches.count == 1, let match = matches.first,
              let responseKey = try? V2Crypto.deriveKey(
                pairingCode: match.0.pairingCode,
                sourceEndpointID: document.localEndpointID
              ) else { return nil }

        var response = V2Message(
            type: .statusResponse,
            eventID: match.1.eventID,
            sourceEndpointID: document.localEndpointID,
            targetEndpointID: sourceEndpointID,
            sourcePlatform: .macos,
            timestamp: now,
            nonce: responseNonce
        )
        response.authTag = V2Crypto.authenticationTag(for: response, key: responseKey)
        guard let responseData = try? JSONEncoder().encode(response) else { return nil }
        return V2UnboundStatusProbeResolution(
            profileID: match.0.id,
            request: match.1,
            responseData: responseData
        )
    }
}

enum V2MessageEnvelope {
    static func sourceEndpointID(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["sourceEndpointID"] as? String else { return nil }
        return V2Crypto.normalizedUUID(source)
    }

    static func eventID(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventID = object["eventID"] as? String else { return nil }
        return V2Crypto.normalizedUUID(eventID)
    }
}
