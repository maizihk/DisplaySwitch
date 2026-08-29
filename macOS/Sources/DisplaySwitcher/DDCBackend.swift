import Foundation

enum DDCCommand: UInt8, CaseIterable, Hashable {
    case luminance = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62

    var m1ddcName: String {
        switch self {
        case .luminance: return "luminance"
        case .contrast: return "contrast"
        case .input: return "input"
        case .volume: return "volume"
        }
    }

    static let userControls: Set<DDCCommand> = [.luminance, .contrast, .volume]

    var userFacingName: String {
        switch self {
        case .luminance: return "亮度"
        case .contrast: return "对比度"
        case .input: return "输入源"
        case .volume: return "音量"
        }
    }
}

struct DDCReading: Equatable {
    let current: Int
    let maximum: Int
}

enum DDCBackendAvailability: Equatable {
    case available
    case unavailable(String)
}

struct DDCBackendCapabilities: Equatable {
    let canEnumerate: Bool
    let canReadVCP: Bool
    let canWriteVCP: Bool
}

struct DDCBackendDisplay: Equatable {
    let stableID: String
    let name: String
    let selector: String
}

struct DDCKnownDisplay: Equatable {
    let stableID: String
    let name: String
    let selector: String
}

enum NativeDDCTransportPath: String, Equatable, Hashable {
    case typeCDPAlt = "typec-dp-alt"
    case builtinHDMIConverter = "builtin-hdmi-converter"
    case unknownExternal = "unknown-external"
    case unmatched = "unmatched"
}

enum NativeTransportPathClassifier {
    static func classify(epicProviderClass: String?, transportDescription: String?)
        -> NativeDDCTransportPath {
        let provider = epicProviderClass?.uppercased() ?? ""
        let transport = transportDescription?.uppercased() ?? ""
        if provider.contains("MCDP") || transport.contains("HDMI") {
            return .builtinHDMIConverter
        }
        if transport.contains("TYPEC") || transport.contains("USB-C")
            || transport.contains("DISPLAYPORT") || transport == "DP" {
            return .typeCDPAlt
        }
        return .unknownExternal
    }
}

enum NativeDDCOperationCategory: String, Equatable {
    case idle
    case serviceUnmatched = "service-unmatched"
    case readSucceeded = "read-succeeded"
    case readRequestWriteFailed = "read-request-write-failed"
    case readResponseTimeout = "read-response-timeout"
    case readResponseFailed = "read-response-failed"
    case readReplyRejected = "read-reply-rejected"
    case writeSucceeded = "write-succeeded"
    case writeTransportFailed = "write-transport-failed"
}

struct NativeDDCDiagnosticSnapshot: Equatable {
    let transportPath: NativeDDCTransportPath
    let serviceMatched: Bool
    let operationCategory: NativeDDCOperationCategory
    let rebuildCount: Int

    var userFacingDescription: String {
        "\(transportPath.rawValue) · service \(serviceMatched ? "matched" : "unmatched") · "
            + "\(operationCategory.rawValue) · rebuild \(rebuildCount)"
    }
}

enum DDCBackendError: Error, Equatable, LocalizedError {
    case unavailable(backend: String)
    case displayUnavailable(stableID: String)
    case readFailed(stableID: String, command: DDCCommand)
    case writeFailed(stableID: String, command: DDCCommand)
    case invalidReply(command: DDCCommand, issue: NativeDDCReplyIssue)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "没有可用的硬件 DDC 后端。"
        case .displayUnavailable:
            return "目标显示器在当前 DDC 后端中不可用。"
        case let .readFailed(_, command):
            return "读取\(command.userFacingName)失败。"
        case let .writeFailed(_, command):
            return "写入\(command.userFacingName)失败。"
        case let .invalidReply(command, issue):
            return "读取\(command.userFacingName)失败：\(issue.userFacingDescription)。"
        case .cancelled:
            return "DDC 操作已取消。"
        }
    }
}

enum NativeDDCReplyIssue: Error, Equatable {
    case requestWriteFailed
    case responseTimeout
    case responseReadFailed
    case wrongLength
    case badChecksum
    case wrongSource
    case wrongPayloadLength
    case wrongOpcode
    case monitorRejected
    case wrongCommand

