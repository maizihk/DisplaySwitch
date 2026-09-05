import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

enum MediaKeyAction: Hashable {
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
    let wasConsumed: Bool

    init(action: MediaKeyAction, isRepeat: Bool, wasConsumed: Bool = false) {
        self.action = action
        self.isRepeat = isRepeat
        self.wasConsumed = wasConsumed
    }
}

enum MediaKeyEventPhase: Equatable {
    case down
    case up
}

struct CapturedMediaKeyEvent: Equatable {
    let action: MediaKeyAction
    let phase: MediaKeyEventPhase
    let isRepeat: Bool

    var normalizedKeyDown: NormalizedMediaKeyEvent? {
        guard phase == .down else { return nil }
        return NormalizedMediaKeyEvent(action: action, isRepeat: isRepeat)
    }
}

/// Normalizes only NX_SYSDEFINED auxiliary-control key-down events. Ordinary F-key events never
/// enter this function, so changing the system's “Use F1, F2, etc. as standard function keys”
/// preference does not change the contract.
enum MediaKeyEventNormalizer {
    static let auxiliaryControlButtonsSubtype = 8
    static let keyDownState = 10
    static let keyUpState = 11

    private enum SystemKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    static func capture(subtype: Int, data1: Int) -> CapturedMediaKeyEvent? {
        guard subtype == auxiliaryControlButtonsSubtype else { return nil }
        let keyType = (data1 >> 16) & 0xffff
        let flags = data1 & 0xffff
        let state = (flags >> 8) & 0xff
        let phase: MediaKeyEventPhase
        switch state {
        case keyDownState: phase = .down
        case keyUpState: phase = .up
        default: return nil
        }

        let action: MediaKeyAction
        switch SystemKeyType(rawValue: keyType) {
        case .brightnessDown: action = .brightnessDown
        case .brightnessUp: action = .brightnessUp
        case .mute: action = .mute
        case .soundDown: action = .volumeDown
        case .soundUp: action = .volumeUp
        case nil: return nil
        }
        return CapturedMediaKeyEvent(action: action, phase: phase, isRepeat: flags & 1 == 1)
    }

    static func normalize(subtype: Int, data1: Int) -> NormalizedMediaKeyEvent? {
        capture(subtype: subtype, data1: data1)?.normalizedKeyDown
    }
}

enum MediaKeyMonitorState: Equatable {
    case permissionRequired
    case passive
    case activeTakeover
    case unavailable

    var diagnosticValue: String {
        switch self {
        case .permissionRequired: return "permission-required"
        case .passive: return "passive"
        case .activeTakeover: return "active"
        case .unavailable: return "unavailable"
        }
    }
}

enum MediaKeyEventTapMode: Equatable {
    case passive
    case activeTakeover

    var options: CGEventTapOptions {
        self == .activeTakeover ? .defaultTap : .listenOnly
    }

    var placement: CGEventTapPlacement {
        self == .activeTakeover ? .headInsertEventTap : .tailAppendEventTap
    }
}

enum MediaKeyTapDisposition: Equatable {
    case passThrough
    case consume
}

struct MediaKeyConsumptionSnapshot: Equatable {
    let canConsumeVolume: Bool
    let canConsumeMute: Bool

    static let disarmed = Self(
        canConsumeVolume: false,
        canConsumeMute: false
    )
}

/// The event-tap callback only consults this precomputed snapshot. It never performs CoreAudio
/// or DDC work. A consumed down owns its matching key-up even if the gate disarms in between.
final class MediaKeyEventConsumptionController {
    private let lock = NSLock()
    private var snapshot = MediaKeyConsumptionSnapshot.disarmed
    private var consumedActions = Set<MediaKeyAction>()

    func update(_ snapshot: MediaKeyConsumptionSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func disarm() {
        update(.disarmed)
    }

    /// Event-tap disable notifications are delivered on the tap callback thread. Clear both the
    /// gate and any key-up ownership synchronously so no event can be consumed while main-thread
    /// teardown is still pending.
    func failOpenAfterTapDisabled() {
        lock.lock()
        snapshot = .disarmed
        consumedActions.removeAll()
        lock.unlock()
    }

    func resetConsumedActionOwnership() {
        lock.lock()
        consumedActions.removeAll()
        lock.unlock()
    }

    func disposition(for event: CapturedMediaKeyEvent) -> MediaKeyTapDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard event.action.command == .volume else { return .passThrough }
        if event.phase == .up {
            guard consumedActions.remove(event.action) != nil else { return .passThrough }
            return .consume
        }
        let allowed = event.action == .mute
            ? snapshot.canConsumeMute
            : snapshot.canConsumeVolume
        guard allowed else { return .passThrough }
        consumedActions.insert(event.action)
        return .consume
    }
}

/// A session-scoped media-key event tap. Passive mode preserves native behavior. Active takeover
/// may delete only pre-authorized sound/mute events; brightness and unrelated events always pass.
final class MediaKeyEventMonitor {
    /// Default/backward-compatible mode remains listen-only until takeover is explicitly armed.
    static let consumesSystemEvents = false

