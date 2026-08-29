import Foundation

struct InputSourceSwitchTarget: Equatable {
    let stableID: String
    let selector: String
    let targetInput: Int?
    let alternateInput: Int?

    init(stableID: String, selector: String, targetInput: Int?, alternateInput: Int? = nil) {
        self.stableID = stableID
        self.selector = selector
        self.targetInput = targetInput
        self.alternateInput = alternateInput
    }
}

enum InputSourceSwitchOrigin: String {
    case usb = "usb"
    case manualOrCollaboration = "manual-or-collaboration"
    case unspecified = "unspecified"
}

struct InputSourceDiagnosticContext: Equatable {
    let operationID: String
    let displaySessionIndex: Int
    let targetValue: UInt16
    let alternateValue: UInt16?
}

struct InputSourceCandidateEvidence: Equatable {
    let anonymousID: String
    let transportType: String
    let locationMatched: Bool
    let productNameMatched: Bool
    let serialMatched: Bool
    let edidMatchCount: Int
    let score: Int
    let selected: Bool

    var safeDescription: String {
        "\(anonymousID){type=\(transportType),location=\(locationMatched),name=\(productNameMatched),serial=\(serialMatched),edid=\(edidMatchCount),score=\(score),selected=\(selected)}"
    }
}

enum InputSourceDeviceFeedback: Equatable {
    case targetValue(value: Int, maximum: Int, estimated: Bool)
    case alternateValue(value: Int, maximum: Int, estimated: Bool)
    case otherValue(value: Int, maximum: Int, estimated: Bool)
    case unavailable(issue: String, attempts: Int, offset: UInt8)

    var safeDescription: String {
        switch self {
        case let .targetValue(value, maximum, estimated):
            return "target-value current=\(value) max=\(maximum) estimated=\(estimated)"
        case let .alternateValue(value, maximum, estimated):
            return "alternate-value current=\(value) max=\(maximum) estimated=\(estimated)"
        case let .otherValue(value, maximum, estimated):
            return "other-value current=\(value) max=\(maximum) estimated=\(estimated)"
        case let .unavailable(issue, attempts, offset):
            return "unavailable issue=\(issue) attempts=\(attempts) offset=\(String(format: "0x%02X", offset))"
        }
    }
}

enum InputSourceDiagnosticEvent: Equatable {
    case targetQueued(origin: InputSourceSwitchOrigin, value: UInt16)
    case resolverStarted
    case candidates([InputSourceCandidateEvidence])
    case serviceSelected(anonymousID: String, reason: String, transportType: String)
    case writeAdapterReached
    case writeCall(
        attempt: Int, cycle: Int, frameHex: String,
        chip: UInt32, address: UInt8, offset: UInt8,
        startedAt: Date, endedAt: Date, returnCode: Int32, durationMicroseconds: UInt64
    )
    case writeTransportResult(acceptedByTransport: Bool)
    case deviceFeedback(InputSourceDeviceFeedback)
    case failed(reason: String)
}

protocol InputSourceDiagnosticRecording: AnyObject {
    func beginTarget(
        origin: InputSourceSwitchOrigin,
        stableID: String,
        targetValue: UInt16,
        alternateValue: UInt16?
    ) -> InputSourceDiagnosticContext
    func anonymousServiceID(for serviceLocation: Int) -> String
    func record(_ event: InputSourceDiagnosticEvent, context: InputSourceDiagnosticContext)
    func exportText() -> String
}

final class InputSourceDiagnosticStore: InputSourceDiagnosticRecording {
    static let shared = InputSourceDiagnosticStore()

    private let lock = NSLock()
    private let maximumLineCount: Int
    private var displayIndexByStableID: [String: Int] = [:]
    private var serviceIndexByLocation: [Int: Int] = [:]
    private var lines: [String] = []
    private let timestampFormatter: ISO8601DateFormatter

    init(maximumLineCount: Int = 2_000) {
        self.maximumLineCount = max(100, maximumLineCount)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
    }

    func beginTarget(
        origin: InputSourceSwitchOrigin,
        stableID: String,
        targetValue: UInt16,
        alternateValue: UInt16?
    ) -> InputSourceDiagnosticContext {
        lock.lock()
        let normalized = stableID.uppercased()
        let displayIndex: Int
        if let existing = displayIndexByStableID[normalized] {
            displayIndex = existing
        } else {
            displayIndex = displayIndexByStableID.count + 1
            displayIndexByStableID[normalized] = displayIndex
        }
        lock.unlock()
        let context = InputSourceDiagnosticContext(
            operationID: UUID().uuidString.lowercased(),
            displaySessionIndex: displayIndex,
            targetValue: targetValue,
            alternateValue: alternateValue
        )
        record(.targetQueued(origin: origin, value: targetValue), context: context)
        return context
    }

