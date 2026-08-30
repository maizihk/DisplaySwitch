import Foundation

enum DDCCommand: UInt8, CaseIterable, Hashable {
    case luminance = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62

    var cacheKeyComponent: String {
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
    let estimated: Bool

    init(current: Int, maximum: Int, estimated: Bool = false) {
        self.current = current
        self.maximum = maximum
        self.estimated = estimated
    }
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
    static func classify(endpointToken: String? = nil,
                         epicProviderClass: String?, transportDescription: String?)
        -> NativeDDCTransportPath {
        let endpoint = endpointToken?.lowercased() ?? ""
        if endpoint == "dispexte" {
            return .builtinHDMIConverter
        }
        if endpoint.hasPrefix("dispext"),
           !endpoint.dropFirst("dispext".count).isEmpty,
           endpoint.dropFirst("dispext".count).allSatisfy(\.isNumber) {
            return .typeCDPAlt
        }
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

struct NativeDDCTransportAddressing: Equatable {
    let transportPath: NativeDDCTransportPath
    let chipAddress: UInt32

    static func resolve(endpointToken: String? = nil,
                        epicProviderClass: String?, transportDescription: String?)
        -> NativeDDCTransportAddressing {
        let classifiedPath = NativeTransportPathClassifier.classify(
            endpointToken: endpointToken,
            epicProviderClass: epicProviderClass,
            transportDescription: transportDescription
        )
        // dispextE identifies the built-in HDMI route on current Apple Silicon,
        // but it is not evidence of an MCDP converter chip. Only explicit MCDP
        // provider metadata selects the converter's 0xB7 address.
        let provider = epicProviderClass?.uppercased() ?? ""
        let isExplicitMCDP = provider.contains("MCDP")
        return NativeDDCTransportAddressing(
            transportPath: isExplicitMCDP ? .builtinHDMIConverter : classifiedPath,
            chipAddress: isExplicitMCDP ? 0xB7 : 0x37
        )
    }
}

enum NativeDisplayEndpointToken {
    static func extract(from values: [String]) -> String? {
        let expression = try? NSRegularExpression(
            pattern: "(?i)(?:^|[^a-z0-9])(dispext(?:e|[0-9]+))(?=$|[^a-z0-9])"
        )
        for value in values {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = expression?.firstMatch(in: value, range: range),
                  let tokenRange = Range(match.range(at: 1), in: value) else { continue }
            let token = String(value[tokenRange]).lowercased()
            return token == "dispexte" ? "dispextE" : token
        }
        return nil
    }
}

enum NativeDDCOperationCategory: String, Equatable {
    case idle
    case serviceUnmatched = "service-unmatched"
    case readSucceeded = "read-succeeded"
    case readDiagnosticSucceeded = "read-diagnostic-succeeded"
    case readRequestWriteFailed = "read-request-write-failed"
    case readResponseTimeout = "read-response-timeout"
    case readResponseFailed = "read-response-failed"
    case readReplyRejected = "read-reply-rejected"
    case readChecksumEstimated = "read-estimated/repeated-consistent/checksum-invalid"
    case writeSucceeded = "write-succeeded"
    case writeTransportFailed = "write-transport-failed"
}

struct NativeDDCDiagnosticSnapshot: Equatable {
    let transportPath: NativeDDCTransportPath
    let serviceMatched: Bool
    let operationCategory: NativeDDCOperationCategory
    let rebuildCount: Int
    let replyIssue: NativeDDCReplyIssue?
    let chipAddress: UInt32?
    let readDataAddress: UInt8?
    let readAttemptCount: Int?
    let checksumCompatibilityRejection: NativeDDCChecksumCompatibilityRejection?
    let checksumCompatibilityEvidence: NativeDDCChecksumCompatibilityEvidence?
    let hdmiReadDiagnostics: [NativeDDCReadAttemptDiagnostic]

    init(transportPath: NativeDDCTransportPath, serviceMatched: Bool,
         operationCategory: NativeDDCOperationCategory, rebuildCount: Int,
         replyIssue: NativeDDCReplyIssue? = nil, chipAddress: UInt32? = nil,
         readDataAddress: UInt8? = nil,
         readAttemptCount: Int? = nil,
         checksumCompatibilityRejection: NativeDDCChecksumCompatibilityRejection? = nil,
         checksumCompatibilityEvidence: NativeDDCChecksumCompatibilityEvidence? = nil,
         hdmiReadDiagnostics: [NativeDDCReadAttemptDiagnostic] = []) {
        self.transportPath = transportPath
        self.serviceMatched = serviceMatched
        self.operationCategory = operationCategory
        self.rebuildCount = rebuildCount
        self.replyIssue = replyIssue
        self.chipAddress = chipAddress
        self.readDataAddress = readDataAddress
        self.readAttemptCount = readAttemptCount
        self.checksumCompatibilityRejection = checksumCompatibilityRejection
        self.checksumCompatibilityEvidence = checksumCompatibilityEvidence
        self.hdmiReadDiagnostics = hdmiReadDiagnostics
    }

    var userFacingDescription: String {
        var operation = operationCategory.rawValue
        if operationCategory == .readReplyRejected, let replyIssue {
            operation += "/\(replyIssue.diagnosticCode)"
        }
        var parts = [
            transportPath.rawValue,
            "service \(serviceMatched ? "matched" : "unmatched")",
            operation
        ]
        if let chipAddress {
            parts.append(String(format: "chip 0x%02X", chipAddress))
        }
        if let readDataAddress {
            parts.append(readDataAddress == 0 ? "offset 0" : String(format: "offset 0x%02X", readDataAddress))
        }
        if let readAttemptCount {
            parts.append("attempts \(readAttemptCount)")
        }
        if let checksumCompatibilityRejection {
            parts.append("compatibility \(checksumCompatibilityRejection.diagnosticDescription)")
        }
        if let checksumCompatibilityEvidence {
            parts.append(checksumCompatibilityEvidence.diagnosticDescription)
        }
        if !hdmiReadDiagnostics.isEmpty {
            parts.append("HDMI offset diagnostic:\n" + hdmiReadDiagnostics
                .map(\.diagnosticDescription).joined(separator: "\n"))
        }
        parts.append("rebuild \(rebuildCount)")
        return parts.joined(separator: " · ")
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
    case nullReply
    case wrongLength
    case badChecksum
    case wrongSource
    case wrongPayloadLength
    case wrongOpcode
    case monitorRejected
    case wrongCommand
    case invalidRange
    case inconsistentStrictReplies

    var userFacingDescription: String {
        switch self {
        case .requestWriteFailed: return "读取请求写入失败"
        case .responseTimeout: return "读取回复超时"
        case .responseReadFailed: return "读取回复 I2C 失败"
        case .nullReply: return "显示器返回 DDC 空回复"
        case .wrongLength: return "回复长度无效"
        case .badChecksum: return "回复校验失败"
        case .wrongSource: return "回复来源无效"
        case .wrongPayloadLength: return "回复载荷长度无效"
        case .wrongOpcode: return "回复类型不匹配"
        case .monitorRejected: return "显示器拒绝该 VCP 请求"
        case .wrongCommand: return "回复的 VCP 项不匹配"
        case .invalidRange: return "回复的 VCP 数值范围无效"
        case .inconsistentStrictReplies: return "连续严格回复的 VCP 数值不一致"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .requestWriteFailed: return "request-write-failed"
        case .responseTimeout: return "response-timeout"
        case .responseReadFailed: return "response-read-failed"
        case .nullReply: return "null-reply"
        case .wrongLength: return "wrong-length"
        case .badChecksum: return "bad-checksum"
        case .wrongSource: return "wrong-source"
        case .wrongPayloadLength: return "wrong-payload-length"
        case .wrongOpcode: return "wrong-opcode"
        case .monitorRejected: return "monitor-rejected"
        case .wrongCommand: return "wrong-command"
        case .invalidRange: return "invalid-range"
        case .inconsistentStrictReplies: return "inconsistent-strict-replies"
        }
    }

    var permitsAlternateReadOffset: Bool {
        self != .requestWriteFailed
    }
}

enum NativeDDCStrictReadValidation: Equatable {
    case valid(DDCReading)
    case rejected(NativeDDCReplyIssue)

    var diagnosticCode: String {
        switch self {
        case .valid:
            return "strict-valid"
        case .rejected(let issue):
            return "strict-rejected/\(issue.diagnosticCode)"
        }
    }
}

struct NativeDDCReadAttemptDiagnostic: Equatable {
    let dataAddress: UInt8
    let strategyAttempt: Int
    let delayMicroseconds: UInt32
    let writeIOReturns: [Int32]
    let readIOReturn: Int32?
    let reply: [UInt8]
    let validation: NativeDDCStrictReadValidation

    var diagnosticDescription: String {
        let offset = dataAddress == 0 ? "0" : String(format: "0x%02X", dataAddress)
        let writeResults = writeIOReturns.map(Self.hexIOReturn).joined(separator: ",")
        let readResult = readIOReturn.map(Self.hexIOReturn) ?? "not-called"
        let replyHex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "offset \(offset) attempt \(strategyAttempt) delay-us \(delayMicroseconds)" +
            " write-ior=[\(writeResults)] read-ior=\(readResult)" +
            " reply=[\(replyHex)] \(validation.diagnosticCode)"
    }

    private static func hexIOReturn(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}

enum NativeDDCReadStrategyOutcome: Equatable {
    case success(DDCReading, dataAddress: UInt8, attempts: Int)
    case failure(
        NativeDDCReplyIssue,
        dataAddress: UInt8,
        attempts: Int,
        onlyObservedIssueWasBadChecksum: Bool,
        checksumCompatibilityRejection: NativeDDCChecksumCompatibilityRejection? = nil,
        checksumCompatibilityEvidence: NativeDDCChecksumCompatibilityEvidence? = nil
    )
}

enum NativeDDCReadStrategyRunner {
    static func run(
        primaryDataAddress: UInt8,
        alternateDataAddress: UInt8?,
        attemptsPerStrategy: Int,
        responseLength: Int = 11,
        exchange: (UInt8, inout [UInt8]) -> Result<DDCReading, NativeDDCReplyIssue>
    ) -> NativeDDCReadStrategyOutcome {
        let attemptLimit = max(attemptsPerStrategy, 1)
        var totalAttempts = 0
        var lastIssue = NativeDDCReplyIssue.responseReadFailed
        var observedIssues: [NativeDDCReplyIssue] = []
        func runStrategy(_ address: UInt8) -> DDCReading? {
            for _ in 0..<attemptLimit {
                totalAttempts += 1
                var response = [UInt8](repeating: 0, count: responseLength)
                switch exchange(address, &response) {
                case .success(let reading):
                    return reading
                case .failure(let issue):
                    lastIssue = issue
                    observedIssues.append(issue)
                }
            }
            return nil
        }

        if let reading = runStrategy(primaryDataAddress) {
            return .success(reading, dataAddress: primaryDataAddress, attempts: totalAttempts)
        }
        if lastIssue.permitsAlternateReadOffset,
           let alternateDataAddress, alternateDataAddress != primaryDataAddress {
            if let reading = runStrategy(alternateDataAddress) {
                return .success(reading, dataAddress: alternateDataAddress, attempts: totalAttempts)
            }
            return .failure(
                lastIssue,
                dataAddress: alternateDataAddress,
                attempts: totalAttempts,
                onlyObservedIssueWasBadChecksum: observedIssues.allSatisfy { $0 == .badChecksum },
                checksumCompatibilityRejection: nil,
                checksumCompatibilityEvidence: nil
            )
        }
        return .failure(
            lastIssue,
            dataAddress: primaryDataAddress,
            attempts: totalAttempts,
            onlyObservedIssueWasBadChecksum: observedIssues.allSatisfy { $0 == .badChecksum },
            checksumCompatibilityRejection: nil,
            checksumCompatibilityEvidence: nil
        )
    }
}

struct NativeDDCHDMIReadDiagnosticResult: Equatable {
    let outcome: NativeDDCReadStrategyOutcome
    let attempts: [NativeDDCReadAttemptDiagnostic]
}

enum NativeDDCHDMIReadDiagnosticRunner {
    static func run(
        primaryDataAddress: UInt8,
        alternateDataAddress: UInt8?,
        attemptsPerStrategy: Int,
        exchange: (UInt8, Int) -> NativeDDCReadAttemptDiagnostic
    ) -> NativeDDCHDMIReadDiagnosticResult {
        let attemptLimit = max(attemptsPerStrategy, 1)
        var records: [NativeDDCReadAttemptDiagnostic] = []
        var totalAttempts = 0
        var lastIssue = NativeDDCReplyIssue.responseReadFailed
        var primaryStrictReading: DDCReading?

        for attempt in 1...attemptLimit {
            totalAttempts += 1
            let record = exchange(primaryDataAddress, attempt)
            records.append(record)
            switch record.validation {
            case .valid(let reading):
                if primaryDataAddress == 0x51 {
                    guard reading.maximum > 0, reading.current <= reading.maximum else {
                        primaryStrictReading = nil
                        lastIssue = .invalidRange
                        continue
                    }
                    if let previous = primaryStrictReading {
                        guard previous.current == reading.current,
                              previous.maximum == reading.maximum else {
                            primaryStrictReading = reading
                            lastIssue = .inconsistentStrictReplies
                            continue
                        }
                    } else {
                        primaryStrictReading = reading
                        continue
                    }
                }
                return NativeDDCHDMIReadDiagnosticResult(
                    outcome: .success(
                        reading, dataAddress: primaryDataAddress, attempts: totalAttempts
                    ),
                    attempts: records
                )
            case .rejected(let issue):
                primaryStrictReading = nil
                lastIssue = issue
            }
        }

        guard lastIssue.permitsAlternateReadOffset,
              let alternateDataAddress,
              alternateDataAddress != primaryDataAddress else {
            return NativeDDCHDMIReadDiagnosticResult(
                outcome: .failure(
                    lastIssue,
                    dataAddress: primaryDataAddress,
                    attempts: totalAttempts,
                    onlyObservedIssueWasBadChecksum: records.allSatisfy {
                        $0.validation == .rejected(.badChecksum)
                    }
                ),
                attempts: records
            )
        }

        var previousStrictReading: DDCReading?
        var observedInconsistentStrictReplies = false
        for attempt in 1...attemptLimit {
            totalAttempts += 1
            let record = exchange(alternateDataAddress, attempt)
            records.append(record)
            switch record.validation {
            case .valid(let reading):
                guard reading.maximum > 0, reading.current <= reading.maximum else {
                    previousStrictReading = nil
                    lastIssue = .invalidRange
                    continue
                }
                if let previous = previousStrictReading {
                    guard previous.current == reading.current,
                          previous.maximum == reading.maximum else {
                        observedInconsistentStrictReplies = true
                        lastIssue = .inconsistentStrictReplies
                        previousStrictReading = reading
                        continue
                    }
                    return NativeDDCHDMIReadDiagnosticResult(
                        outcome: .success(
                            reading, dataAddress: alternateDataAddress, attempts: totalAttempts
                        ),
                        attempts: records
                    )
                }
                previousStrictReading = reading
            case .rejected(let issue):
                previousStrictReading = nil
                lastIssue = issue
            }
        }
        if observedInconsistentStrictReplies, previousStrictReading != nil {
            lastIssue = .inconsistentStrictReplies
        }
        return NativeDDCHDMIReadDiagnosticResult(
            outcome: .failure(
                lastIssue,
                dataAddress: alternateDataAddress,
                attempts: totalAttempts,
                onlyObservedIssueWasBadChecksum: records.allSatisfy {
                    $0.validation == .rejected(.badChecksum)
                }
            ),
            attempts: records
        )
    }

}

struct NativeDDCReadPreferenceKey: Hashable {
    let selector: String
    let serviceIdentity: UInt64
    let transportPath: NativeDDCTransportPath

    init(selector: String, serviceIdentity: UInt64, transportPath: NativeDDCTransportPath) {
        self.selector = selector.uppercased()
        self.serviceIdentity = serviceIdentity
        self.transportPath = transportPath
    }
}

struct NativeDDCReadPreferenceCache {
    private var values: [NativeDDCReadPreferenceKey: UInt8] = [:]

    func preferredAddress(for key: NativeDDCReadPreferenceKey,
                          default defaultAddress: UInt8) -> UInt8 {
        values[key] ?? defaultAddress
    }

    mutating func remember(address: UInt8, for key: NativeDDCReadPreferenceKey) {
        values[key] = address
    }

    mutating func invalidate(selector: String) {
        let normalized = selector.uppercased()
        values = values.filter { $0.key.selector != normalized }
    }

    mutating func retainOnly(_ validKeys: Set<NativeDDCReadPreferenceKey>) {
        values = values.filter { validKeys.contains($0.key) }
    }

    mutating func removeAll() {
        values.removeAll()
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
        guard !(reply[0] == 0x6E && reply[1] & 0x7F == 0) else {
            return .failure(.nullReply)
        }
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

struct NativeDDCChecksumPayloadComparison: Equatable {
    let commandMatches: Bool
    let currentMatches: Bool
    let maximumMatches: Bool
    let payloadLengths: [Int]

    var diagnosticDescription: String {
        "command-match=\(commandMatches)" +
            "/current-same=\(currentMatches)" +
            "/max-same=\(maximumMatches)" +
            "/payload-length=\(payloadLengths.map(String.init).joined(separator: ","))"
    }
}

struct NativeDDCReplySemanticFields: Equatable {
    let source: UInt8?
    let payloadLength: UInt8?
    let opcode: UInt8?
    let result: UInt8?
    let command: UInt8?
    let current: Int?
    let maximum: Int?

    init(reply: [UInt8]) {
        source = Self.byte(reply, at: 0)
        payloadLength = Self.byte(reply, at: 1)
        opcode = Self.byte(reply, at: 2)
        result = Self.byte(reply, at: 3)
        command = Self.byte(reply, at: 4)
        maximum = Self.word(reply, high: 6, low: 7)
        current = Self.word(reply, high: 8, low: 9)
    }

    var diagnosticDescription: String {
        [
            "source=\(Self.hex(source))\(sourceAssessment)",
            "payload-length=\(Self.hex(payloadLength))",
            "opcode=\(Self.hex(opcode))",
            "result=\(Self.hex(result))",
            "command=\(Self.hex(command))",
            "current=\(current.map(String.init) ?? "n/a")",
            "max=\(maximum.map(String.init) ?? "n/a")"
        ].joined(separator: ",")
    }

    private var sourceAssessment: String {
        switch source {
        case 0x6E: return "(expected)"
        case 0x6F: return "(alternate-source)"
        case 0x02: return "(suspected-frame-shift/opcode-at-source)"
        case 0x00: return "(suspected-frame-shift/zero-at-source)"
        case .some: return "(unexpected-source)"
        case nil: return "(missing)"
        }
    }

    private static func byte(_ reply: [UInt8], at index: Int) -> UInt8? {
        reply.indices.contains(index) ? reply[index] : nil
    }

    private static func word(_ reply: [UInt8], high: Int, low: Int) -> Int? {
        guard let highByte = byte(reply, at: high), let lowByte = byte(reply, at: low) else { return nil }
        return Int(UInt16(highByte) << 8 | UInt16(lowByte))
    }

    private static func hex(_ value: UInt8?) -> String {
        value.map { String(format: "0x%02X", $0) } ?? "n/a"
    }
}

struct NativeDDCChecksumCompatibilityEvidence: Equatable {
    let replies: [NativeDDCReplySemanticFields]

    init(replies: [[UInt8]]) {
        self.replies = replies.map(NativeDDCReplySemanticFields.init(reply:))
    }

    var diagnosticDescription: String {
        let replyDescriptions = replies.enumerated().map { index, reply in
            "reply\(index + 1){\(reply.diagnosticDescription)}"
        }
        let consistent = replies.count >= NativeDDCChecksumCompatibilityValidator.requiredReplyCount
            && replies.dropFirst().allSatisfy { $0 == replies[0] }
        return (replyDescriptions + ["semantic-fields-consistent=\(consistent)"])
            .joined(separator: " · ")
    }
}

enum NativeDDCChecksumCompatibilityRejection: Equatable {
    case insufficientReplies
    case checksumWasValid
    case inconsistentPayload(NativeDDCChecksumPayloadComparison)
    case invalidField(NativeDDCReplyIssue)
    case invalidRange(current: Int, maximum: Int)
    case transportError(NativeDDCReplyIssue)

    var diagnosticDescription: String {
        switch self {
        case .insufficientReplies:
            return "insufficient-replies"
        case .checksumWasValid:
            return "checksum-was-valid"
        case .inconsistentPayload(let comparison):
            return "inconsistent-payload/\(comparison.diagnosticDescription)"
        case .invalidField(let issue):
            return "invalid-field/\(issue.diagnosticCode)"
        case .invalidRange(let current, let maximum):
            return "invalid-range/current=\(current)/max=\(maximum)"
        case .transportError(let issue):
            return "transport-error/\(issue.diagnosticCode)"
        }
    }
}

enum NativeDDCChecksumCompatibilityResult: Equatable {
    case accepted(DDCReading)
    case rejected(
        NativeDDCChecksumCompatibilityRejection,
        evidence: NativeDDCChecksumCompatibilityEvidence
    )
}

enum NativeDDCChecksumCompatibilityValidator {
    static let requiredReplyCount = 2

    static func reading(from replies: [[UInt8]], command: DDCCommand)
        -> NativeDDCChecksumCompatibilityResult {
        let evidence = NativeDDCChecksumCompatibilityEvidence(replies: replies)
        guard replies.count >= requiredReplyCount else {
            return .rejected(.insufficientReplies, evidence: evidence)
        }
        let compared = Array(replies.prefix(requiredReplyCount))
        for reply in compared {
            guard reply.count == 11 else {
                return .rejected(.invalidField(.wrongLength), evidence: evidence)
            }
            guard reply.dropLast().reduce(UInt8(0x50), ^) != reply.last else {
                return .rejected(.checksumWasValid, evidence: evidence)
            }
            let issue = fieldIssue(reply, command: command)
            guard issue == .badChecksum else {
                return .rejected(.invalidField(issue), evidence: evidence)
            }
        }
        guard compared.dropFirst().allSatisfy({ $0.dropLast() == compared[0].dropLast() }) else {
            let commands = compared.map { $0[4] }
            let currents = compared.map { Int(UInt16($0[8]) << 8 | UInt16($0[9])) }
            let maximums = compared.map { Int(UInt16($0[6]) << 8 | UInt16($0[7])) }
            return .rejected(.inconsistentPayload(NativeDDCChecksumPayloadComparison(
                commandMatches: commands.allSatisfy { $0 == command.rawValue },
                currentMatches: Set(currents).count == 1,
                maximumMatches: Set(maximums).count == 1,
                payloadLengths: compared.map { Int($0[1] & 0x7F) }
            )), evidence: evidence)
        }
        let reply = compared[0]
        let maximum = Int(UInt16(reply[6]) << 8 | UInt16(reply[7]))
        let current = Int(UInt16(reply[8]) << 8 | UInt16(reply[9]))
        guard maximum > 0, current <= maximum else {
            return .rejected(.invalidRange(current: current, maximum: maximum), evidence: evidence)
        }
        return .accepted(DDCReading(current: current, maximum: maximum, estimated: true))
    }

    private static func fieldIssue(_ reply: [UInt8], command: DDCCommand) -> NativeDDCReplyIssue {
        guard reply.count == 11 else { return .wrongLength }
        guard !(reply[0] == 0x6E && reply[1] & 0x7F == 0) else { return .nullReply }
        guard reply[0] == 0x6E else { return .wrongSource }
        guard reply[1] & 0x7F == 8 else { return .wrongPayloadLength }
        guard reply[2] == 0x02 else { return .wrongOpcode }
        guard reply[3] == 0 else { return .monitorRejected }
        guard reply[4] == command.rawValue else { return .wrongCommand }
        return .badChecksum
    }
}

enum NativeDDCChecksumCompatibilityRunner {
    static func run(
        responseLength: Int = 11,
        command: DDCCommand,
        exchange: (inout [UInt8]) -> Result<Void, NativeDDCReplyIssue>
    ) -> NativeDDCChecksumCompatibilityResult {
        var replies: [[UInt8]] = []
        var transportIssue: NativeDDCReplyIssue?
        for _ in 0..<NativeDDCChecksumCompatibilityValidator.requiredReplyCount {
            var response = [UInt8](repeating: 0, count: responseLength)
            switch exchange(&response) {
            case .success:
                replies.append(response)
            case .failure(let issue):
                transportIssue = issue
            }
        }
        guard transportIssue == nil else {
            return .rejected(
                .transportError(transportIssue ?? .responseReadFailed),
                evidence: NativeDDCChecksumCompatibilityEvidence(replies: replies)
            )
        }
        return NativeDDCChecksumCompatibilityValidator.reading(from: replies, command: command)
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

enum NativeInputCandidateDiagnosticProjection {
    static func evidence(
        identity: NativeDisplayIdentity?,
        candidates: [NativeTransportCandidate],
        selectedServiceLocation: Int?,
        anonymousServiceID: (Int) -> String = { "S\($0)" }
    ) -> [InputSourceCandidateEvidence] {
        candidates.map { candidate in
            let locationMatched = identity.map {
                !$0.ioDisplayLocation.isEmpty && $0.ioDisplayLocation == candidate.ioDisplayLocation
            } ?? false
            let productNameMatched = identity.map {
                !$0.productName.isEmpty
                    && $0.productName.caseInsensitiveCompare(candidate.productName) == .orderedSame
            } ?? false
            let serialMatched = identity.map {
                $0.serialNumber != 0 && $0.serialNumber == candidate.serialNumber
            } ?? false
            let candidateEDID = candidate.edidUUID.uppercased()
            let edidMatches = identity?.edidSearchKeys.filter { key in
                !key.value.isEmpty && key.value != "0000" && key.offset >= 0
                    && candidateEDID.count >= key.offset + key.value.count
                    && String(candidateEDID.dropFirst(key.offset).prefix(key.value.count)) == key.value
            }.count ?? 0
            let score = (locationMatched ? 10 : 0)
                + (productNameMatched ? 1 : 0)
                + (serialMatched ? 4 : 0)
                + edidMatches
            return InputSourceCandidateEvidence(
                anonymousID: anonymousServiceID(candidate.serviceLocation),
                transportType: candidate.transportPath.rawValue,
                locationMatched: locationMatched,
                productNameMatched: productNameMatched,
                serialMatched: serialMatched,
                edidMatchCount: edidMatches,
                score: score,
                selected: candidate.serviceLocation == selectedServiceLocation
            )
        }
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
    private let backend: DDCBackend

    init(backend: DDCBackend) {
        self.backend = backend
    }

    var availability: DDCBackendAvailability {
        backend.availability
    }

    var capabilities: DDCBackendCapabilities {
        backend.availability == .available
            ? backend.capabilities
            : DDCBackendCapabilities(canEnumerate: false, canReadVCP: false, canWriteVCP: false)
    }

    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {
        backend.updateKnownDisplays(displays)
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        guard backend.availability == .available, backend.capabilities.canEnumerate else {
            throw DDCBackendError.unavailable(backend: backend.identifier)
        }
        try token.throwIfCancelled()
        let displays = try backend.enumerateDisplays(token: token)
        guard !displays.isEmpty else {
            throw DDCBackendError.unavailable(backend: backend.identifier)
        }
        return displays
    }

    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading {
        guard backend.availability == .available, backend.capabilities.canReadVCP else {
            throw DDCBackendError.unavailable(backend: backend.identifier)
        }
        try token.throwIfCancelled()
        return try backend.read(stableID: stableID, selector: selector, command: command, token: token)
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws {
        guard backend.availability == .available, backend.capabilities.canWriteVCP else {
            throw DDCBackendError.unavailable(backend: backend.identifier)
        }
        try token.throwIfCancelled()
        try backend.write(stableID: stableID, selector: selector, command: command,
                          value: value, token: token)
    }

    func cancelAll() {
        backend.cancelAll()
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        backend.diagnostic(selector: selector)
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

final class UserDefaultsDDCValueCache: DDCValueCache {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value(stableID: String, command: DDCCommand) -> Int? {
        let key = cacheKey(stableID: stableID, command: command)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    func setValue(_ value: Int, stableID: String, command: DDCCommand) {
        defaults.set(value, forKey: cacheKey(stableID: stableID, command: command))
    }

    private func cacheKey(stableID: String, command: DDCCommand) -> String {
        "LastValue.stable.\(stableID.lowercased()).\(command.cacheKeyComponent)"
    }
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
                        reading: reading, estimated: reading.estimated
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