    private let handler: (NormalizedMediaKeyEvent) -> Void
    private let disposition: (CapturedMediaKeyEvent) -> MediaKeyTapDisposition
    private let onTapDisabledSynchronously: () -> Void
    private let onTapWillRestartSynchronously: () -> Void
    private let onTapDisabled: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mode: MediaKeyEventTapMode = .passive

    init(
        handler: @escaping (NormalizedMediaKeyEvent) -> Void,
        disposition: @escaping (CapturedMediaKeyEvent) -> MediaKeyTapDisposition = { _ in .passThrough },
        onTapDisabledSynchronously: @escaping () -> Void = {},
        onTapWillRestartSynchronously: @escaping () -> Void = {},
        onTapDisabled: @escaping () -> Void = {}
    ) {
        self.handler = handler
        self.disposition = disposition
        self.onTapDisabledSynchronously = onTapDisabledSynchronously
        self.onTapWillRestartSynchronously = onTapWillRestartSynchronously
        self.onTapDisabled = onTapDisabled
    }

    deinit {
        stop()
    }

    func start(mode: MediaKeyEventTapMode = .passive, requestPermission: Bool = false) -> MediaKeyMonitorState {
        if eventTap != nil, self.mode == mode {
            return mode == .activeTakeover ? .activeTakeover : .passive
        }
        if eventTap != nil { onTapWillRestartSynchronously() }
        stop()
        self.mode = mode
        if mode == .passive {
            let allowed = requestPermission ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
            guard allowed else { return .permissionRequired }
        } else {
            guard AXIsProcessTrusted() else { return .permissionRequired }
        }
        guard let systemDefinedType = CGEventType(rawValue: 14) else { return .unavailable }
        let mask = CGEventMask(1) << systemDefinedType.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: mode.placement,
            options: mode.options,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MediaKeyEventMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.onTapDisabledSynchronously()
                    monitor.onTapDisabled()
                    // Passive taps cannot delete events and are safe to re-enable after the
                    // synchronous fail-open. Active taps stay disabled until main rebuilds them.
                    if monitor.mode == .passive, let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if let appEvent = NSEvent(cgEvent: event),
                   let captured = MediaKeyEventNormalizer.capture(
                       subtype: Int(appEvent.subtype.rawValue),
                       data1: appEvent.data1
                   ) {
                    let tapDisposition = monitor.mode == .activeTakeover
                        ? monitor.disposition(captured) : .passThrough
                    if captured.phase == .down {
                        let normalized = NormalizedMediaKeyEvent(
                            action: captured.action,
                            isRepeat: captured.isRepeat,
                            wasConsumed: tapDisposition == .consume
                        )
                        DispatchQueue.main.async { monitor.handler(normalized) }
                    }
                    if tapDisposition == .consume {
                        return nil
                    }
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
        return mode == .activeTakeover ? .activeTakeover : .passive
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
    let audioRouteGeneration: UInt64
    let targets: [MediaKeyFreshReadTarget]

    init(
        event: NormalizedMediaKeyEvent,
        linkAllDisplays: Bool,
        runtimeGeneration: UInt64,
        audioRouteGeneration: UInt64 = 0,
        targets: [MediaKeyFreshReadTarget]
    ) {
        self.event = event
        self.linkAllDisplays = linkAllDisplays
        self.runtimeGeneration = runtimeGeneration
        self.audioRouteGeneration = audioRouteGeneration
        self.targets = targets
    }
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

/// Runs one bounded DDC read batch at a time. Only consecutive held-key repeats share a fresh
/// sample; different actions retain FIFO order in a bounded queue. Invalidation suppresses every
/// queued batch and late completion from the previous runtime generation.
final class MediaKeyFreshReadCoordinator {
    static let maximumCoalescedRepeatCount = 32
    static let maximumPendingBatchCount = 8

    enum SubmitDisposition: Equatable {
        case started
        case coalesced
        case queued
        case repeatLimitReached
        case queueFull
        case ignored
    }

    typealias Completion = (MediaKeyFreshReadResult, @escaping () -> Void) -> Void

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
    private var pending: [Pending] = []
    private var awaitingRoutingToken: UInt64?
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
            if pending.isEmpty,
               awaitingRoutingToken == nil,
               canCoalesce(request, into: current.request) {
                if current.coalescedRepeatCount < Self.maximumCoalescedRepeatCount {
                    current.coalescedRepeatCount += 1
                    active = current
                    disposition = .coalesced
                } else {
                    disposition = .repeatLimitReached
                }
            } else if let lastIndex = pending.indices.last,
                      canCoalesce(request, into: pending[lastIndex].request) {
                if pending[lastIndex].coalescedRepeatCount < Self.maximumCoalescedRepeatCount {
                    pending[lastIndex].coalescedRepeatCount += 1
                    disposition = .coalesced
                } else {
                    disposition = .repeatLimitReached
                }
            } else if pending.count < Self.maximumPendingBatchCount {
                pending.append(Pending(request: request, coalescedRepeatCount: 0))
                disposition = .queued
            } else {
                disposition = .queueFull
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
        pending.removeAll()
        awaitingRoutingToken = nil
        lock.unlock()
        executor.cancelAll()
    }

    func setOperationsAllowed(_ allowed: Bool) {
        lock.lock()
        operationsAllowed = allowed
        if !allowed {
            coordinatorGeneration &+= 1
            active = nil
            pending.removeAll()
            awaitingRoutingToken = nil
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

        lock.lock()
        if let current = active,
           current.token == token,
           current.coordinatorGeneration == coordinatorGeneration,
           operationsAllowed,
           awaitingRoutingToken == nil {
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
            awaitingRoutingToken = token
        }
        lock.unlock()

        guard let result else { return }
        guard let onCompletion else {
            advanceAfterRouting(token: token)
            return
        }
        onCompletion(result) { [weak self] in
            self?.advanceAfterRouting(token: token)
        }
    }

    private func advanceAfterRouting(token: UInt64) {
        var next: Active?

        lock.lock()
        if let current = active,
           current.token == token,
           awaitingRoutingToken == token,
           current.coordinatorGeneration == coordinatorGeneration,
           operationsAllowed {
            awaitingRoutingToken = nil
            active = nil
            if !pending.isEmpty {
                let waiting = pending.removeFirst()
                next = makeActive(waiting)
                active = next
            }
        }
        lock.unlock()

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

enum AudioOutputTransport: String, Equatable {
    case hdmi
    case displayPort = "display-port"
    case other
    case unavailable

    init(coreAudioValue: UInt32?) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case nil: self = .unavailable
        default: self = .other
        }
    }

    var isExternalDisplay: Bool { self == .hdmi || self == .displayPort }
}

struct AudioOutputRouteSnapshot: Equatable {
    let transport: AudioOutputTransport
    let isAlive: Bool
    let systemVolumeSettable: Bool
    let systemMuteSettable: Bool
    let isComplete: Bool
    let generation: UInt64

    static let unavailable = Self(
        transport: .unavailable,
        isAlive: false,
        systemVolumeSettable: true,
        systemMuteSettable: true,
        isComplete: false,
        generation: 0
    )

    var allowsDDCTakeover: Bool {
        isComplete && isAlive && transport.isExternalDisplay
            && !systemVolumeSettable && !systemMuteSettable
    }

    var diagnosticValue: String {
        guard isComplete else { return "unavailable" }
        return "transport-\(transport.rawValue)-alive-\(isAlive)"
            + "-volume-settable-\(systemVolumeSettable)-mute-settable-\(systemMuteSettable)"
    }
}

protocol AudioOutputRouteMonitoring: AnyObject {
    var snapshot: AudioOutputRouteSnapshot { get }
    var onChange: ((AudioOutputRouteSnapshot) -> Void)? { get set }
    func start()
    func stop()
}

/// Read-only CoreAudio monitor. Every callback is evaluated on a private serial queue and publishes
/// only a sanitized immutable snapshot. No audio property is ever written.
final class CoreAudioOutputRouteMonitor: AudioOutputRouteMonitoring {
    private let queue = DispatchQueue(label: "DisplaySwitcher.core-audio-route")
    private let lock = NSLock()
    private var currentSnapshot = AudioOutputRouteSnapshot.unavailable
    private var currentDevice = AudioDeviceID(kAudioObjectUnknown)
    private var installedDeviceAddresses: [AudioObjectPropertyAddress] = []
    private var generation: UInt64 = 0
    private var started = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refresh()
    }

    var onChange: ((AudioOutputRouteSnapshot) -> Void)?

    var snapshot: AudioOutputRouteSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, self.queue, self.listener
            )
            guard status == noErr else {
                self.started = false
                self.publish(.unavailable)
                return
            }
            self.refresh()
        }
    }

