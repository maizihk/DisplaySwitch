import Foundation

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
        "LastValue.stable.\(stableID.lowercased()).\(command.m1ddcName)"
    }
}

final class M1DDCBackend: DDCBackend {
    let identifier = "m1ddc"
    let capabilities = DDCBackendCapabilities(canEnumerate: true, canReadVCP: true, canWriteVCP: true)
    private let executablePath: String?
    private let processLock = NSLock()
    private var processes: [Process] = []
    private var knownDisplays: [DDCKnownDisplay] = []

    init(executablePath: String? = M1DDCBackend.detectedExecutablePath) {
        self.executablePath = executablePath
    }

    var availability: DDCBackendAvailability {
        executablePath == nil ? .unavailable("m1ddc 未安装") : .available
    }

    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {
        processLock.lock()
        knownDisplays = displays
        processLock.unlock()
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        let output = try run(arguments: ["display", "list", "detailed"], token: token)
        processLock.lock()
        let known = knownDisplays
        processLock.unlock()
        return DetectedDisplay.parseList(output).map { display in
            let stableID = known.first {
                $0.selector.caseInsensitiveCompare(display.systemUUID) == .orderedSame
            }?.stableID ?? display.systemUUID
            return DDCBackendDisplay(stableID: stableID, name: display.name, selector: display.systemUUID)
        }
    }

    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let current = try readValue(selector: selector, operation: "get", command: command, token: token)
                let maximum = try readValue(selector: selector, operation: "max", command: command, token: token)
                return DDCReading(current: current, maximum: maximum)
            } catch DDCBackendError.cancelled {
                throw DDCBackendError.cancelled
            } catch {
                lastError = error
                if attempt == 0 { Thread.sleep(forTimeInterval: 0.08) }
            }
        }
        throw lastError ?? DDCBackendError.readFailed(stableID: stableID, command: command)
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws {
        guard UInt16(exactly: value) != nil else { throw DDCError.invalidValue(value) }
        _ = try run(arguments: ["display", selector, "set", command.m1ddcName, "\(value)"], token: token)
    }

    func cancelAll() {
        processLock.lock()
        let running = processes
        processLock.unlock()
        running.filter(\.isRunning).forEach { $0.terminate() }
    }

    static var detectedExecutablePath: String? {
        ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func readValue(selector: String, operation: String, command: DDCCommand,
                           token: DDCCancellationToken) throws -> Int {
        let output = try run(arguments: ["display", selector, operation, command.m1ddcName], token: token)
        guard let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            throw DDCBackendError.readFailed(stableID: selector, command: command)
        }
        return value
    }

    private func run(arguments: [String], token: DDCCancellationToken) throws -> String {
        try token.throwIfCancelled()
        guard let executablePath else { throw DDCBackendError.unavailable(backend: identifier) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        processLock.lock()
        processes.append(process)
        do {
            try token.throwIfCancelled()
            try process.run()
            processLock.unlock()
        } catch {
            processes.removeAll { $0 === process }
            processLock.unlock()
            throw error
        }
        defer {
            processLock.lock()
            processes.removeAll { $0 === process }
            processLock.unlock()
        }
        process.waitUntilExit()
        try token.throwIfCancelled()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw DDCError.commandFailed(arguments: arguments, status: process.terminationStatus,
                                         detail: text.isEmpty ? nil : text)
        }
        return text
    }
}

final class DDCController {
    private let service: DDCControlService

    init() {
        let native = NativeDDCBackend(knownDisplays: [])
        service = DDCControlService(
            router: DDCBackendRouter(backends: [native]),
            cache: UserDefaultsDDCValueCache()
        )
    }

    /// Pure capability hint used by settings validation. It does not enumerate displays or issue DDC traffic.
    static var hasLocalBackendWithoutHardwareAccess: Bool {
#if arch(arm64)
        return true
#else
        return false
#endif
    }

