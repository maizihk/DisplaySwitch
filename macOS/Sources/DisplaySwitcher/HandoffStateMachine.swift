import Foundation

enum HandoffPlatform: String {
    case mac
    case windows
}

protocol HandoffClock {
    func currentTimeMs() -> Int64
}

protocol HandoffScheduler {
    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void)
    func cancel(_ key: String)
}

protocol HandoffEventIDSource {
    func nextEventID() -> String
}

protocol HandoffActionSink {
    func sendMessage(type: PeerMessageType, eventID: String, wakeSucceeded: Bool?)
    func sendBurst(type: PeerMessageType, count: Int, eventID: String, wakeSucceeded: Bool?)
    func requestWake(eventID: String)
    func requestSwitch(eventID: String)
    func updatePeerReachable(_ reachable: Bool)
}

enum HandoffAction {
    case acceptMessage(type: PeerMessageType, eventID: String)
    case rejectMessage(type: PeerMessageType, eventID: String, reason: String)
    case sendMessage(type: PeerMessageType, eventID: String, wakeSucceeded: Bool?)
    case sendBurst(type: PeerMessageType, count: Int, eventID: String, wakeSucceeded: Bool?)
    case requestWake(eventID: String)
    case requestSwitch(eventID: String)
    case setPeerReachable(Bool)
    case cancelOutgoing(eventID: String)
}

struct HandoffStateSnapshot {
    let localPlatform: String
    let coordinationEnabled: Bool
    let usbAutomationEnabled: Bool
    let usbPresent: Bool
    let peerReachable: Bool
    let peerLastSeenAtMs: Int64?
    let incomingEventID: String?
    let outgoingEventID: String?
    let newestIncomingRequestTimestamp: TimeInterval?
    let seenMessageCount: Int
}

private enum WakePurpose {
    case incomingReady
    case usbPresence
}

private struct HandoffReplayGuard {
    private(set) var newestIncomingRequestTimestamp: TimeInterval = 0
    private var seen: [String: Int64] = [:]

    mutating func reset() {
        newestIncomingRequestTimestamp = 0
        seen.removeAll(keepingCapacity: true)
    }

    mutating func restoreSeen(type: String, eventID: String, seenAtMs: Int64) {
        seen[replayKey(type: type, eventID: eventID)] = seenAtMs
    }

    mutating func classify(_ message: PeerMessage, nowMs: Int64) -> (isDuplicate: Bool, isOutOfOrder: Bool) {
        prune(nowMs: nowMs)

        let key = replayKey(type: message.type.rawValue, eventID: message.eventID)
        if let seenMs = seen[key], nowMs - seenMs <= PeerMessageValidation.maximumAgeMs {
            return (true, false)
        }

        let isOutOfOrder =
            message.type == .handoverRequest &&
            newestIncomingRequestTimestamp > 0 &&
            message.timestamp < newestIncomingRequestTimestamp

        if !isOutOfOrder {
            if message.type == .handoverRequest {
                newestIncomingRequestTimestamp = max(
                    newestIncomingRequestTimestamp,
                    message.timestamp
                )
            }
            seen[key] = nowMs
        }

        if seen.count > 2048, let oldest = seen.min(by: { $0.value < $1.value })?.key {
            seen.removeValue(forKey: oldest)
        }
        return (false, isOutOfOrder)
    }

    mutating func setNewestIncomingRequestTimestamp(_ timestamp: TimeInterval?) {
        newestIncomingRequestTimestamp = timestamp ?? 0
    }

    var seenCount: Int { seen.count }

    private mutating func prune(nowMs: Int64) {
        seen = seen.filter { nowMs - $0.value <= PeerMessageValidation.maximumAgeMs }
    }

    private func replayKey(type: String, eventID: String) -> String {
        "\(type):\(eventID.lowercased())"
    }
}

final class HandoffStateMachine {
    private static let debounceMs: Int64 = 150
    private static let peerReachableWindowMs: Int64 = 6_000
    private static let handoverRetryMs: Int64 = 150
    private static let handoverFallbackMs: Int64 = 600
    private static let handoverRetryCount = 4
    private static let messageBurstCount = 3