    func stop() {
        queue.sync {
            guard started else { return }
            started = false
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
            removeDeviceListeners(currentDevice)
            currentDevice = AudioDeviceID(kAudioObjectUnknown)
            publish(.unavailable)
        }
    }

    deinit { stop() }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var requiredDeviceAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
    }

    private func refresh() {
        guard started else { return }
        let device: AudioDeviceID? = readScalar(
            object: AudioObjectID(kAudioObjectSystemObject), address: Self.defaultOutputAddress
        )
        let nextDevice = device ?? AudioDeviceID(kAudioObjectUnknown)
        if nextDevice != currentDevice {
            removeDeviceListeners(currentDevice)
            currentDevice = nextDevice
            guard addDeviceListeners(nextDevice) else {
                generation &+= 1
                publish(AudioOutputRouteSnapshot(
                    transport: .unavailable, isAlive: false,
                    systemVolumeSettable: true, systemMuteSettable: true,
                    isComplete: false, generation: generation
                ))
                return
            }
        }
        generation &+= 1
        guard nextDevice != kAudioObjectUnknown,
              let alive: UInt32 = readScalar(
                  object: nextDevice,
                  address: AudioObjectPropertyAddress(
                      mSelector: kAudioDevicePropertyDeviceIsAlive,
                      mScope: kAudioObjectPropertyScopeGlobal,
                      mElement: kAudioObjectPropertyElementMain
                  )
              ),
              let transportValue: UInt32 = readScalar(
                  object: nextDevice,
                  address: AudioObjectPropertyAddress(
                      mSelector: kAudioDevicePropertyTransportType,
                      mScope: kAudioObjectPropertyScopeGlobal,
                      mElement: kAudioObjectPropertyElementMain
                  )
              ),
              let volumeSettable = anySettable(
                  object: nextDevice, selector: kAudioDevicePropertyVolumeScalar
              ),
              let muteSettable = anySettable(
                  object: nextDevice, selector: kAudioDevicePropertyMute
              ) else {
            publish(AudioOutputRouteSnapshot(
                transport: .unavailable, isAlive: false,
                systemVolumeSettable: true, systemMuteSettable: true,
                isComplete: false, generation: generation
            ))
            return
        }
        publish(AudioOutputRouteSnapshot(
            transport: AudioOutputTransport(coreAudioValue: transportValue),
            isAlive: alive != 0,
            systemVolumeSettable: volumeSettable,
            systemMuteSettable: muteSettable,
            isComplete: true,
            generation: generation
        ))
    }

    private func addDeviceListeners(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        installedDeviceAddresses.removeAll()
        guard let channelCount = outputChannelCount(object: device) else { return false }
        var candidates = Self.requiredDeviceAddresses
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in UInt32(0)...channelCount {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                if AudioObjectHasProperty(device, &address) { candidates.append(address) }
            }
        }
        for var address in candidates {
            guard AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr else {
                removeDeviceListeners(device)
                return false
            }
            installedDeviceAddresses.append(address)
        }
        return true
    }

    private func removeDeviceListeners(_ device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else {
            installedDeviceAddresses.removeAll()
            return
        }
        for var address in installedDeviceAddresses {
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
        installedDeviceAddresses.removeAll()
    }

    private func readScalar<T>(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> T? {
        var mutableAddress = address
        guard AudioObjectHasProperty(object, &mutableAddress) else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &mutableAddress, 0, nil, &size, storage)
        return status == noErr && size == MemoryLayout<T>.size ? storage.load(as: T.self) : nil
    }

    /// Audio devices may expose volume/mute on the master or individual channels. Any writable
    /// element means macOS already owns volume control, so takeover must remain disabled.
    private func anySettable(object: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
        guard let channelCount = outputChannelCount(object: object) else { return nil }
        var foundProperty = false
        for element in UInt32(0)...channelCount {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(object, &address) else { continue }
            foundProperty = true
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else {
                return nil
            }
            if settable.boolValue { return true }
        }
        return foundProperty ? false : false
    }

    private func outputChannelCount(object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else {
            return nil
        }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let count = UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) {
            $0 &+ $1.mNumberChannels
        }
        return count
    }

    private func publish(_ snapshot: AudioOutputRouteSnapshot) {
        lock.lock()
        currentSnapshot = snapshot
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }
}

