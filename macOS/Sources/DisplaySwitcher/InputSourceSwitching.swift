import Foundation

struct InputSourceSwitchTarget: Equatable {
    let stableID: String
    let selector: String
    let targetInput: Int?
}

enum InputSourceSwitchFailure: Error, Equatable, LocalizedError {
    case blocked(stableID: String)
    case missingInput(stableID: String)
    case invalidInput(stableID: String, value: Int)
    case displayUnavailable(stableID: String)
    case writeFailed(stableID: String)

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "输入源切换已被安全门控阻止。"
        case .missingInput:
            return "目标显示器未配置输入源。"
        case let .invalidInput(_, value):
            return "输入源数值超出有效范围：\(value)"
        case .displayUnavailable:
            return "目标显示器的原生 DDC 通道当前不可用。"
        case .writeFailed:
            return "写入显示器输入源失败。"
        }
    }
}

struct InputSourceSwitchOutcome: Equatable {
    let stableID: String
    let failure: InputSourceSwitchFailure?

    var succeeded: Bool { failure == nil }
}

struct InputSourceSwitchBatchResult: Equatable {
    let outcomes: [InputSourceSwitchOutcome]

    var allSucceeded: Bool {
        !outcomes.isEmpty && outcomes.allSatisfy(\.succeeded)
    }

    var firstFailure: InputSourceSwitchFailure? {
        outcomes.compactMap(\.failure).first
    }
}

protocol InputSourceTransport: AnyObject {
    func writeInput(_ value: UInt16) -> Bool
}

protocol InputSourceTransportResolving {
    /// Returns a transport valid only for the current operation. Implementations must not cache it.
    func resolve(selector: String) throws -> InputSourceTransport
}

protocol InputSourceLeaseScheduling {
    func schedule(after delay: TimeInterval, _ operation: @escaping () -> Void)
}

private final class DispatchInputSourceLeaseScheduler: InputSourceLeaseScheduling {
    private let queue = DispatchQueue(label: "DisplaySwitcher.input-source-lease")

    func schedule(after delay: TimeInterval, _ operation: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: operation))
    }
}

/// Keeps a completed one-shot transport alive briefly without making it reusable by later events.
final class InputSourceTransportLeaseRetainer {
    private let lock = NSLock()
    private let scheduler: InputSourceLeaseScheduling
    private let leaseDuration: TimeInterval
    private let maximumLeaseCount: Int
    private var leaseOrder: [UUID] = []
    private var transportsByLeaseID: [UUID: InputSourceTransport] = [:]

    init(
        scheduler: InputSourceLeaseScheduling = DispatchInputSourceLeaseScheduler(),
        leaseDuration: TimeInterval = 1,
        maximumLeaseCount: Int = 32
    ) {
        self.scheduler = scheduler
        self.leaseDuration = leaseDuration
        self.maximumLeaseCount = max(1, maximumLeaseCount)
    }

    var activeLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return transportsByLeaseID.count
    }

    func retain(_ transport: InputSourceTransport) {
        let leaseID = UUID()
        lock.lock()
        while leaseOrder.count >= maximumLeaseCount, let oldestLeaseID = leaseOrder.first {
            leaseOrder.removeFirst()
            transportsByLeaseID.removeValue(forKey: oldestLeaseID)
        }
        leaseOrder.append(leaseID)
        transportsByLeaseID[leaseID] = transport
        lock.unlock()

        scheduler.schedule(after: leaseDuration) { [weak self] in
            self?.release(leaseID)
        }
    }

    private func release(_ leaseID: UUID) {
        lock.lock()
        transportsByLeaseID.removeValue(forKey: leaseID)
        leaseOrder.removeAll { $0 == leaseID }
        lock.unlock()
    }
}

/// Serializes native I2C access while allowing a waiting input switch to run before queued control work.
final class NativeI2CHardwareArbiter {
    static let shared = NativeI2CHardwareArbiter()

    private let condition = NSCondition()
    private var active = false
    private var waitingInputSwitches = 0

    var waitingInputSwitchCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waitingInputSwitches
    }

    func withControlOperation<T>(_ operation: () throws -> T) rethrows -> T {
        condition.lock()
        while active || waitingInputSwitches > 0 {
            condition.wait()
        }
        active = true
        condition.unlock()
        defer { release() }
        return try operation()
    }

    func withInputSwitch<T>(_ operation: () throws -> T) rethrows -> T {
        condition.lock()
        waitingInputSwitches += 1
        while active {
            condition.wait()
        }
        waitingInputSwitches -= 1
        active = true
        condition.unlock()
        defer { release() }
        return try operation()
    }

    private func release() {
        condition.lock()
        active = false
        condition.broadcast()
        condition.unlock()
    }
}

/// Dedicated VCP 0x60 service. It owns no display, read preference, diagnostic, or DDC value cache.
final class InputSourceSwitchService {
    private let resolver: InputSourceTransportResolving
    private let hardwareArbiter: NativeI2CHardwareArbiter
    private let leaseRetainer: InputSourceTransportLeaseRetainer

    init(resolver: InputSourceTransportResolving,
         hardwareArbiter: NativeI2CHardwareArbiter = .shared,
         leaseRetainer: InputSourceTransportLeaseRetainer = InputSourceTransportLeaseRetainer()) {
        self.resolver = resolver
        self.hardwareArbiter = hardwareArbiter
        self.leaseRetainer = leaseRetainer
    }

    func switchInputs(
        _ targets: [InputSourceSwitchTarget],
        operationsAllowed: () -> Bool = { true }
    ) -> InputSourceSwitchBatchResult {
        var outcomes: [InputSourceSwitchOutcome] = []
        outcomes.reserveCapacity(targets.count)

        for target in targets {
            guard operationsAllowed() else {
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: .blocked(stableID: target.stableID)
                ))
                continue
            }
            guard let targetInput = target.targetInput else {
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: .missingInput(stableID: target.stableID)
                ))
                continue
            }
            guard let nativeValue = UInt16(exactly: targetInput) else {
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: .invalidInput(stableID: target.stableID, value: targetInput)
                ))
                continue
            }

            do {
                let succeeded = try hardwareArbiter.withInputSwitch {
                    guard operationsAllowed() else {
                        throw InputSourceSwitchFailure.blocked(stableID: target.stableID)
                    }
                    let transport = try resolver.resolve(selector: target.selector)
                    let succeeded = transport.writeInput(nativeValue)
                    leaseRetainer.retain(transport)
                    return succeeded
                }
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: succeeded ? nil : .writeFailed(stableID: target.stableID)
                ))
            } catch let failure as InputSourceSwitchFailure {
                let normalizedFailure: InputSourceSwitchFailure
                switch failure {
                case .displayUnavailable:
                    normalizedFailure = .displayUnavailable(stableID: target.stableID)
                case .writeFailed:
                    normalizedFailure = .writeFailed(stableID: target.stableID)
                case .blocked:
                    normalizedFailure = .blocked(stableID: target.stableID)
                case .missingInput:
                    normalizedFailure = .missingInput(stableID: target.stableID)
                case let .invalidInput(_, value):
                    normalizedFailure = .invalidInput(stableID: target.stableID, value: value)
                }
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID, failure: normalizedFailure
                ))
            } catch {
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: .displayUnavailable(stableID: target.stableID)
                ))
            }
        }

        return InputSourceSwitchBatchResult(outcomes: outcomes)
    }
}