    private let expectedSource: String
    private let expectedTarget: String
    private let platform: HandoffPlatform
    private let sink: HandoffActionSink
    private let clock: HandoffClock
    private let scheduler: HandoffScheduler
    private let eventIDSource: HandoffEventIDSource
    private let actionLog: ((HandoffAction) -> Void)?

    private(set) var coordinationEnabled = true
    private(set) var usbAutomationEnabled = true
    private(set) var usbPresent = false
    private(set) var peerReachable = false
    private(set) var peerLastSeenAtMs: Int64?
    private(set) var incomingEventID: String?
    private(set) var outgoingEventID: String?
    private(set) var newestIncomingRequestTimestamp: TimeInterval?

    private var outgoingSwitchEventID: String?
    private var outgoingTimers = Set<String>()
    private var scheduledTimerKeys = Set<String>()
    private var replayGuard = HandoffReplayGuard()
    private var peerHealthTimerKey = "peer-health"
    private var pairingCode = ""
    private var pendingWakeByEventID: [String: WakePurpose] = [:]
    private var wakeSucceededByEventID: [String: Bool] = [:]
    private var shouldSendIncomingReadyAfterUsbArrival = false

    init(
        localPlatform: HandoffPlatform,
        sink: HandoffActionSink,
        clock: HandoffClock,
        scheduler: HandoffScheduler,
        eventIDSource: HandoffEventIDSource,
        actionLog: ((HandoffAction) -> Void)? = nil
    ) {
        platform = localPlatform
        expectedSource = localPlatform == .mac ? "windows" : "mac"
        expectedTarget = localPlatform == .mac ? "mac" : "windows"
        self.sink = sink
        self.clock = clock
        self.scheduler = scheduler
        self.eventIDSource = eventIDSource
        self.actionLog = actionLog
    }

    func setPairingCode(_ value: String) {
        pairingCode = value
    }

    func configure(
        coordinationEnabled: Bool,
        usbAutomationEnabled: Bool,
        usbPresent: Bool,
        peerReachable: Bool,
        peerLastSeenAtMs: Int64?,
        incomingEventID: String?,
        outgoingEventID: String?,
        newestIncomingRequestTimestamp: TimeInterval?,
        seenMessages: [(type: String, eventID: String, seenAtMs: Int64)],
        pairingCode: String
    ) {
        reset()
        self.pairingCode = pairingCode
        self.coordinationEnabled = coordinationEnabled
        self.usbAutomationEnabled = usbAutomationEnabled
        self.usbPresent = usbPresent
        self.peerReachable = peerReachable
        self.peerLastSeenAtMs = peerLastSeenAtMs
        self.incomingEventID = incomingEventID
        self.outgoingEventID = outgoingEventID
        self.newestIncomingRequestTimestamp = newestIncomingRequestTimestamp
        replayGuard.setNewestIncomingRequestTimestamp(newestIncomingRequestTimestamp)
        for item in seenMessages {
            replayGuard.restoreSeen(type: item.type, eventID: item.eventID, seenAtMs: item.seenAtMs)
        }
        if peerReachable, let lastSeenAtMs = peerLastSeenAtMs {
            schedulePeerReachableExpiry(atMs: lastSeenAtMs)
        }
        if outgoingEventID != nil {
            self.peerHealthTimerKey = "peer-health"
        }
    }

    func reset() {
        coordinationEnabled = true
        usbAutomationEnabled = true
        usbPresent = false
        peerReachable = false
        peerLastSeenAtMs = nil
        incomingEventID = nil
        outgoingEventID = nil
        outgoingSwitchEventID = nil
        newestIncomingRequestTimestamp = nil
        wakeSucceededByEventID.removeAll()
        pendingWakeByEventID.removeAll()
        shouldSendIncomingReadyAfterUsbArrival = false
        outgoingTimers.removeAll()
        for key in scheduledTimerKeys {
            scheduler.cancel(key)
        }
        scheduledTimerKeys.removeAll()
        replayGuard.reset()
    }