enum AccessibilityTrust {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

enum MediaKeyVolumeTakeoverGate {
    static func allows(
        optIn: Bool,
        accessibilityTrusted: Bool,
        route: AudioOutputRouteSnapshot,
        topologyTrusted: Bool,
        targetCount: Int,
        freshTargetCount: Int,
        runtimeGenerationMatches: Bool,
        audioGenerationMatches: Bool
    ) -> Bool {
        optIn && accessibilityTrusted && route.allowsDDCTakeover && topologyTrusted
            && targetCount > 0 && freshTargetCount == targetCount
            && runtimeGenerationMatches && audioGenerationMatches
    }
}

/// Enabling takeover changes volume routing semantics: only an exact display-audio route that
/// macOS cannot adjust may reach DDC. With the option off, DS-031's listen-only behavior remains
/// backward compatible and continues to mirror volume keys to DDC.
enum MediaKeyVolumeDDCRoutePolicy {
    static func allowsDDCProcessing(
        optIn: Bool,
        route: AudioOutputRouteSnapshot
    ) -> Bool {
        !optIn || route.allowsDDCTakeover
    }
}

enum MediaKeyVolumeTakeoverDiagnostic: String, Equatable {
    case passive
    case activeDisarmed = "active-disarmed"
    case activeArmed = "active-armed"
    case passedThrough = "pass-through"
    case consumed
    case ddcSubmitted = "ddc-submitted"
    case ddcSucceeded = "ddc-succeeded"
    case ddcFailed = "ddc-failed"
}

struct DDCVolumeHUDPresentation: Equatable {
    enum Icon: Equatable {
        case volume
        case muted
        case failure