    var userFacingDescription: String {
        switch self {
        case .requestWriteFailed: return "读取请求写入失败"
        case .responseTimeout: return "读取回复超时"
        case .responseReadFailed: return "读取回复 I2C 失败"
        case .wrongLength: return "回复长度无效"
        case .badChecksum: return "回复校验失败"
        case .wrongSource: return "回复来源无效"
        case .wrongPayloadLength: return "回复载荷长度无效"
        case .wrongOpcode: return "回复类型不匹配"
        case .monitorRejected: return "显示器拒绝该 VCP 请求"
        case .wrongCommand: return "回复的 VCP 项不匹配"
        }
    }
}

struct NativeDDCTransportParameters: Equatable {
    let writeDataAddress: UInt8
    let typeCDPReadDataAddress: UInt8
    let builtinHDMIReadDataAddress: UInt8
    let writeSleepMicroseconds: UInt32
    let typeCDPReadSleepMicroseconds: UInt32
    let builtinHDMIReadSleepMicroseconds: UInt32
    let retrySleepMicroseconds: UInt32
    let writeCycles: Int
    let writeAttempts: Int
    let typeCDPReadAttempts: Int
    let builtinHDMIReadAttempts: Int

    func readDataAddress(for path: NativeDDCTransportPath) -> UInt8 {
        path == .builtinHDMIConverter ? builtinHDMIReadDataAddress : typeCDPReadDataAddress
    }

    func readSleepMicroseconds(for path: NativeDDCTransportPath) -> UInt32 {
        path == .builtinHDMIConverter
            ? builtinHDMIReadSleepMicroseconds : typeCDPReadSleepMicroseconds
    }

    func readAttempts(for path: NativeDDCTransportPath) -> Int {
        path == .builtinHDMIConverter ? builtinHDMIReadAttempts : typeCDPReadAttempts
    }

    static let appleSiliconDDCCompatible = NativeDDCTransportParameters(
        writeDataAddress: 0x51,
        typeCDPReadDataAddress: 0x51,
        builtinHDMIReadDataAddress: 0x00,
        writeSleepMicroseconds: 10_000,
        typeCDPReadSleepMicroseconds: 50_000,
        builtinHDMIReadSleepMicroseconds: 50_000,
        retrySleepMicroseconds: 20_000,
        writeCycles: 2,
        writeAttempts: 5,
        typeCDPReadAttempts: 5,
        builtinHDMIReadAttempts: 5
    )
}

enum NativeDDCWriteCyclePolicy {
    static func perform(cycles: Int, write: () -> Bool) -> Bool {
        var anyCycleAccepted = false
        for _ in 0..<max(cycles, 1) {
            // Keep the bounded duplicate-write behavior, but never let a later
            // transport loss erase an earlier accepted DDC command. Input-source
            // writes can tear down the active Type-C path immediately.
            let accepted = write()
            anyCycleAccepted = anyCycleAccepted || accepted
        }
        return anyCycleAccepted
    }
}

enum NativeDDCReplyValidator {
    static func reading(from reply: [UInt8], command: DDCCommand) -> Result<DDCReading, NativeDDCReplyIssue> {
        guard reply.count == 11 else { return .failure(.wrongLength) }
        guard reply.dropLast().reduce(UInt8(0x50), ^) == reply.last else { return .failure(.badChecksum) }
        guard reply[0] == 0x6E else { return .failure(.wrongSource) }
        guard reply[1] & 0x7F == 8 else { return .failure(.wrongPayloadLength) }
        guard reply[2] == 0x02 else { return .failure(.wrongOpcode) }
        guard reply[3] == 0 else { return .failure(.monitorRejected) }
        guard reply[4] == command.rawValue else { return .failure(.wrongCommand) }
        return .success(DDCReading(
            current: Int(UInt16(reply[8]) << 8 | UInt16(reply[9])),
            maximum: Int(UInt16(reply[6]) << 8 | UInt16(reply[7]))
        ))
    }
}

struct NativeEDIDSearchKey: Equatable {
    let value: String
    let offset: Int
}

struct NativeDisplayIdentity: Equatable {
    let stableID: String
    let ioDisplayLocation: String
    let productName: String
    let serialNumber: Int64
    let edidSearchKeys: [NativeEDIDSearchKey]
}

struct NativeTransportCandidate: Equatable {
    let serviceLocation: Int
    let ioDisplayLocation: String
    let productName: String
    let serialNumber: Int64
    let edidUUID: String
    let transportPath: NativeDDCTransportPath