    func setCoordinationEnabled(_ enabled: Bool) {
        guard coordinationEnabled != enabled else { return }
        coordinationEnabled = enabled
        if !enabled {
            cancelOutgoing(emitAction: true)
            peerReachable = false
            peerLastSeenAtMs = nil
            incomingEventID = nil
            outgoingEventID = nil
            outgoingSwitchEventID = nil
            newestIncomingRequestTimestamp = nil
            wakeSucceededByEventID.removeAll()
            pendingWakeByEventID.removeAll()
            shouldSendIncomingReadyAfterUsbArrival = false
            replayGuard.reset()
            log(.setPeerReachable(false))
            sink.updatePeerReachable(false)
        }
    }

    func setUsbAutomationEnabled(_ enabled: Bool) {
        usbAutomationEnabled = enabled
    }

    func setPeerReachabilityFromHost(timeMs: Int64) {
        peerLastSeenAtMs = timeMs
        checkPeerReachability(nowMs: timeMs)
    }

    func snapshot() -> HandoffStateSnapshot {
        HandoffStateSnapshot(
            localPlatform: platform.rawValue,
            coordinationEnabled: coordinationEnabled,
            usbAutomationEnabled: usbAutomationEnabled,
            usbPresent: usbPresent,
            peerReachable: peerReachable,
            peerLastSeenAtMs: peerLastSeenAtMs,
            incomingEventID: incomingEventID,
            outgoingEventID: outgoingEventID,
            newestIncomingRequestTimestamp: newestIncomingRequestTimestamp,
            seenMessageCount: replayGuard.seenCount
        )
    }

    func handleAdvanceTime(to timeMs: Int64) {
        checkPeerReachability(nowMs: timeMs)
    }

    func handleUSBPresenceChanged(_ present: Bool) {
        guard coordinationEnabled && usbAutomationEnabled else { return }
        guard usbPresent != present else { return }

        usbPresent = present
        let debounceKey = "usb-debounce"

        if present {
            scheduler.cancel(debounceKey)
            scheduledTimerKeys.remove(debounceKey)

            if let outgoingID = outgoingEventID {
                cancelOutgoing(emitAction: true)
            }

            if let incomingID = incomingEventID, shouldSendIncomingReadyAfterUsbArrival {
                if let wakeSucceeded = wakeSucceededByEventID[incomingID] {
                    sendUsbReadyBurst(eventID: incomingID, wakeSucceeded: wakeSucceeded)
                    shouldSendIncomingReadyAfterUsbArrival = false
                }
            } else if let incomingID = incomingEventID,
                      let wakeSucceeded = wakeSucceededByEventID[incomingID] {
                sendUsbReadyBurst(eventID: incomingID, wakeSucceeded: wakeSucceeded)
            }

            let eventID = eventIDSource.nextEventID()
            pendingWakeByEventID[eventID] = .usbPresence
            log(.requestWake(eventID: eventID))
            sink.requestWake(eventID: eventID)
            return
        }

        let beginTime = Self.debounceMs
        scheduler.schedule(debounceKey, after: beginTime) { [weak self] in
            guard let self else { return }
            if !self.usbPresent {
                self.beginOutgoingHandover()
            }
        }
        scheduledTimerKeys.insert(debounceKey)
    }

    func handleIncomingMessage(_ message: PeerMessage) {
        let nowMs = clock.currentTimeMs()
        let validation = PeerMessageValidation.validate(
            message: message,
            pairingCode: pairingCode,
            expectedSource: expectedSource,
            expectedTarget: expectedTarget,
            now: Double(nowMs) / 1000.0
        )

        guard validation.accepted else {
            log(.rejectMessage(type: message.type, eventID: message.eventID, reason: validation.reason.rawValue))
            return
        }

        let disposition = replayGuard.classify(message, nowMs: nowMs)
        if disposition.isDuplicate {
            markPeerReachable(nowMs: nowMs)
            log(.rejectMessage(type: message.type, eventID: message.eventID, reason: "duplicate"))
            if message.type == .handoverRequest,
               let incomingEventID,
               incomingEventID == message.eventID,
               usbPresent {
                sendUsbReadyBurst(
                    eventID: message.eventID,
                    wakeSucceeded: wakeSucceededByEventID[incomingEventID]
                )
            }
            return
        }

        log(.acceptMessage(type: message.type, eventID: message.eventID))
        markPeerReachable(nowMs: nowMs)

        if disposition.isOutOfOrder {
            log(.rejectMessage(type: message.type, eventID: message.eventID, reason: "out_of_order"))
            return
        }

        processNewMessage(message)
    }

