import Foundation

protocol HandoffScheduler {
    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void)
    func cancel(_ key: String)
}

protocol HandoffEventIDSource {
    func nextEventID() -> String
}

enum V2PeerCapability: String, Codable {
    case v2
}

struct V2HandoffTarget: Equatable {
    let endpointID: String
    let capability: V2PeerCapability
    var reachable: Bool
}

enum V2HandoffState: String, Codable {
    case idle
    case awaitingReady = "awaiting_ready"
    case awaitingCommit = "awaiting_commit"
    case switching
    case completed
    case cancelled
}

enum V2HandoffIgnoreReason: String {
    case duplicate
    case authenticationFailed = "authentication_failed"
    case endpointChanged = "endpoint_changed"
    case noPendingEvent = "no_pending_event"
    case configurationChanged = "configuration_changed"
}

enum V2HandoffAction: Equatable {
    case sendMessage(
        type: V2MessageType,
        eventID: String,
        endpointID: String,
        intent: V2HandoverIntent? = nil,
        wakeSucceeded: Bool? = nil,
        switchSucceeded: Bool? = nil,
        reason: V2CancellationReason? = nil
    )
    case requestWake(eventID: String)
    case requestSwitch(eventID: String, endpointID: String)
    case lockTarget(endpointID: String)
    case ignoreMessage(reason: V2HandoffIgnoreReason, eventID: String?, endpointID: String?)
    case clearEvent(reason: V2HandoffIgnoreReason?)
    case setPeerReachable(Bool)
}

protocol V2HandoffActionSink: AnyObject {
    func sendV2Message(
        type: V2MessageType,
        eventID: String,
        endpointID: String,
        intent: V2HandoverIntent?,
        wakeSucceeded: Bool?,
        switchSucceeded: Bool?,
        reason: V2CancellationReason?
    )
    func requestV2Wake(eventID: String, completionRequired: Bool)
    func requestV2Switch(eventID: String, endpointID: String)
    func updateV2PeerReachable(_ reachable: Bool, endpointID: String)
}

struct V2HandoffSnapshot {
    let coordinationEnabled: Bool
    let state: V2HandoffState
    let activeEventID: String?
    let lockedTargetEndpointID: String?
}

final class HandoffV2StateMachine {
    private static let retryMs: Int64 = 150
    private static let fallbackMs: Int64 = 600
    private static let retryCount = 4

    private let sink: V2HandoffActionSink
    private let scheduler: HandoffScheduler
    private let eventIDSource: HandoffEventIDSource
    private let actionLog: ((V2HandoffAction) -> Void)?

    private(set) var localEndpointID: String
    private(set) var coordinationEnabled = false
    private(set) var state: V2HandoffState = .idle
    private(set) var activeEventID: String?
    private(set) var lockedTargetEndpointID: String?
    private(set) var enabledTargets: [V2HandoffTarget] = []

    private var activeIntent: V2HandoverIntent?
    private var wakeResult: Bool?
    private var switchRequested = false
    private var seenMessages = Set<String>()
    private var timerKeys = Set<String>()

    init(
        localEndpointID: String,
        sink: V2HandoffActionSink,
        scheduler: HandoffScheduler,
        eventIDSource: HandoffEventIDSource,
        actionLog: ((V2HandoffAction) -> Void)? = nil
    ) {
        self.localEndpointID = localEndpointID.lowercased()
        self.sink = sink
        self.scheduler = scheduler
        self.eventIDSource = eventIDSource
        self.actionLog = actionLog
    }

    func configure(
        localEndpointID: String,
        coordinationEnabled: Bool,
        state: V2HandoffState = .idle,
        activeEventID: String? = nil,
        lockedTargetEndpointID: String? = nil,
        enabledTargets: [V2HandoffTarget]
    ) {
        cancelAllTimers()
        self.localEndpointID = localEndpointID.lowercased()
        self.coordinationEnabled = coordinationEnabled
        self.state = state
        self.activeEventID = activeEventID?.lowercased()
        self.lockedTargetEndpointID = lockedTargetEndpointID?.lowercased()
        self.enabledTargets = enabledTargets.map {
            V2HandoffTarget(endpointID: $0.endpointID.lowercased(), capability: $0.capability, reachable: $0.reachable)
        }
        activeIntent = nil
        wakeResult = nil
        switchRequested = state == .switching
        seenMessages.removeAll(keepingCapacity: true)
    }