        var symbolName: String {
            switch self {
            case .volume: "speaker.wave.2.fill"
            case .muted: "speaker.slash.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }
    }

    let title: String
    let detail: String
    let fraction: Double
    let isFailure: Bool
    let icon: Icon

    static func submitted(value: Int, maximum: Int) -> Self {
        let safeMaximum = max(1, maximum)
        let fraction = min(1, max(0, Double(value) / Double(safeMaximum)))
        return Self(
            title: "DDC 音量",
            detail: "已提交 \(value) / \(safeMaximum)（\(Int((fraction * 100).rounded()))%）",
            fraction: fraction,
            isFailure: false,
            icon: value == 0 ? .muted : .volume
        )
    }

    static func submitted(values: [(value: Int, maximum: Int)]) -> Self? {
        guard let first = values.first else { return nil }
        if values.allSatisfy({ $0.value == first.value && $0.maximum == first.maximum }) {
            return submitted(value: first.value, maximum: first.maximum)
        }
        let percentages = values.map {
            Int((100 * Double($0.value) / Double(max(1, $0.maximum))).rounded())
        }
        guard let lower = percentages.min(), let upper = percentages.max() else { return nil }
        let average = Double(percentages.reduce(0, +)) / Double(percentages.count) / 100
        return Self(
            title: "DDC 音量",
            detail: "已提交到 \(values.count) 台显示器（\(lower)%–\(upper)%）",
            fraction: min(1, max(0, average)),
            isFailure: false,
            icon: upper == 0 ? .muted : .volume
        )
    }

    static func current(values: [(value: Int, maximum: Int)]) -> Self? {
        guard let first = values.first else { return nil }
        let percentages = values.map {
            Int((100 * Double($0.value) / Double(max(1, $0.maximum))).rounded())
        }
        guard let lower = percentages.min(), let upper = percentages.max() else { return nil }
        let average = Double(percentages.reduce(0, +)) / Double(percentages.count) / 100
        let detail = values.count == 1
            ? "当前读取 \(first.value) / \(max(1, first.maximum))（\(lower)%）"
            : "当前读取 \(values.count) 台显示器（\(lower)%–\(upper)%）"
        return Self(
            title: "DDC 音量",
            detail: detail,
            fraction: min(1, max(0, average)),
            isFailure: false,
            icon: upper == 0 ? .muted : .volume
        )
    }

    static let failed = Self(
        title: "DDC 音量",
        detail: "显示器写入失败；下一次按键将交给 macOS",
        fraction: 0,
        isFailure: true,
        icon: .failure
    )
}

enum DDCVolumeHUDBackgroundStyle: Equatable {
    case liquidGlass
    case visualEffect
}

enum DDCVolumeHUDGlassStyle: Equatable {
    case clear
    case unavailable
}

enum DDCVolumeHUDFallbackMaterial: Equatable {
    case popover
}

struct DDCVolumeHUDMaterialContract: Equatable {
    let backgroundStyle: DDCVolumeHUDBackgroundStyle
    let glassStyle: DDCVolumeHUDGlassStyle
    let fallbackMaterial: DDCVolumeHUDFallbackMaterial
    let materialLayerCount: Int
    let drawsOpaqueContentBackground: Bool
    let drawsManualBorder: Bool
    let usesOuterClippingWrapper: Bool

    static func make(isMacOS26OrNewer: Bool) -> Self {
        Self(
            backgroundStyle: isMacOS26OrNewer ? .liquidGlass : .visualEffect,
            glassStyle: isMacOS26OrNewer ? .clear : .unavailable,
            fallbackMaterial: .popover,
            materialLayerCount: 1,
            drawsOpaqueContentBackground: false,
            drawsManualBorder: false,
            usesOuterClippingWrapper: false
        )
    }

    static var current: Self {
        if #available(macOS 26.0, *) {
            return make(isMacOS26OrNewer: true)
        }
        return make(isMacOS26OrNewer: false)
    }
}

struct DDCVolumeHUDScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum DDCVolumeHUDPlacement {
    static let safeMargin: CGFloat = 24

    static func targetVisibleFrame(
        mouseLocation: CGPoint,
        screens: [DDCVolumeHUDScreen],
        mainVisibleFrame: CGRect?
    ) -> CGRect? {
        screens.first(where: { $0.frame.contains(mouseLocation) })?.visibleFrame
            ?? mainVisibleFrame
    }

    static func origin(
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = safeMargin
    ) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX, visibleFrame.maxX - panelSize.width - margin),
            y: max(visibleFrame.minY, visibleFrame.maxY - panelSize.height - margin)
        )
    }
}

struct DDCVolumeHUDWindowBehavior: Equatable {
    let isNonactivating = true
    let ignoresMouseEvents = true
    let joinsAllSpaces = true
    let supportsFullScreen = true
    let reusesOneWindow = true
}

struct DDCVolumeHUDSessionModel: Equatable {
    struct Update: Equatable {
        let revision: UInt64
        let reusesExistingWindow: Bool
    }

    private(set) var revision: UInt64 = 0
    private(set) var isVisible = false
    private(set) var presentation: DDCVolumeHUDPresentation?

    mutating func present(_ presentation: DDCVolumeHUDPresentation) -> Update {
        revision &+= 1
        let reusesExistingWindow = isVisible
        isVisible = true
        self.presentation = presentation
        return Update(revision: revision, reusesExistingWindow: reusesExistingWindow)
    }

    mutating func dismiss(ifCurrent expectedRevision: UInt64) -> Bool {
        guard isVisible, revision == expectedRevision else { return false }
        isVisible = false
        return true
    }
}

enum DDCVolumeHUDBackgroundFactory {
    struct Result {
        let root: NSView
        let content: NSView
    }

    static func make(contract: DDCVolumeHUDMaterialContract) -> Result {
        let content = NSView()
        if #available(macOS 26.0, *),
           contract.backgroundStyle == .liquidGlass,
           contract.glassStyle == .clear {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 20
            glass.tintColor = nil
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            return Result(root: glass, content: content)
        }

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 20
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        return Result(root: material, content: content)
    }
}

final class DDCVolumeHUDController {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var dismissWorkItem: DispatchWorkItem?
    private var session = DDCVolumeHUDSessionModel()
    private let screenProvider: () -> (mouseLocation: CGPoint, screens: [DDCVolumeHUDScreen], mainVisibleFrame: CGRect?)

