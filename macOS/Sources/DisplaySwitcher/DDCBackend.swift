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

enum DDCBackendError: Error, Equatable, LocalizedError {
    case unavailable(backend: String)
    case displayUnavailable(stableID: String)
    case readFailed(stableID: String, command: DDCCommand)
    case writeFailed(stableID: String, command: DDCCommand)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "没有可用的硬件 DDC 后端。"
        case .displayUnavailable:
            return "目标显示器在当前 DDC 后端中不可用。"
        case let .readFailed(_, command):
            return "读取 VCP 0x\(String(format: "%02X", command.rawValue)) 失败。"
        case let .writeFailed(_, command):
            return "写入 VCP 0x\(String(format: "%02X", command.rawValue)) 失败。"
        case .cancelled:
            return "DDC 操作已取消。"
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
}

extension DDCBackend {
    func updateKnownDisplays(_ displays: [DDCKnownDisplay]) {}
    func cancelAll() {}
}

final class DDCBackendRouter {
    private let backends: [DDCBackend]

    init(backends: [DDCBackend]) {
        self.backends = backends
    }

    var availability: DDCBackendAvailability {
        backends.contains { $0.availability == .available }
            ? .available
            : .unavailable("没有可用的硬件 DDC 后端")
    }

    var capabilities: DDCBackendCapabilities {
        let available = backends.filter { $0.availability == .available }
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
        for backend in backends where backend.availability == .available && backend.capabilities.canEnumerate {
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
        for backend in backends where backend.availability == .available && backend.capabilities.canReadVCP {
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
        for backend in backends where backend.availability == .available && backend.capabilities.canWriteVCP {
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
}

struct DDCDisplayTarget: Equatable {
    let stableID: String
    let selector: String
    let readEnabled: Bool
    let enabledCommands: Set<DDCCommand>
}

struct DDCResolvedReading: Equatable {
    let reading: DDCReading
    let estimated: Bool
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

    func enumerateDisplays() throws -> [DDCBackendDisplay] {
        let operation = try beginOperation()
        defer { endOperation(operation.id) }
        let displays = try router.enumerateDisplays(token: operation.token)
        try ensureCanCommit(operation.token)
        return displays
    }

    func read(_ targets: [DDCDisplayTarget]) -> [String: [DDCCommand: DDCResolvedReading]] {
        guard let operation = try? beginOperation() else { return [:] }
        defer { endOperation(operation.id) }
        var output: [String: [DDCCommand: DDCResolvedReading]] = [:]

        for target in targets where target.readEnabled {
            guard canContinue(operation.token) else { return [:] }
            let commands = DDCCommand.userControls.intersection(target.enabledCommands)
            var successful: [DDCCommand: DDCReading] = [:]
            for command in commands {
                guard canContinue(operation.token) else { return [:] }
                if let reading = try? router.read(stableID: target.stableID, selector: target.selector,
                                                  command: command, token: operation.token) {
                    successful[command] = reading
                }
            }

            let allZeroIsUntrusted = commands == DDCCommand.userControls
                && successful.count == DDCCommand.userControls.count
                && successful.values.allSatisfy { $0.current == 0 }

            for command in commands {
                guard canContinue(operation.token) else { return [:] }
                if let reading = successful[command], !allZeroIsUntrusted {
                    guard (try? commitCachedValue(reading.current, stableID: target.stableID,
                                                  command: command, token: operation.token)) != nil else {
                        return [:]
                    }
                    output[target.stableID, default: [:]][command] = DDCResolvedReading(
                        reading: reading, estimated: false
                    )
                } else if let cached = cache.value(stableID: target.stableID, command: command) {
                    output[target.stableID, default: [:]][command] = DDCResolvedReading(
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