    init(serviceLocation: Int, ioDisplayLocation: String, productName: String,
         serialNumber: Int64, edidUUID: String,
         transportPath: NativeDDCTransportPath = .typeCDPAlt) {
        self.serviceLocation = serviceLocation
        self.ioDisplayLocation = ioDisplayLocation
        self.productName = productName
        self.serialNumber = serialNumber
        self.edidUUID = edidUUID
        self.transportPath = transportPath
    }
}

enum NativeDisplayMatcher {
    static func matches(
        identities: [NativeDisplayIdentity],
        candidates: [NativeTransportCandidate]
    ) -> [String: Int] {
        let scored = identities.flatMap { identity in
            candidates.compactMap { candidate -> (String, Int, Int)? in
                var score = 0
                if !identity.ioDisplayLocation.isEmpty,
                   identity.ioDisplayLocation == candidate.ioDisplayLocation { score += 10 }
                if !identity.productName.isEmpty,
                   identity.productName.caseInsensitiveCompare(candidate.productName) == .orderedSame { score += 1 }
                if identity.serialNumber != 0, identity.serialNumber == candidate.serialNumber { score += 4 }
                let candidateEDID = candidate.edidUUID.uppercased()
                score += identity.edidSearchKeys.filter { key in
                    !key.value.isEmpty && key.value != "0000" && key.offset >= 0
                        && candidateEDID.count >= key.offset + key.value.count
                        && String(candidateEDID.dropFirst(key.offset).prefix(key.value.count)) == key.value
                }.count
                // A product-name-only match is unsafe for identical models. Require either
                // location, serial, or multiple independent EDID/product characteristics.
                return score < 2 ? nil : (identity.stableID, candidate.serviceLocation, score)
            }
        }.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        var usedDisplays = Set<String>()
        var usedServices = Set<Int>()
        var result: [String: Int] = [:]
        for (displayID, serviceLocation, _) in scored {
            guard !usedDisplays.contains(displayID), !usedServices.contains(serviceLocation) else { continue }
            usedDisplays.insert(displayID)
            usedServices.insert(serviceLocation)
            result[displayID] = serviceLocation
        }
        return result
    }
}

enum DDCSingleRetry {
    static func perform(operation: () throws -> Void, recover: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            try recover()
            try operation()
        }
    }
}

final class DDCCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        if isCancelled { throw DDCBackendError.cancelled }
    }
}

protocol DDCBackend: AnyObject {
    var identifier: String { get }
    var availability: DDCBackendAvailability { get }
    var capabilities: DDCBackendCapabilities { get }
    func updateKnownDisplays(_ displays: [DDCKnownDisplay])
    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay]
    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading
    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws
    func cancelAll()
    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot?
}

extension DDCBackend {
    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {}
    func cancelAll() {}
    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? { nil }
}

final class DDCBackendRouter {
    private let backends: [DDCBackend]

    init(backends: [DDCBackend]) {
        self.backends = backends
    }

    func setControlChannel(_ channel: DDCControlChannel) {
        // DS-009 deliberately keeps the persisted setting readable while the runtime is
        // native-only. Selecting automatic or the historical fallback must not silently
        // launch m1ddc and report a native operation as successful.
        _ = channel
    }

    private var selectedBackends: [DDCBackend] {
        backends.filter { $0.identifier == "apple-silicon-native" }
    }

    var availability: DDCBackendAvailability {
        selectedBackends.contains { $0.availability == .available }
            ? .available
            : .unavailable("没有可用的硬件 DDC 后端")
    }