    init(
        materialContract: DDCVolumeHUDMaterialContract = .current,
        screenProvider: @escaping () -> (
            mouseLocation: CGPoint,
            screens: [DDCVolumeHUDScreen],
            mainVisibleFrame: CGRect?
        ) = {
            (
                NSEvent.mouseLocation,
                NSScreen.screens.map { DDCVolumeHUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                NSScreen.main?.visibleFrame
            )
        }
    ) {
        self.screenProvider = screenProvider
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 304, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let backgroundResult = DDCVolumeHUDBackgroundFactory.make(contract: materialContract)
        let background = backgroundResult.root
        let content = backgroundResult.content
        background.frame = panel.contentLayoutRect
        background.autoresizingMask = [.width, .height]
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .left
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        for view in [iconView, titleLabel, detailLabel, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(iconView)
        content.addSubview(titleLabel)
        content.addSubview(detailLabel)
        content.addSubview(progress)
        panel.contentView = background
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progress.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 9),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 5)
        ])
        background.layoutSubtreeIfNeeded()
        if content.translatesAutoresizingMaskIntoConstraints {
            content.frame = background.bounds
        }
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("DDC 音量状态")
    }

    func show(_ presentation: DDCVolumeHUDPresentation) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissWorkItem?.cancel()
        let update = session.present(presentation)
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        progress.doubleValue = presentation.fraction
        progress.isHidden = presentation.isFailure
        iconView.image = NSImage(
            systemSymbolName: presentation.icon.symbolName,
            accessibilityDescription: presentation.isFailure ? "DDC 音量写入失败" : "DDC 音量"
        )
        iconView.image?.isTemplate = true
        iconView.contentTintColor = presentation.isFailure ? .systemOrange : .labelColor
        panel.setAccessibilityValue(presentation.detail)

        let screens = screenProvider()
        if let visibleFrame = DDCVolumeHUDPlacement.targetVisibleFrame(
            mouseLocation: screens.mouseLocation,
            screens: screens.screens,
            mainVisibleFrame: screens.mainVisibleFrame
        ) {
            panel.setFrameOrigin(DDCVolumeHUDPlacement.origin(
                panelSize: panel.frame.size,
                visibleFrame: visibleFrame
            ))
        }
        if update.reusesExistingWindow {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        let expectedRevision = update.revision
        let item = DispatchWorkItem { [weak self] in
            self?.dismiss(ifCurrent: expectedRevision)
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: item)
    }

    private func dismiss(ifCurrent expectedRevision: UInt64) {
        guard session.dismiss(ifCurrent: expectedRevision) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self,
                  self.session.revision == expectedRevision,
                  !self.session.isVisible else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }
}

final class MediaKeyVolumeTakeoverController {
    struct Context: Equatable {
        let optIn: Bool
        let accessibilityTrusted: Bool
        let route: AudioOutputRouteSnapshot
        let topologyTrusted: Bool
        let runtimeGeneration: UInt64
        let targetKeys: Set<DDCWriteKey>
    }

    enum Completion: Equatable {
        case unrelated
        case pending
        case succeeded(DDCVolumeHUDPresentation)
        case failed(showHUD: Bool)
    }

    private struct Evidence {
        let event: NormalizedMediaKeyEvent
        let valueByKey: [DDCWriteKey: Int]
        let maximumByKey: [DDCWriteKey: Int]
        let runtimeGeneration: UInt64
        let audioGeneration: UInt64
    }

    private struct Batch {
        let id: UInt64
        let expectedValueByKey: [DDCWriteKey: Int]
        let maximumByKey: [DDCWriteKey: Int]
        let runtimeGeneration: UInt64
        let audioGeneration: UInt64
        let wasConsumed: Bool
        var completedKeys: Set<DDCWriteKey>
    }

    private let now: () -> TimeInterval
    private(set) var context: Context
    private var evidence: Evidence?
    private var batch: Batch?
    private var sequence: UInt64 = 0
    private(set) var isArmed = false
    private(set) var canConsumeMute = false
    private(set) var armedAt: TimeInterval?

    init(
        context: Context = Context(
            optIn: false, accessibilityTrusted: false, route: .unavailable,
            topologyTrusted: false, runtimeGeneration: 0, targetKeys: []
        ),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.context = context
        self.now = now
    }

    func updateContext(_ context: Context) {
        guard context != self.context else { return }
        self.context = context
        disarm()
    }

    func disarm() {
        evidence = nil
        batch = nil
        isArmed = false
        canConsumeMute = false
        armedAt = nil
    }