    func handleWakeCompleted(eventID: String, success: Bool) {
        guard coordinationEnabled, let purpose = pendingWakeByEventID.removeValue(forKey: eventID) else { return }
        wakeSucceededByEventID[eventID] = success

        switch purpose {
        case .incomingReady:
            if let incomingEventID, incomingEventID == eventID {
                if usbPresent {
                    sendUsbReadyBurst(eventID: eventID, wakeSucceeded: success)
                } else {
                    shouldSendIncomingReadyAfterUsbArrival = true
                }
            }
        case .usbPresence:
            sendUsbPresentBurst(eventID: eventID, wakeSucceeded: success)
            if shouldSendIncomingReadyAfterUsbArrival, let incomingEventID {
                sendUsbReadyBurst(eventID: incomingEventID, wakeSucceeded: wakeSucceededByEventID[incomingEventID])
                shouldSendIncomingReadyAfterUsbArrival = false
            }
        }
    }

    func handleSwitchCompleted(eventID: String, success: Bool) {
        guard outgoingSwitchEventID == eventID else { return }
        outgoingSwitchEventID = nil
        outgoingEventID = nil
        log(.sendMessage(type: .committed, eventID: eventID, wakeSucceeded: success))
        sink.sendMessage(type: .committed, eventID: eventID, wakeSucceeded: success)
        clearOutgoingTimers()
    }

    private func processNewMessage(_ message: PeerMessage) {
        switch message.type {
        case .statusProbe:
            sendStatusResponse(for: message.eventID)
        case .statusResponse:
            break
        case .handoverRequest:
            newestIncomingRequestTimestamp = message.timestamp
            incomingEventID = message.eventID
            wakeSucceededByEventID[message.eventID] = nil
            shouldSendIncomingReadyAfterUsbArrival = false
            pendingWakeByEventID[message.eventID] = .incomingReady
            log(.requestWake(eventID: message.eventID))
            sink.requestWake(eventID: message.eventID)
        case .usbPresent:
            guard let outgoingEventID else {
                return
            }
            if outgoingEventID == message.eventID {
                completeOutgoingIfNeeded(eventID: outgoingEventID)
            } else {
                completeOutgoingIfNeeded(eventID: outgoingEventID)
            }
        case .usbReady:
            guard outgoingEventID == message.eventID else {
                log(.rejectMessage(type: message.type, eventID: message.eventID, reason: "stale_event"))
                return
            }
            completeOutgoingIfNeeded(eventID: message.eventID)
        case .committed:
            guard incomingEventID == message.eventID else { return }
            incomingEventID = nil
            pendingWakeByEventID.removeValue(forKey: message.eventID)
            wakeSucceededByEventID.removeValue(forKey: message.eventID)
            shouldSendIncomingReadyAfterUsbArrival = false
            newestIncomingRequestTimestamp = message.timestamp
        case .unknown:
            break
        }
    }

    private func sendStatusResponse(for eventID: String) {
        log(.sendMessage(type: .statusResponse, eventID: eventID, wakeSucceeded: nil))
        sink.sendMessage(type: .statusResponse, eventID: eventID, wakeSucceeded: nil)
    }

    private func sendUsbReadyBurst(eventID: String, wakeSucceeded: Bool?) {
        log(.sendBurst(type: .usbReady, count: Self.messageBurstCount, eventID: eventID, wakeSucceeded: wakeSucceeded))
        sink.sendBurst(type: .usbReady, count: Self.messageBurstCount, eventID: eventID, wakeSucceeded: wakeSucceeded)
    }

    private func sendUsbPresentBurst(eventID: String, wakeSucceeded: Bool?) {
        log(.sendBurst(type: .usbPresent, count: Self.messageBurstCount, eventID: eventID, wakeSucceeded: wakeSucceeded))
        sink.sendBurst(type: .usbPresent, count: Self.messageBurstCount, eventID: eventID, wakeSucceeded: wakeSucceeded)
    }

