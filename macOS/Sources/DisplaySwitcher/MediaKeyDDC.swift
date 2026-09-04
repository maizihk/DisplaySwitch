import AppKit
import CoreGraphics
import Foundation

enum MediaKeyAction: Equatable {
    case brightnessDown
    case brightnessUp
    case mute
    case volumeDown
    case volumeUp

    var command: DDCCommand {
        switch self {
        case .brightnessDown, .brightnessUp:
            return .luminance
        case .mute, .volumeDown, .volumeUp:
            return .volume
        }
    }

    var delta: Int? {
        switch self {
        case .brightnessDown, .volumeDown: return -5
        case .brightnessUp, .volumeUp: return 5
        case .mute: return nil
        }
    }
}

struct NormalizedMediaKeyEvent: Equatable {
    let action: MediaKeyAction
    let isRepeat: Bool
}

/// Normalizes only NX_SYSDEFINED auxiliary-control key-down events. Ordinary F-key events never
/// enter this function, so changing the system's “Use F1, F2, etc. as standard function keys”
/// preference does not change the contract.
enum MediaKeyEventNormalizer {
    static let auxiliaryControlButtonsSubtype = 8
    static let keyDownState = 10

    private enum SystemKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    static func normalize(subtype: Int, data1: Int) -> NormalizedMediaKeyEvent? {
        guard subtype == auxiliaryControlButtonsSubtype else { return nil }
        let keyType = (data1 >> 16) & 0xffff
        let flags = data1 & 0xffff
        guard ((flags >> 8) & 0xff) == keyDownState else { return nil }

        let action: MediaKeyAction
        switch SystemKeyType(rawValue: keyType) {
        case .brightnessDown: action = .brightnessDown
        case .brightnessUp: action = .brightnessUp
        case .mute: action = .mute
        case .soundDown: action = .volumeDown
        case .soundUp: action = .volumeUp
        case nil: return nil
        }
        return NormalizedMediaKeyEvent(action: action, isRepeat: flags & 1 == 1)
    }
}

enum MediaKeyMonitorState: Equatable {
    case permissionRequired
    case active
    case unavailable

    var diagnosticValue: String {
        switch self {
        case .permissionRequired: return "permission-required"
        case .active: return "active"
        case .unavailable: return "unavailable"
        }
    }
}

/// A session-scoped, listen-only event tap. The callback always returns the original event, so
/// native macOS brightness and volume handling remains in place.
final class MediaKeyEventMonitor {
    static let consumesSystemEvents = false