    func anonymousServiceID(for serviceLocation: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let index: Int
        if let existing = serviceIndexByLocation[serviceLocation] {
            index = existing
        } else {
            index = serviceIndexByLocation.count + 1
            serviceIndexByLocation[serviceLocation] = index
        }
        return "S\(index)"
    }

    func record(_ event: InputSourceDiagnosticEvent, context: InputSourceDiagnosticContext) {
        let prefix = "op=\(context.operationID) display=D\(context.displaySessionIndex)"
        let detail: String
        switch event {
        case let .targetQueued(origin, value):
            detail = "stage=target-queued origin=\(origin.rawValue) vcp=0x60 value=\(value)"
        case .resolverStarted:
            detail = "stage=resolver-started"
        case let .candidates(values):
            detail = "stage=candidates count=\(values.count) "
                + values.map(\.safeDescription).joined(separator: " ")
        case let .serviceSelected(anonymousID, reason, transportType):
            detail = "stage=service-selected service=\(anonymousID) type=\(transportType) reason=\(reason)"
        case .writeAdapterReached:
            detail = "stage=write-adapter-reached vcp=0x60"
        case let .writeCall(attempt, cycle, frameHex, chip, address, offset,
                            startedAt, endedAt, returnCode, durationMicroseconds):
            detail = "stage=write-i2c attempt=\(attempt) cycle=\(cycle) vcp=0x60"
                + " frame=\(frameHex) chip=\(String(format: "0x%02X", chip))"
                + " address=\(String(format: "0x%02X", address))"
                + " offset=\(String(format: "0x%02X", offset))"
                + " start=\(timestampFormatter.string(from: startedAt))"
                + " end=\(timestampFormatter.string(from: endedAt))"
                + " return=\(returnCode) duration-us=\(durationMicroseconds)"
        case let .writeTransportResult(accepted):
            detail = "stage=write-transport-result kern-success-observed=\(accepted) device-executed=unknown"
        case let .deviceFeedback(feedback):
            detail = "stage=device-feedback \(feedback.safeDescription)"
        case let .failed(reason):
            detail = "stage=failed reason=\(reason)"
        }
        lock.lock()
        lines.append(prefix + " " + detail)
        if lines.count > maximumLineCount {
            lines.removeFirst(lines.count - maximumLineCount)
        }
        lock.unlock()
    }

    func exportText() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return ([
            "DisplaySwitcher input-source diagnostic",
            "Session-only anonymized data; KERN_SUCCESS is transport acceptance, not device execution."
        ] + snapshot).joined(separator: "\n")
    }
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
    func writeInput(_ value: UInt16, context: InputSourceDiagnosticContext) -> Bool
}

protocol InputSourceTransportResolving {
    /// Returns a transport valid only for the current operation. Implementations must not cache it.
    func resolve(selector: String, context: InputSourceDiagnosticContext) throws -> InputSourceTransport
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
    private let diagnostics: InputSourceDiagnosticRecording

    init(resolver: InputSourceTransportResolving,
         hardwareArbiter: NativeI2CHardwareArbiter = .shared,
         leaseRetainer: InputSourceTransportLeaseRetainer = InputSourceTransportLeaseRetainer(),
         diagnostics: InputSourceDiagnosticRecording = InputSourceDiagnosticStore.shared) {
        self.resolver = resolver
        self.hardwareArbiter = hardwareArbiter
        self.leaseRetainer = leaseRetainer
        self.diagnostics = diagnostics
    }

    func switchInputs(
        _ targets: [InputSourceSwitchTarget],
        origin: InputSourceSwitchOrigin = .unspecified,
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
            let alternateValue = target.alternateInput.flatMap(UInt16.init(exactly:))
            let context = diagnostics.beginTarget(
                origin: origin,
                stableID: target.stableID,
                targetValue: nativeValue,
                alternateValue: alternateValue
            )

            do {
                let succeeded = try hardwareArbiter.withInputSwitch {
                    guard operationsAllowed() else {
                        throw InputSourceSwitchFailure.blocked(stableID: target.stableID)
                    }
                    diagnostics.record(.resolverStarted, context: context)
                    let transport = try resolver.resolve(selector: target.selector, context: context)
                    diagnostics.record(.writeAdapterReached, context: context)
                    let succeeded = transport.writeInput(nativeValue, context: context)
                    leaseRetainer.retain(transport)
                    return succeeded
                }
                diagnostics.record(
                    .writeTransportResult(acceptedByTransport: succeeded), context: context
                )
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: succeeded ? nil : .writeFailed(stableID: target.stableID)
                ))
            } catch let failure as InputSourceSwitchFailure {
                diagnostics.record(.failed(reason: "input-service-error"), context: context)
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
                diagnostics.record(.failed(reason: "resolver-error"), context: context)
                outcomes.append(InputSourceSwitchOutcome(
                    stableID: target.stableID,
                    failure: .displayUnavailable(stableID: target.stableID)
                ))
            }
        }

        return InputSourceSwitchBatchResult(outcomes: outcomes)
    }
}