    func recordFreshRead(_ result: MediaKeyFreshReadResult) {
        guard result.request.event.action.command == .volume else { return }
        let valid = result.targets.compactMap { target -> (DDCWriteKey, DDCControlValueSample)? in
            guard let sample = target.sample,
                  !sample.estimated, sample.maximum > 0,
                  (0...sample.maximum).contains(sample.value) else { return nil }
            return (DDCWriteKey(stableID: target.stableID, command: .volume), sample)
        }
        let samples = Dictionary(valid, uniquingKeysWith: { _, newest in newest })
        guard MediaKeyVolumeTakeoverGate.allows(
            optIn: context.optIn,
            accessibilityTrusted: context.accessibilityTrusted,
            route: context.route,
            topologyTrusted: context.topologyTrusted,
            targetCount: context.targetKeys.count,
            freshTargetCount: samples.count,
            runtimeGenerationMatches: result.request.runtimeGeneration == context.runtimeGeneration,
            audioGenerationMatches: result.request.audioRouteGeneration == context.route.generation
        ), Set(samples.keys) == context.targetKeys else {
            disarm()
            return
        }
        evidence = Evidence(
            event: result.request.event,
            valueByKey: samples.mapValues(\.value),
            maximumByKey: samples.mapValues(\.maximum),
            runtimeGeneration: context.runtimeGeneration,
            audioGeneration: context.route.generation
        )
    }

    func prepare(requests: [DDCWriteRequest], event: NormalizedMediaKeyEvent) -> [DDCWriteRequest] {
        guard event.action.command == .volume,
              let evidence,
              evidence.event.action == event.action,
              evidence.runtimeGeneration == context.runtimeGeneration,
              evidence.audioGeneration == context.route.generation else {
            disarm()
            return requests
        }
        let latest = Dictionary(requests.map { ($0.key, $0.value) }, uniquingKeysWith: { _, newest in newest })
        guard Set(latest.keys) == context.targetKeys else {
            disarm()
            return requests
        }
        sequence &+= 1
        batch = Batch(
            id: sequence,
            expectedValueByKey: latest,
            maximumByKey: evidence.maximumByKey,
            runtimeGeneration: evidence.runtimeGeneration,
            audioGeneration: evidence.audioGeneration,
            wasConsumed: event.wasConsumed,
            completedKeys: []
        )
        // Fresh values are single-event evidence. The next consumed event must complete its own
        // hardware read before any media-key write can be prepared.
        self.evidence = nil
        return requests.map { $0.withOrigin(.mediaKey(sequence)) }
    }

    func recordCompletion(_ request: DDCWriteRequest, succeeded: Bool) -> Completion {
        guard case .mediaKey(let id) = request.origin,
              var batch, batch.id == id else { return .unrelated }
        guard succeeded else {
            let showHUD = batch.wasConsumed
            disarm()
            return .failed(showHUD: showHUD)
        }
        guard batch.expectedValueByKey[request.key] == request.value else { return .pending }
        batch.completedKeys.insert(request.key)
        self.batch = batch
        guard batch.completedKeys == Set(batch.expectedValueByKey.keys) else { return .pending }
        guard batch.runtimeGeneration == context.runtimeGeneration,
              batch.audioGeneration == context.route.generation,
              context.targetKeys == Set(batch.expectedValueByKey.keys) else {
            disarm()
            return .failed(showHUD: batch.wasConsumed)
        }
        let pairs = batch.expectedValueByKey.compactMap { key, value -> (value: Int, maximum: Int)? in
            guard let maximum = batch.maximumByKey[key] else { return nil }
            return (value: value, maximum: maximum)
        }
        guard pairs.count == context.targetKeys.count,
              let presentation = DDCVolumeHUDPresentation.submitted(values: pairs) else {
            disarm()
            return .failed(showHUD: batch.wasConsumed)
        }
        if !isArmed { armedAt = now() }
        isArmed = true
        // Any successful all-target media volume write establishes a nonzero value or a stored
        // restore value in MediaKeyDDCRouter, so the next mute toggle is reversible.
        canConsumeMute = true
        self.batch = nil
        return .succeeded(presentation)
    }

    func noChangePresentation(for event: NormalizedMediaKeyEvent) -> DDCVolumeHUDPresentation? {
        guard event.action != .mute,
              isArmed,
              let evidence,
              evidence.event.action == event.action,
              evidence.runtimeGeneration == context.runtimeGeneration,
              evidence.audioGeneration == context.route.generation else { return nil }
        defer { self.evidence = nil }
        let pairs = context.targetKeys.compactMap { key -> (value: Int, maximum: Int)? in
            guard let value = evidence.valueByKey[key],
                  let maximum = evidence.maximumByKey[key] else { return nil }
            return (value: value, maximum: maximum)
        }
        return pairs.count == context.targetKeys.count
            ? DDCVolumeHUDPresentation.current(values: pairs) : nil
    }

    func consumptionSnapshot() -> MediaKeyConsumptionSnapshot {
        guard isArmed else { return .disarmed }
        return MediaKeyConsumptionSnapshot(
            canConsumeVolume: true,
            canConsumeMute: canConsumeMute
        )
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
    case writeSucceeded = "write-succeeded"
    case writeFailed = "write-failed"
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
    enum Action: Equatable {
        case requestInputMonitoring
        case retryListener
    }

    let title: String
    let detail: String
    let actionTitle: String?
    let action: Action?

    static func make(state: MediaKeyMonitorState, lastRoute: String?) -> Self {
        switch state {
        case .passive, .activeTakeover:
            let suffix = lastRoute.map { " 最近一次：\($0)。" } ?? ""
            return Self(
                title: "媒体快捷键关联已启用",
                detail: state == .activeTakeover
                    ? "F1/F2 始终放行；符合安全条件时接管 F10/F11/F12。\(suffix)"
                    : "F1/F2 关联亮度，F10/F11/F12 关联音量；系统原生行为不受影响。\(suffix)",
                actionTitle: nil,
                action: nil
            )
        case .permissionRequired:
            return Self(
                title: "媒体快捷键关联需要输入监控权限",
                detail: "未授权时仅停用快捷键关联，其他功能不受影响。请在“系统设置 > 隐私与安全性 > 输入监控”中允许 DisplaySwitcher。",
                actionTitle: "申请权限",
                action: .requestInputMonitoring
            )
        case .unavailable:
            return Self(
                title: "媒体快捷键监听未启动",
                detail: "未执行任何快捷键 DDC 写入；可重试监听，其他功能不受影响。",
                actionTitle: "重试",
                action: .retryListener
            )
        }
    }
}

struct MediaKeyVolumeTakeoverPresentation: Equatable {
    enum Action: Equatable {
        case requestAccessibility
    }