    private let handler: (NormalizedMediaKeyEvent) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping (NormalizedMediaKeyEvent) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start(requestPermission: Bool = false) -> MediaKeyMonitorState {
        stop()
        let allowed = requestPermission ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
        guard allowed else { return .permissionRequired }
        guard let systemDefinedType = CGEventType(rawValue: 14) else { return .unavailable }
        let mask = CGEventMask(1) << systemDefinedType.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MediaKeyEventMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if let appEvent = NSEvent(cgEvent: event),
                   let normalized = MediaKeyEventNormalizer.normalize(
                       subtype: Int(appEvent.subtype.rawValue),
                       data1: appEvent.data1
                   ) {
                    DispatchQueue.main.async { monitor.handler(normalized) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return .unavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .unavailable
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .active
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

struct MediaKeyDDCTarget: Equatable {
    let stableID: String
    let selector: String
    let sample: DDCControlValueSample?
}

struct MediaKeyFreshReadTarget: Equatable {
    let stableID: String
    let selector: String
}

struct MediaKeyFreshReadRequest: Equatable {
    let event: NormalizedMediaKeyEvent
    let linkAllDisplays: Bool
    let runtimeGeneration: UInt64
    let targets: [MediaKeyFreshReadTarget]
}

struct MediaKeyFreshReadResult: Equatable {
    let request: MediaKeyFreshReadRequest
    let targets: [MediaKeyDDCTarget]
    let coalescedRepeatCount: Int

    var failedTargetCount: Int {
        targets.filter { $0.sample == nil }.count
    }
}

enum MediaKeyFreshReadAdmission {
    static func allows(
        operationsAllowed: Bool,
        physicalEvidence: DDCPhysicalEnumerationEvidence,
        targets: [MediaKeyFreshReadTarget]
    ) -> Bool {
        operationsAllowed
            && MediaKeyTopologyPolicy.allows(physicalEvidence)
            && !targets.isEmpty
    }
}

protocol MediaKeyFreshReadExecuting: AnyObject {
    func execute(
        targets: [MediaKeyFreshReadTarget],
        command: DDCCommand,
        completion: @escaping ([String: DDCControlValueSample]) -> Void
    )
    func cancelAll()
}

/// Runs one bounded DDC read batch at a time. Held-key repeat events for the active action share
/// that fresh sample; other events replace one bounded pending slot instead of creating a read
/// storm. Invalidation suppresses every late completion from the previous runtime generation.
final class MediaKeyFreshReadCoordinator {
    static let maximumCoalescedRepeatCount = 32

    enum SubmitDisposition: Equatable {
        case started
        case coalesced
        case queued
        case ignored
    }

    typealias Completion = (MediaKeyFreshReadResult) -> Void

    private struct Pending {
        var request: MediaKeyFreshReadRequest
        var coalescedRepeatCount: Int
    }

    private struct Active {
        let request: MediaKeyFreshReadRequest
        var coalescedRepeatCount: Int
        let token: UInt64
        let coordinatorGeneration: UInt64
    }

    private let executor: MediaKeyFreshReadExecuting
    private let lock = NSLock()
    private var active: Active?
    private var pending: Pending?
    private var coordinatorGeneration: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var operationsAllowed = true

    var onReadStarted: ((MediaKeyFreshReadRequest) -> Void)?
    var onCompletion: Completion?

    init(executor: MediaKeyFreshReadExecuting) {
        self.executor = executor
    }

    @discardableResult
    func submit(_ request: MediaKeyFreshReadRequest) -> SubmitDisposition {
        var itemToStart: Active?
        let disposition: SubmitDisposition

        lock.lock()
        if !operationsAllowed {
            disposition = .ignored
        } else if var current = active {
            if canCoalesce(request, into: current.request) {
                current.coalescedRepeatCount = min(
                    current.coalescedRepeatCount + 1,
                    Self.maximumCoalescedRepeatCount
                )
                active = current
                disposition = .coalesced
            } else if var waiting = pending, canCoalesce(request, into: waiting.request) {
                waiting.coalescedRepeatCount = min(
                    waiting.coalescedRepeatCount + 1,
                    Self.maximumCoalescedRepeatCount
                )
                pending = waiting
                disposition = .coalesced
            } else {
                pending = Pending(request: request, coalescedRepeatCount: 0)
                disposition = .queued
            }
        } else {
            itemToStart = makeActive(Pending(request: request, coalescedRepeatCount: 0))
            active = itemToStart
            disposition = .started
        }
        lock.unlock()

        if let itemToStart { start(itemToStart) }
        return disposition
    }

    func invalidate() {
        lock.lock()
        coordinatorGeneration &+= 1
        active = nil
        pending = nil
        lock.unlock()
        executor.cancelAll()
    }

    func setOperationsAllowed(_ allowed: Bool) {
        lock.lock()
        operationsAllowed = allowed
        if !allowed {
            coordinatorGeneration &+= 1
            active = nil
            pending = nil
        }
        lock.unlock()
        if !allowed { executor.cancelAll() }
    }

    private func canCoalesce(
        _ incoming: MediaKeyFreshReadRequest,
        into existing: MediaKeyFreshReadRequest
    ) -> Bool {
        incoming.event.isRepeat
            && incoming.event.action == existing.event.action
            && incoming.linkAllDisplays == existing.linkAllDisplays
            && incoming.runtimeGeneration == existing.runtimeGeneration
            && incoming.targets == existing.targets
    }

    private func makeActive(_ pending: Pending) -> Active {
        nextToken &+= 1
        return Active(
            request: pending.request,
            coalescedRepeatCount: pending.coalescedRepeatCount,
            token: nextToken,
            coordinatorGeneration: coordinatorGeneration
        )
    }

    private func start(_ item: Active) {
        onReadStarted?(item.request)
        executor.execute(targets: item.request.targets, command: item.request.event.action.command) {
            [weak self] samples in
            self?.finish(token: item.token, samples: samples)
        }
    }

    private func finish(token: UInt64, samples: [String: DDCControlValueSample]) {
        var result: MediaKeyFreshReadResult?
        var next: Active?

        lock.lock()
        if let current = active,
           current.token == token,
           current.coordinatorGeneration == coordinatorGeneration,
           operationsAllowed {
            let targets = current.request.targets.map { target in
                MediaKeyDDCTarget(
                    stableID: target.stableID,
                    selector: target.selector,
                    sample: samples[target.stableID.lowercased()]
                )
            }
            result = MediaKeyFreshReadResult(
                request: current.request,
                targets: targets,
                coalescedRepeatCount: current.coalescedRepeatCount
            )
            active = nil
            if let waiting = pending {
                pending = nil
                next = makeActive(waiting)
                active = next
            }
        }
        lock.unlock()

        if let result { onCompletion?(result) }
        if let next { start(next) }
    }
}

final class DDCControllerMediaKeyFreshReadExecutor: MediaKeyFreshReadExecuting {
    private let queue: DispatchQueue
    private let read: ([DDCDisplayTarget]) -> DDCReadBatchResult
    private let cancellation: () -> Void

    init(
        queue: DispatchQueue,
        read: @escaping ([DDCDisplayTarget]) -> DDCReadBatchResult,
        cancellation: @escaping () -> Void
    ) {
        self.queue = queue
        self.read = read
        self.cancellation = cancellation
    }

    func execute(
        targets: [MediaKeyFreshReadTarget],
        command: DDCCommand,
        completion: @escaping ([String: DDCControlValueSample]) -> Void
    ) {
        queue.async { [read] in
            let batch = read(targets.map {
                DDCDisplayTarget(
                    stableID: $0.stableID,
                    selector: $0.selector,
                    enabledCommands: [command]
                )
            })
            var samples: [String: DDCControlValueSample] = [:]
            for target in targets {
                guard let resolved = batch[target.stableID]?[command],
                      !resolved.estimated,
                      !resolved.reading.estimated,
                      resolved.reading.maximum > 0,
                      (0...resolved.reading.maximum).contains(resolved.reading.current) else {
                    continue
                }
                samples[target.stableID.lowercased()] = DDCControlValueSample(
                    value: resolved.reading.current,
                    maximum: resolved.reading.maximum,
                    estimated: false
                )
            }
            completion(samples)
        }
    }

    func cancelAll() {
        cancellation()
    }
}

enum MediaKeyTopologyPolicy {
    static func allows(_ evidence: DDCPhysicalEnumerationEvidence) -> Bool {
        evidence.isCompletePhysicalSnapshot
    }
}

enum MediaKeyRuntimeStage: String, Equatable {
    case eventSeen = "event-seen"
    case freshReadStarted = "fresh-read-started"
    case freshReadFailed = "fresh-read-failed"
    case routeBlocked = "route-blocked"
    case writeSubmitted = "write-submitted"
}

struct MediaKeyRuntimeStageTrace: Equatable {
    private(set) var stages: [MediaKeyRuntimeStage] = []

    mutating func beginEvent() {
        stages = [.eventSeen]
    }

    mutating func append(_ stage: MediaKeyRuntimeStage) {
        if stages.last != stage { stages.append(stage) }
    }

    mutating func clear() {
        stages.removeAll()
    }

    var diagnosticValue: String {
        stages.isEmpty ? "none" : stages.map(\.rawValue).joined(separator: ",")
    }
}

enum MediaKeyDDCRouteOutcome: Equatable {
    case applied(Int)
    case ignoredMuteRepeat
    case noEnabledTargets
    case missingTrustedValues
    case mixedLinkedValues
    case noStoredMuteValue
    case unchanged

    var diagnosticValue: String {
        switch self {
        case .applied(let count): return "applied-\(count)"
        case .ignoredMuteRepeat: return "ignored-mute-repeat"
        case .noEnabledTargets: return "no-enabled-targets"
        case .missingTrustedValues: return "missing-trusted-values"
        case .mixedLinkedValues: return "mixed-linked-values"
        case .noStoredMuteValue: return "no-stored-mute-value"
        case .unchanged: return "unchanged-at-limit"
        }
    }

    var userFacingValue: String {
        switch self {
        case .applied(let count): return "已向 \(count) 台显示器提交"
        case .ignoredMuteRepeat: return "已忽略静音长按重复"
        case .noEnabledTargets: return "没有启用对应控制项的显示器"
        case .missingTrustedValues: return "缺少可信当前值，未写入"
        case .mixedLinkedValues: return "联动值不一致，未写入"
        case .noStoredMuteValue: return "没有可安全恢复的音量，未写入"
        case .unchanged: return "已达到调节边界，未写入"
        }
    }
}

struct MediaKeyDDCPlan: Equatable {
    let requests: [DDCWriteRequest]
    let outcome: MediaKeyDDCRouteOutcome
}

/// Pure except for session-only mute restore values. Callers supply only currently online,
/// physically trusted targets which have the requested command enabled.
struct MediaKeyDDCRouter {
    private var lastNonzeroVolume: [String: Int] = [:]
    private var projectedValues: [DDCWriteKey: DDCControlValueSample] = [:]

    mutating func invalidateSessionState() {
        lastNonzeroVolume.removeAll()
        projectedValues.removeAll()
    }

    mutating func recordCompletion(_ request: DDCWriteRequest, succeeded: Bool) {
        let key = projectionKey(
            stableID: request.key.stableID,
            command: request.key.command
        )
        if !succeeded || projectedValues[key]?.value == request.value {
            projectedValues.removeValue(forKey: key)
        }
    }

    mutating func beginFreshReadRouting(command: DDCCommand, targets: [MediaKeyDDCTarget]) {
        for target in targets {
            projectedValues.removeValue(
                forKey: projectionKey(stableID: target.stableID, command: command)
            )
        }
    }

    mutating func plan(
        event: NormalizedMediaKeyEvent,
        linkAllDisplays: Bool,
        targets: [MediaKeyDDCTarget]
    ) -> MediaKeyDDCPlan {
        guard !targets.isEmpty else {
            return MediaKeyDDCPlan(requests: [], outcome: .noEnabledTargets)
        }
        if event.action == .mute, event.isRepeat {
            return MediaKeyDDCPlan(requests: [], outcome: .ignoredMuteRepeat)
        }
        if event.action == .mute {
            return linkAllDisplays ? linkedMute(targets) : independentMute(targets)
        }
        guard let delta = event.action.delta else {
            return MediaKeyDDCPlan(requests: [], outcome: .unchanged)
        }
        return linkAllDisplays
            ? linkedAdjustment(command: event.action.command, delta: delta, targets: targets)
            : independentAdjustment(command: event.action.command, delta: delta, targets: targets)
    }

    private func trustedSample(_ target: MediaKeyDDCTarget) -> DDCControlValueSample? {
        guard let sample = target.sample,
              !sample.estimated,
              sample.maximum > 0,
              (0...sample.maximum).contains(sample.value) else { return nil }
        return sample
    }

    private func projectionKey(stableID: String, command: DDCCommand) -> DDCWriteKey {
        DDCWriteKey(stableID: stableID.lowercased(), command: command)
    }

    private func effectiveSample(
        _ target: MediaKeyDDCTarget,
        command: DDCCommand
    ) -> DDCControlValueSample? {
        projectedValues[projectionKey(stableID: target.stableID, command: command)]
            ?? trustedSample(target)
    }

    private mutating func rememberProjection(
        _ target: MediaKeyDDCTarget,
        command: DDCCommand,
        value: Int,
        maximum: Int
    ) {
        projectedValues[projectionKey(stableID: target.stableID, command: command)] =
            DDCControlValueSample(value: value, maximum: maximum, estimated: false)
    }

    private func request(_ target: MediaKeyDDCTarget, command: DDCCommand, value: Int) -> DDCWriteRequest {
        DDCWriteRequest(
            key: DDCWriteKey(stableID: target.stableID, command: command),
            selector: target.selector,
            value: value
        )
    }

    private mutating func independentAdjustment(
        command: DDCCommand,
        delta: Int,
        targets: [MediaKeyDDCTarget]
    ) -> MediaKeyDDCPlan {
        var requests: [DDCWriteRequest] = []
        for target in targets {
            guard let sample = effectiveSample(target, command: command) else { continue }
            let value = min(sample.maximum, max(0, sample.value + delta))
            guard value != sample.value else { continue }
            requests.append(request(target, command: command, value: value))
            rememberProjection(target, command: command, value: value, maximum: sample.maximum)
            if command == .volume {
                if sample.value > 0 { lastNonzeroVolume[target.stableID.lowercased()] = sample.value }
                if value > 0 { lastNonzeroVolume[target.stableID.lowercased()] = value }
            }
        }
        if !requests.isEmpty { return MediaKeyDDCPlan(requests: requests, outcome: .applied(requests.count)) }
        let hasTrusted = targets.contains { effectiveSample($0, command: command) != nil }
        return MediaKeyDDCPlan(
            requests: [], outcome: hasTrusted ? .unchanged : .missingTrustedValues
        )
    }

    private mutating func linkedAdjustment(
        command: DDCCommand,
        delta: Int,
        targets: [MediaKeyDDCTarget]
    ) -> MediaKeyDDCPlan {
        let samples = targets.compactMap { effectiveSample($0, command: command) }
        guard samples.count == targets.count else {
            return MediaKeyDDCPlan(requests: [], outcome: .missingTrustedValues)
        }
        guard let current = samples.first?.value,
              samples.dropFirst().allSatisfy({ $0.value == current }) else {
            return MediaKeyDDCPlan(requests: [], outcome: .mixedLinkedValues)
        }
        let maximum = samples.map(\.maximum).min() ?? 0
        let value = min(maximum, max(0, current + delta))
        guard value != current else {
            return MediaKeyDDCPlan(requests: [], outcome: .unchanged)
        }
        if command == .volume {
            for target in targets {
                if current > 0 { lastNonzeroVolume[target.stableID.lowercased()] = current }
                if value > 0 { lastNonzeroVolume[target.stableID.lowercased()] = value }
            }
        }
        let requests = targets.map { request($0, command: command, value: value) }
        for (target, sample) in zip(targets, samples) {
            rememberProjection(target, command: command, value: value, maximum: sample.maximum)
        }
        return MediaKeyDDCPlan(requests: requests, outcome: .applied(requests.count))
    }

    private mutating func independentMute(_ targets: [MediaKeyDDCTarget]) -> MediaKeyDDCPlan {
        var requests: [DDCWriteRequest] = []
        var hadTrustedValue = false
        var missingRestore = false
        for target in targets {
            guard let sample = effectiveSample(target, command: .volume) else { continue }
            hadTrustedValue = true
            let key = target.stableID.lowercased()
            if sample.value > 0 {
                lastNonzeroVolume[key] = sample.value
                requests.append(request(target, command: .volume, value: 0))
                rememberProjection(target, command: .volume, value: 0, maximum: sample.maximum)
            } else if let restore = lastNonzeroVolume[key], restore > 0, restore <= sample.maximum {
                requests.append(request(target, command: .volume, value: restore))
                rememberProjection(target, command: .volume, value: restore, maximum: sample.maximum)
            } else {
                missingRestore = true
            }
        }
        if !requests.isEmpty { return MediaKeyDDCPlan(requests: requests, outcome: .applied(requests.count)) }
        if !hadTrustedValue { return MediaKeyDDCPlan(requests: [], outcome: .missingTrustedValues) }
        return MediaKeyDDCPlan(
            requests: [], outcome: missingRestore ? .noStoredMuteValue : .unchanged
        )
    }

    private mutating func linkedMute(_ targets: [MediaKeyDDCTarget]) -> MediaKeyDDCPlan {
        let samples = targets.compactMap { effectiveSample($0, command: .volume) }
        guard samples.count == targets.count else {
            return MediaKeyDDCPlan(requests: [], outcome: .missingTrustedValues)
        }
        guard let current = samples.first?.value,
              samples.dropFirst().allSatisfy({ $0.value == current }) else {
            return MediaKeyDDCPlan(requests: [], outcome: .mixedLinkedValues)
        }
        let value: Int
        if current > 0 {
            value = 0
            for target in targets {
                lastNonzeroVolume[target.stableID.lowercased()] = current
            }
        } else {
            let restored = targets.compactMap { lastNonzeroVolume[$0.stableID.lowercased()] }
            guard restored.count == targets.count,
                  let first = restored.first,
                  first > 0,
                  restored.dropFirst().allSatisfy({ $0 == first }),
                  zip(restored, samples).allSatisfy({ $0.0 <= $0.1.maximum }) else {
                return MediaKeyDDCPlan(requests: [], outcome: .noStoredMuteValue)
            }
            value = first
        }
        let requests = targets.map { request($0, command: .volume, value: value) }
        for (target, sample) in zip(targets, samples) {
            rememberProjection(target, command: .volume, value: value, maximum: sample.maximum)
        }
        return MediaKeyDDCPlan(requests: requests, outcome: .applied(requests.count))
    }
}

struct MediaKeyShortcutPresentation: Equatable {
    let title: String
    let detail: String
    let actionTitle: String?

    static func make(state: MediaKeyMonitorState, lastRoute: String?) -> Self {
        switch state {
        case .active:
            let suffix = lastRoute.map { " 最近一次：\($0)。" } ?? ""
            return Self(
                title: "媒体快捷键关联已启用",
                detail: "F1/F2 关联亮度，F10/F11/F12 关联音量；系统原生行为不受影响。\(suffix)",
                actionTitle: nil
            )
        case .permissionRequired:
            return Self(
                title: "媒体快捷键关联需要输入监控权限",
                detail: "未授权时仅停用快捷键关联，其他功能不受影响。请在“系统设置 > 隐私与安全性 > 输入监控”中允许 DisplaySwitcher。",
                actionTitle: "申请权限"
            )
        case .unavailable:
            return Self(
                title: "媒体快捷键监听未启动",
                detail: "未执行任何快捷键 DDC 写入；可重试监听，其他功能不受影响。",
                actionTitle: "重试"
            )
        }
    }
}