    func snapshot() -> V2HandoffSnapshot {
        V2HandoffSnapshot(
            coordinationEnabled: coordinationEnabled,
            state: state,
            activeEventID: activeEventID,
            lockedTargetEndpointID: lockedTargetEndpointID
        )
    }

    func handleStatusProbe(endpointID: String, eventID: String, authenticated: Bool) {
        guard coordinationEnabled else { return }
        guard authenticated else {
            ignore(.authenticationFailed, eventID: eventID, endpointID: endpointID)
            return
        }
        markReachable(endpointID)
        log(.setPeerReachable(true))
        sink.updateV2PeerReachable(true, endpointID: endpointID)
        send(type: .statusResponse, eventID: eventID, endpointID: endpointID)
    }

    func handleStatusResponse(endpointID: String, authenticated: Bool) {
        guard coordinationEnabled, authenticated, target(endpointID)?.capability == .v2 else { return }
        markReachable(endpointID)
        log(.setPeerReachable(true))
        sink.updateV2PeerReachable(true, endpointID: endpointID)
    }

    func setTargetReachable(_ reachable: Bool, endpointID: String) {
        guard let index = enabledTargets.firstIndex(where: {
            $0.endpointID.caseInsensitiveCompare(endpointID) == .orderedSame
        }) else { return }
        enabledTargets[index].reachable = reachable
    }

    func handleManualSelect(endpointID: String, eventID: String) {
        guard coordinationEnabled,
              let target = target(endpointID), target.capability == .v2 else { return }
        clearInternalEvent(finalState: .idle)
        activeEventID = eventID.lowercased()
        activeIntent = .manual
        lock(endpointID)
        beginDirectedRequest(target: target, eventID: eventID, intent: .manual)
    }

    func handleWakeDisplay(endpointID: String, eventID: String, authenticated: Bool) {
        guard coordinationEnabled else { return }
        guard authenticated else {
            ignore(.authenticationFailed, eventID: eventID, endpointID: endpointID)
            return
        }
        guard target(endpointID)?.capability == .v2 else {
            ignore(.endpointChanged, eventID: eventID, endpointID: endpointID)
            return
        }
        let key = replayKey(type: .wakeDisplay, eventID: eventID, endpointID: endpointID)
        guard seenMessages.insert(key).inserted else {
            ignore(.duplicate, eventID: eventID, endpointID: nil)
            return
        }
        log(.requestWake(eventID: eventID.lowercased()))
        sink.requestV2Wake(eventID: eventID.lowercased(), completionRequired: false)
    }

    func handleHandoverRequest(
        endpointID: String,
        eventID: String,
        authenticated: Bool,
        intent: V2HandoverIntent
    ) {
        guard coordinationEnabled else { return }
        guard authenticated else {
            ignore(.authenticationFailed, eventID: eventID, endpointID: endpointID)
            return
        }
        guard target(endpointID)?.capability == .v2 else {
            ignore(.endpointChanged, eventID: eventID, endpointID: endpointID)
            return
        }
        let key = replayKey(type: .handoverRequest, eventID: eventID, endpointID: endpointID)
        guard seenMessages.insert(key).inserted else {
            ignore(.duplicate, eventID: eventID, endpointID: nil)
            return
        }

        clearInternalEvent(finalState: .awaitingReady, keepSeen: true)
        activeEventID = eventID.lowercased()
        lockedTargetEndpointID = endpointID.lowercased()
        activeIntent = intent
        wakeResult = nil
        log(.requestWake(eventID: eventID.lowercased()))
        sink.requestV2Wake(eventID: eventID.lowercased(), completionRequired: true)
    }