    private func beginOutgoingHandover() {
        guard coordinationEnabled && usbAutomationEnabled && !usbPresent else { return }
        if let existing = outgoingEventID {
            cancelOutgoing(emitAction: false)
            _ = existing
        }

        let eventID = eventIDSource.nextEventID()
        outgoingEventID = eventID
        outgoingSwitchEventID = nil

        if !peerReachable {
            sendHandoverRequest(eventID: eventID)
            requestSwitch(eventID: eventID)
            return
        }

        for index in 0..<Self.handoverRetryCount {
            let delay = Int64(index) * Self.handoverRetryMs
            let key = "outgoing-\(eventID)-retry-\(index)"
            outgoingTimers.insert(key)
            scheduledTimerKeys.insert(key)
            scheduler.schedule(key, after: delay) { [weak self] in
                self?.sendHandoverRequest(eventID: eventID)
            }
        }
        let fallbackKey = "outgoing-\(eventID)-fallback"
        outgoingTimers.insert(fallbackKey)
        scheduledTimerKeys.insert(fallbackKey)
        scheduler.schedule(fallbackKey, after: Self.handoverFallbackMs) { [weak self] in
            self?.checkFallbackSwitch(eventID: eventID)
        }
    }

    private func sendHandoverRequest(eventID: String) {
        guard outgoingEventID == eventID, outgoingSwitchEventID == nil else { return }
        log(.sendMessage(type: .handoverRequest, eventID: eventID, wakeSucceeded: nil))
        sink.sendMessage(type: .handoverRequest, eventID: eventID, wakeSucceeded: nil)
    }

    private func checkFallbackSwitch(eventID: String) {
        guard outgoingEventID == eventID else { return }
        requestSwitch(eventID: eventID)
    }

    private func requestSwitch(eventID: String) {
        guard outgoingEventID == eventID else { return }
        if outgoingSwitchEventID == nil {
            outgoingSwitchEventID = eventID
            log(.requestSwitch(eventID: eventID))
            sink.requestSwitch(eventID: eventID)
        }
    }

    private func completeOutgoingIfNeeded(eventID: String) {
        guard outgoingEventID == eventID else { return }
        clearOutgoingTimers()
        requestSwitch(eventID: eventID)
    }

    private func cancelOutgoing(emitAction: Bool = false) {
        guard let eventID = outgoingEventID else { return }
        clearOutgoingTimers()
        outgoingEventID = nil
        outgoingSwitchEventID = nil
        if emitAction {
            log(.cancelOutgoing(eventID: eventID))
        }
    }

    private func clearOutgoingTimers() {
        for key in outgoingTimers {
            scheduler.cancel(key)
            scheduledTimerKeys.remove(key)
        }
        outgoingTimers.removeAll()
    }

    private func markPeerReachable(nowMs: Int64) {
        peerReachable = true
        peerLastSeenAtMs = nowMs
        log(.setPeerReachable(true))
        sink.updatePeerReachable(true)
        schedulePeerReachableExpiry(atMs: nowMs)
    }

    private func schedulePeerReachableExpiry(atMs: Int64) {
        scheduler.cancel(peerHealthTimerKey)
        scheduledTimerKeys.remove(peerHealthTimerKey)
        scheduledTimerKeys.insert(peerHealthTimerKey)
        scheduler.schedule(peerHealthTimerKey, after: Self.peerReachableWindowMs + 1) { [weak self] in
            guard let self else { return }
            self.checkPeerReachability(nowMs: self.clock.currentTimeMs())
            self.scheduledTimerKeys.remove(self.peerHealthTimerKey)
        }
    }

    private func checkPeerReachability(nowMs: Int64) {
        guard peerReachable, let lastSeen = peerLastSeenAtMs else { return }
        if nowMs - lastSeen > Self.peerReachableWindowMs {
            peerReachable = false
            log(.setPeerReachable(false))
            sink.updatePeerReachable(false)
        }
    }

    private func log(_ action: HandoffAction) {
        actionLog?(action)
    }
}