    let enabled: Bool
    let title: String
    let detail: String
    let actionTitle: String?
    let action: Action?

    static func make(
        enabled: Bool,
        accessibilityTrusted: Bool,
        monitorState: MediaKeyMonitorState,
        route: AudioOutputRouteSnapshot,
        armed: Bool
    ) -> Self {
        guard enabled else {
            return Self(
                enabled: false,
                title: "HDMI/DP DDC 音量接管（可选）",
                detail: "默认关闭。需要辅助功能权限；仅在默认音频输出为 HDMI/DisplayPort，且 macOS 自身无法调音量时接管 F10/F11/F12。",
                actionTitle: nil,
                action: nil
            )
        }
        guard accessibilityTrusted else {
            return Self(
                enabled: true,
                title: "音量接管需要辅助功能权限",
                detail: "未授权时保持被动监听，不吞按键；仅当输出符合 HDMI/DP 条件时仍额外执行 DDC。可在系统设置中允许 DisplaySwitcher。",
                actionTitle: "申请辅助功能权限",
                action: .requestAccessibility
            )
        }
        let mode = monitorState == .activeTakeover ? "主动监听" : "被动监听"
        let routeText: String
        if !route.isComplete {
            routeText = "默认音频输出不可确认"
        } else if !route.transport.isExternalDisplay {
            routeText = "默认音频输出不是 HDMI/DisplayPort"
        } else if route.systemVolumeSettable || route.systemMuteSettable {
            routeText = "macOS 可直接调节当前输出"
        } else {
            routeText = "HDMI/DisplayPort 输出符合接管条件"
        }
        let behaviorText: String
        if route.allowsDDCTakeover {
            behaviorText = armed
                ? "音量键已接管，每次写入前仍会重新读取显示器"
                : "首次按键仍交给 macOS，DDC 成功后再接管"
        } else {
            behaviorText = "当前音量键完全交给 macOS，不执行 DDC"
        }
        return Self(
            enabled: true,
            title: armed ? "HDMI/DP DDC 音量接管已就绪" : "HDMI/DP DDC 音量接管待确认",
            detail: "\(mode)；\(routeText)；\(behaviorText)。",
            actionTitle: nil,
            action: nil
        )
    }
}

enum MediaKeySettingsActionKind: Equatable {
    case requestInputMonitoring
    case requestAccessibility
    case retryListener
}

struct MediaKeySettingsRowPresentation: Equatable {
    enum Role: Equatable {
        case shortcutStatus
        case volumeTakeover
    }

    let role: Role
    let title: String
    let detail: String
    let action: MediaKeySettingsActionKind?
    let actionTitle: String?

    var hasCompleteContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shortcut(_ presentation: MediaKeyShortcutPresentation) -> Self {
        Self(
            role: .shortcutStatus,
            title: presentation.title,
            detail: presentation.detail,
            action: presentation.action.map {
                switch $0 {
                case .requestInputMonitoring: .requestInputMonitoring
                case .retryListener: .retryListener
                }
            },
            actionTitle: presentation.actionTitle
        )
    }

    static func volumeTakeover(_ presentation: MediaKeyVolumeTakeoverPresentation) -> Self {
        Self(
            role: .volumeTakeover,
            title: presentation.title,
            detail: presentation.detail,
            action: presentation.action.map { _ in .requestAccessibility },
            actionTitle: presentation.actionTitle
        )
    }
}

/// Both permission actions live inside their complete status row. There are no conditional
/// spacer or separator rows, so removing an action cannot leave an empty settings row behind.
struct MediaKeySettingsSectionPresentation: Equatable {
    enum Item: Equatable {
        case row(MediaKeySettingsRowPresentation)
        case separator
    }

    let items: [Item]

    static func make(
        shortcut: MediaKeyShortcutPresentation,
        volumeTakeover: MediaKeyVolumeTakeoverPresentation
    ) -> Self {
        Self(items: [
            .row(.shortcut(shortcut)),
            .separator,
            .row(.volumeTakeover(volumeTakeover))
        ])
    }

    var hasEmptyRow: Bool {
        items.contains {
            guard case .row(let row) = $0 else { return false }
            return !row.hasCompleteContent
        }
    }

    var hasOrphanedSeparator: Bool {
        guard items.first != .separator, items.last != .separator else { return true }
        return zip(items, items.dropFirst()).contains { $0 == .separator && $1 == .separator }
    }
}