    var capabilities: DDCBackendCapabilities {
        let available = selectedBackends.filter { $0.availability == .available }
        return DDCBackendCapabilities(
            canEnumerate: available.contains { $0.capabilities.canEnumerate },
            canReadVCP: available.contains { $0.capabilities.canReadVCP },
            canWriteVCP: available.contains { $0.capabilities.canWriteVCP }
        )
    }

    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {
        backends.forEach { $0.updateKnownDisplays(displays) }
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        var lastError: Error?
        for backend in selectedBackends where backend.availability == .available && backend.capabilities.canEnumerate {
            do {
                try token.throwIfCancelled()
                let displays = try backend.enumerateDisplays(token: token)
                if !displays.isEmpty { return displays }
                lastError = DDCBackendError.unavailable(backend: backend.identifier)
            } catch DDCBackendError.cancelled {
                throw DDCBackendError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DDCBackendError.unavailable(backend: "all")
    }

    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading {
        var lastError: Error?
        for backend in selectedBackends where backend.availability == .available && backend.capabilities.canReadVCP {
            do {
                try token.throwIfCancelled()
                return try backend.read(stableID: stableID, selector: selector, command: command, token: token)
            } catch DDCBackendError.cancelled {
                throw DDCBackendError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DDCBackendError.unavailable(backend: "all")
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws {
        var lastError: Error?
        for backend in selectedBackends where backend.availability == .available && backend.capabilities.canWriteVCP {
            do {
                try token.throwIfCancelled()
                try backend.write(stableID: stableID, selector: selector, command: command,
                                  value: value, token: token)
                return
            } catch DDCBackendError.cancelled {
                throw DDCBackendError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DDCBackendError.unavailable(backend: "all")
    }

    func cancelAll() {
        backends.forEach { $0.cancelAll() }
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        selectedBackends.compactMap { $0.diagnostic(selector: selector) }.first
    }
}

enum DisplayPresentationNameResolver {
    static func names(
        for displays: [DDCBackendDisplay],
        knownDisplays: [DDCKnownDisplay]
    ) -> [String: String] {
        let knownByID = Dictionary(uniqueKeysWithValues: knownDisplays.map {
            ($0.stableID.lowercased(), $0)
        })
        let knownRank = Dictionary(uniqueKeysWithValues: knownDisplays.enumerated().map {
            ($0.element.stableID.lowercased(), $0.offset)
        })
        let candidates = displays.map { display -> (DDCBackendDisplay, String) in
            let saved = knownByID[display.stableID.lowercased()]?.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let system = display.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferred = saved.flatMap { isGenericLegacyName($0) ? nil : $0 }
                ?? (system.isEmpty ? "外接显示器" : system)
            return (display, preferred)
        }
        let groups = Dictionary(grouping: candidates) { $0.1.lowercased() }
        var output: [String: String] = [:]
        for group in groups.values {
            let ordered = group.sorted { lhs, rhs in
                let lhsID = lhs.0.stableID.lowercased()
                let rhsID = rhs.0.stableID.lowercased()
                let lhsRank = knownRank[lhsID] ?? Int.max
                let rhsRank = knownRank[rhsID] ?? Int.max
                return lhsRank == rhsRank ? lhsID < rhsID : lhsRank < rhsRank
            }
            for (offset, item) in ordered.enumerated() {
                output[item.0.stableID.lowercased()] = ordered.count == 1
                    ? item.1
                    : "\(item.1)（\(offset + 1)）"
            }
        }
        return output
    }

    private static func isGenericLegacyName(_ value: String) -> Bool {
        value.range(of: #"^(显示器|外接显示器)\s*\d+$"#, options: .regularExpression) != nil
    }
}

struct DDCDisplayTarget: Equatable {
    let stableID: String
    let selector: String
    let enabledCommands: Set<DDCCommand>
}

struct DDCResolvedReading: Equatable {
    let reading: DDCReading
    let estimated: Bool
}

enum DDCReadSkipReason: Equatable {
    case noEnabledCommands

    var userFacingDescription: String {
        switch self {
        case .noEnabledCommands:
            return "未开启可读取的 DDC 功能"
        }
    }
}

struct DDCReadBatchResult: Equatable {
    var readings: [String: [DDCCommand: DDCResolvedReading]] = [:]
    var skipped: [String: DDCReadSkipReason] = [:]

    var isEmpty: Bool { readings.isEmpty }

    subscript(stableID: String) -> [DDCCommand: DDCResolvedReading]? {
        readings[stableID]
    }
}

protocol DDCValueCache: AnyObject {
    func value(stableID: String, command: DDCCommand) -> Int?
    func setValue(_ value: Int, stableID: String, command: DDCCommand)
}

final class DDCControlService {
    private let router: DDCBackendRouter
    private let cache: DDCValueCache
    private let stateLock = NSLock()
    private var operationsAllowed = true
    private var activeTokens: [UUID: DDCCancellationToken] = [:]

    init(router: DDCBackendRouter, cache: DDCValueCache) {
        self.router = router
        self.cache = cache
    }

    var availability: DDCBackendAvailability { router.availability }
    var capabilities: DDCBackendCapabilities { router.capabilities }

    func setOperationsAllowed(_ allowed: Bool) {
        stateLock.lock()
        operationsAllowed = allowed
        let tokens = allowed ? [] : Array(activeTokens.values)
        stateLock.unlock()
        if !allowed {
            tokens.forEach { $0.cancel() }
            router.cancelAll()
        }
    }

    func cancelAll() {
        stateLock.lock()
        let tokens = Array(activeTokens.values)
        stateLock.unlock()
        tokens.forEach { $0.cancel() }
        router.cancelAll()
    }

    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {
        router.updateKnownDisplays(displays)
    }

    func setControlChannel(_ channel: DDCControlChannel) {
        router.setControlChannel(channel)
    }

    func enumerateDisplays() throws -> [DDCBackendDisplay] {
        let operation = try beginOperation()
        defer { endOperation(operation.id) }
        let displays = try router.enumerateDisplays(token: operation.token)
        try ensureCanCommit(operation.token)
        return displays
    }

    func read(_ targets: [DDCDisplayTarget]) -> DDCReadBatchResult {
        guard let operation = try? beginOperation() else { return DDCReadBatchResult() }
        defer { endOperation(operation.id) }
        var output = DDCReadBatchResult()

        for target in targets {
            guard canContinue(operation.token) else { return DDCReadBatchResult() }
            let commands = DDCCommand.userControls.intersection(target.enabledCommands)
            guard !commands.isEmpty else {
                output.skipped[target.stableID] = .noEnabledCommands
                continue
            }
            var successful: [DDCCommand: DDCReading] = [:]
            for command in commands {
                guard canContinue(operation.token) else { return DDCReadBatchResult() }
                if let reading = try? router.read(stableID: target.stableID, selector: target.selector,
                                                  command: command, token: operation.token) {
                    successful[command] = reading
                }
            }

            let allZeroIsUntrusted = commands == DDCCommand.userControls
                && successful.count == DDCCommand.userControls.count
                && successful.values.allSatisfy { $0.current == 0 }

            for command in commands {
                guard canContinue(operation.token) else { return DDCReadBatchResult() }
                if let reading = successful[command], !allZeroIsUntrusted {
                    guard (try? commitCachedValue(reading.current, stableID: target.stableID,
                                                  command: command, token: operation.token)) != nil else {
                        return DDCReadBatchResult()
                    }
                    output.readings[target.stableID, default: [:]][command] = DDCResolvedReading(
                        reading: reading, estimated: false
                    )
                } else if let cached = cache.value(stableID: target.stableID, command: command) {
                    output.readings[target.stableID, default: [:]][command] = DDCResolvedReading(
                        reading: DDCReading(current: cached, maximum: max(100, cached)), estimated: true
                    )
                }
            }
        }
        return output
    }

    func write(command: DDCCommand, value: Int, targets: [DDCDisplayTarget]) -> [String: Error] {
        guard let operation = try? beginOperation() else {
            return Dictionary(uniqueKeysWithValues: targets.map { ($0.stableID, DDCBackendError.cancelled) })
        }
        defer { endOperation(operation.id) }
        var failures: [String: Error] = [:]
        for target in targets where target.enabledCommands.contains(command) {
            guard canContinue(operation.token) else {
                failures[target.stableID] = DDCBackendError.cancelled
                continue
            }
            do {
                try router.write(stableID: target.stableID, selector: target.selector,
                                 command: command, value: value, token: operation.token)
                try commitCachedValue(value, stableID: target.stableID, command: command,
                                      token: operation.token)
            } catch {
                failures[target.stableID] = error
            }
        }
        return failures
    }

    func cachedValue(stableID: String, command: DDCCommand) -> Int? {
        cache.value(stableID: stableID, command: command)
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        router.diagnostic(selector: selector)
    }

    private func beginOperation() throws -> (id: UUID, token: DDCCancellationToken) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard operationsAllowed else { throw DDCBackendError.cancelled }
        let id = UUID()
        let token = DDCCancellationToken()
        activeTokens[id] = token
        return (id, token)
    }

    private func endOperation(_ id: UUID) {
        stateLock.lock()
        activeTokens.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func canContinue(_ token: DDCCancellationToken) -> Bool {
        (try? ensureCanCommit(token)) != nil
    }

    private func ensureCanCommit(_ token: DDCCancellationToken) throws {
        try token.throwIfCancelled()
        stateLock.lock()
        let allowed = operationsAllowed
        stateLock.unlock()
        if !allowed { throw DDCBackendError.cancelled }
    }

    private func commitCachedValue(_ value: Int, stableID: String, command: DDCCommand,
                                   token: DDCCancellationToken) throws {
        try token.throwIfCancelled()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard operationsAllowed, !token.isCancelled else { throw DDCBackendError.cancelled }
        cache.setValue(value, stableID: stableID, command: command)
    }
}