    static var backendSummaryWithoutHardwareAccess: String {
#if arch(arm64)
        return "Apple Silicon 原生硬件 DDC；本版本不启用 m1ddc 回退。"
#else
        return "Intel Mac 不支持本版本的 Apple Silicon 原生硬件 DDC；不使用软件调光或 m1ddc 伪装。"
#endif
    }

    var availability: DDCBackendAvailability { service.availability }
    var capabilities: DDCBackendCapabilities { service.capabilities }

    func setOperationsAllowed(_ allowed: Bool) {
        service.setOperationsAllowed(allowed)
    }

    func cancelAll() {
        service.cancelAll()
    }

    func detectDisplays(existingConfigurations: [DisplayConfiguration]) throws -> [DetectedDisplay] {
        let known = Self.knownDisplays(from: existingConfigurations)
        service.updateKnownDisplays(known)
        let detected = try service.enumerateDisplays()
        let presentationNames = DisplayPresentationNameResolver.names(
            for: detected, knownDisplays: known
        )
        let rank = Dictionary(uniqueKeysWithValues: known.enumerated().map {
            ($0.element.stableID.lowercased(), $0.offset)
        })
        let ordered = detected.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[lhs.element.stableID.lowercased()] ?? (known.count + lhs.offset)
            let rhsRank = rank[rhs.element.stableID.lowercased()] ?? (known.count + rhs.offset)
            return lhsRank < rhsRank
        }.map(\.element)
        return ordered.enumerated().map { offset, display in
            DetectedDisplay(
                index: offset + 1,
                name: presentationNames[display.stableID.lowercased()] ?? display.name,
                systemUUID: display.selector.uppercased()
            )
        }
    }

    func updateConfigurations(_ configurations: [DisplayConfiguration]) {
        service.updateKnownDisplays(Self.knownDisplays(from: configurations))
    }

    func setControlChannel(_ channel: DDCControlChannel) {
        service.setControlChannel(channel)
    }

    func read(targets: [DDCDisplayTarget]) -> DDCReadBatchResult {
        service.read(targets)
    }

    func write(command: DDCCommand, value: Int, targets: [DDCDisplayTarget]) -> [String: Error] {
        service.write(command: command, value: value, targets: targets)
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int) throws {
        let target = DDCDisplayTarget(stableID: stableID, selector: selector,
                                      enabledCommands: [command])
        if let error = service.write(command: command, value: value, targets: [target])[stableID] {
            throw error
        }
    }

    func cachedValue(stableID: String, command: DDCCommand) -> Int? {
        service.cachedValue(stableID: stableID, command: command)
    }

    func diagnostic(selector: String) -> NativeDDCDiagnosticSnapshot? {
        service.diagnostic(selector: selector)
    }

    private static func knownDisplays(from configurations: [DisplayConfiguration]) -> [DDCKnownDisplay] {
        configurations.map {
            DDCKnownDisplay(stableID: $0.id ?? $0.selector, name: $0.name, selector: $0.selector)
        }
    }
}

enum DDCError: LocalizedError {
    case commandFailed(arguments: [String], status: Int32, detail: String?)
    case detectionFailed
    case invalidValue(Int)
    case inputNotConfigured(displayName: String)
    case m1ddcUnavailable
    case nativeWriteFailed(command: DDCCommand, value: Int)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, status, detail):
            let command = (["m1ddc"] + arguments).joined(separator: " ")
            let suffix = detail.map { "\n\n\($0)" } ?? ""
            return "命令执行失败（退出码 \(status)）：\n\(command)\(suffix)"
        case .detectionFailed:
            return "Apple Silicon 原生 DDC 没有返回可用的外接显示器。"
        case let .invalidValue(value):
            return "DDC 数值超出有效范围：\(value)"
        case let .inputNotConfigured(displayName):
            return "\(displayName) 尚未配置输入源，未执行切屏。"
        case .m1ddcUnavailable:
            return "Apple Silicon 原生 DDC 不可用；本版本不启用 m1ddc 回退。"
        case let .nativeWriteFailed(command, value):
            return "原生 DDC 写入失败：VCP 0x\(String(format: "%02X", command.rawValue)) = \(value)。"
        }
    }
}