    func handleTargetReady(
        endpointID: String,
        eventID: String,
        authenticated: Bool,
        wakeSucceeded: Bool
    ) {
        guard coordinationEnabled else { return }
        guard authenticated else {
            ignore(.authenticationFailed, eventID: eventID, endpointID: endpointID)
            return
        }
        let key = replayKey(type: .targetReady, eventID: eventID, endpointID: endpointID)
        guard seenMessages.insert(key).inserted else {
            ignore(.duplicate, eventID: eventID, endpointID: nil)
            return
        }
        guard activeEventID == eventID.lowercased(), lockedTargetEndpointID == endpointID.lowercased() else {
            ignore(.noPendingEvent, eventID: eventID, endpointID: nil)
            return
        }
        cancelDirectedTimers(eventID: eventID)
        requestSwitchIfNeeded(eventID: eventID, endpointID: endpointID)
    }

    func handleWakeCompleted(eventID: String, success: Bool) {
        guard coordinationEnabled, activeEventID == eventID.lowercased(), activeIntent != nil else { return }
        wakeResult = success
        sendReadyIfPossible()
    }

    func handleSwitchCompleted(eventID: String, success: Bool) {
        guard coordinationEnabled, state == .switching,
              activeEventID == eventID.lowercased(), let endpointID = lockedTargetEndpointID else { return }
        send(type: .committed, eventID: eventID, endpointID: endpointID, switchSucceeded: success)
        clearEvent(reason: nil, finalState: .completed)
    }

    func handleCommitted(
        endpointID: String,
        eventID: String,
        authenticated: Bool,
        switchSucceeded: Bool
    ) {
        guard coordinationEnabled else { return }
        guard authenticated else {
            ignore(.authenticationFailed, eventID: eventID, endpointID: endpointID)
            return
        }
        let key = replayKey(type: .committed, eventID: eventID, endpointID: endpointID)
        guard seenMessages.insert(key).inserted else {
            ignore(.duplicate, eventID: eventID, endpointID: nil)
            return
        }
        guard activeEventID == eventID.lowercased(), lockedTargetEndpointID == endpointID.lowercased() else {
            ignore(.noPendingEvent, eventID: eventID, endpointID: nil)
            return
        }
        _ = switchSucceeded
        clearEvent(reason: nil, finalState: .completed)
    }

    func handleCancelled(endpointID: String, eventID: String, authenticated: Bool) {
        guard coordinationEnabled, authenticated,
              activeEventID == eventID.lowercased(), lockedTargetEndpointID == endpointID.lowercased() else { return }
        clearEvent(reason: nil, finalState: .cancelled)
    }

    func handleConfigurationChanged(enabledTargets: [V2HandoffTarget]? = nil, coordinationEnabled: Bool? = nil) {
        if let enabledTargets {
            self.enabledTargets = enabledTargets.map {
                V2HandoffTarget(endpointID: $0.endpointID.lowercased(), capability: $0.capability, reachable: $0.reachable)
            }
        }
        if let coordinationEnabled { self.coordinationEnabled = coordinationEnabled }
        if activeEventID != nil {
            clearEvent(reason: .configurationChanged, finalState: .cancelled)
        }
        if self.coordinationEnabled == false { clearInternalEvent(finalState: .cancelled) }
    }

    func handleAdvanceTime() {}

    private func beginDirectedRequest(target: V2HandoffTarget, eventID: String, intent: V2HandoverIntent) {
        state = .awaitingReady
        send(type: .handoverRequest, eventID: eventID, endpointID: target.endpointID, intent: intent)
        guard target.reachable else {
            requestSwitchIfNeeded(eventID: eventID, endpointID: target.endpointID)
            return
        }
        for attempt in 1..<Self.retryCount {
            schedule("v2-\(eventID.lowercased())-retry-\(attempt)", after: Int64(attempt) * Self.retryMs) { [weak self] in
                guard let self, self.activeEventID == eventID.lowercased(), self.state == .awaitingReady else { return }
                self.send(type: .handoverRequest, eventID: eventID, endpointID: target.endpointID, intent: intent)
            }
        }
        schedule("v2-\(eventID.lowercased())-fallback", after: Self.fallbackMs) { [weak self] in
            guard let self, self.activeEventID == eventID.lowercased(), self.state == .awaitingReady else { return }
            self.requestSwitchIfNeeded(eventID: eventID, endpointID: target.endpointID)
        }
    }

    private func sendReadyIfPossible() {
        guard let eventID = activeEventID, let endpointID = lockedTargetEndpointID,
              let wakeResult, activeIntent != nil else { return }
        send(type: .targetReady, eventID: eventID, endpointID: endpointID, wakeSucceeded: wakeResult)
        state = .awaitingCommit
    }

    private func requestSwitchIfNeeded(eventID: String, endpointID: String) {
        guard !switchRequested else { return }
        switchRequested = true
        state = .switching
        log(.requestSwitch(eventID: eventID.lowercased(), endpointID: endpointID.lowercased()))
        sink.requestV2Switch(eventID: eventID.lowercased(), endpointID: endpointID.lowercased())
    }

    private func lock(_ endpointID: String) {
        lockedTargetEndpointID = endpointID.lowercased()
        log(.lockTarget(endpointID: endpointID.lowercased()))
    }

    private func send(
        type: V2MessageType,
        eventID: String,
        endpointID: String,
        intent: V2HandoverIntent? = nil,
        wakeSucceeded: Bool? = nil,
        switchSucceeded: Bool? = nil,
        reason: V2CancellationReason? = nil
    ) {
        let action = V2HandoffAction.sendMessage(
            type: type,
            eventID: eventID.lowercased(),
            endpointID: endpointID.lowercased(),
            intent: intent,
            wakeSucceeded: wakeSucceeded,
            switchSucceeded: switchSucceeded,
            reason: reason
        )
        log(action)
        sink.sendV2Message(
            type: type,
            eventID: eventID.lowercased(),
            endpointID: endpointID.lowercased(),
            intent: intent,
            wakeSucceeded: wakeSucceeded,
            switchSucceeded: switchSucceeded,
            reason: reason
        )
    }

    private func target(_ endpointID: String) -> V2HandoffTarget? {
        enabledTargets.first { $0.endpointID.caseInsensitiveCompare(endpointID) == .orderedSame }
    }

    private func markReachable(_ endpointID: String) {
        guard let index = enabledTargets.firstIndex(where: {
            $0.endpointID.caseInsensitiveCompare(endpointID) == .orderedSame
        }) else { return }
        enabledTargets[index].reachable = true
    }

    private func replayKey(type: V2MessageType, eventID: String, endpointID: String) -> String {
        "\(type.rawValue):\(eventID.lowercased()):\(endpointID.lowercased())"
    }

    private func ignore(_ reason: V2HandoffIgnoreReason, eventID: String?, endpointID: String?) {
        log(.ignoreMessage(
            reason: reason,
            eventID: eventID?.lowercased(),
            endpointID: endpointID?.lowercased()
        ))
    }

    private func clearEvent(reason: V2HandoffIgnoreReason?, finalState: V2HandoffState) {
        log(.clearEvent(reason: reason))
        clearInternalEvent(finalState: finalState, keepSeen: true)
    }

    private func clearInternalEvent(finalState: V2HandoffState, keepSeen: Bool = false) {
        cancelAllTimers()
        activeEventID = nil
        lockedTargetEndpointID = nil
        activeIntent = nil
        wakeResult = nil
        switchRequested = false
        state = finalState
        if !keepSeen { seenMessages.removeAll(keepingCapacity: true) }
    }

    private func cancelDirectedTimers(eventID: String) {
        let prefix = "v2-\(eventID.lowercased())-"
        let matchingKeys = timerKeys.filter { $0.hasPrefix(prefix) }
        for key in matchingKeys {
            scheduler.cancel(key)
            timerKeys.remove(key)
        }
    }

    private func cancelAllTimers() {
        for key in timerKeys { scheduler.cancel(key) }
        timerKeys.removeAll()
    }

    private func schedule(_ key: String, after delayMs: Int64, action: @escaping () -> Void) {
        timerKeys.insert(key)
        scheduler.schedule(key, after: delayMs, action)
    }

    private func log(_ action: V2HandoffAction) { actionLog?(action) }
}
