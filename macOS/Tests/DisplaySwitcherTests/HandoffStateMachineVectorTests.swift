import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DisplaySwitcher
#endif

private struct VectorFile: Decodable {
    let vectors: [StateMachineVector]
    let configuredPairingCode: String
    let referenceTime: TimeInterval
}

private struct VectorHardwareCalls: Decodable, Equatable {
    let wake: Int
    let switchDisplay: Int
    let usbActions: Int
}

private struct StateMachineVector: Decodable {
    let id: String
    let description: String
    let initialState: InitialState
    let steps: [Step]
    let expectedActions: [ExpectedAction]
    let expectedHardwareCalls: VectorHardwareCalls
    let finalState: FinalState
}

private struct InitialState: Decodable {
    let localPlatform: String
    let coordinationEnabled: Bool
    let usbAutomationEnabled: Bool
    let usbPresent: Bool
    let peerReachable: Bool
    let peerLastSeenAtMs: Int?
    let incomingEventID: String?
    let outgoingEventID: String?
    let newestIncomingRequestTimestamp: TimeInterval?
    let seenMessages: [SeenMessage]
    let nextEventIDs: [String]
}

private struct SeenMessage: Decodable {
    let type: String
    let eventID: String
    let seenAtMs: Int
}

private struct FinalState: Decodable {
    let coordinationEnabled: Bool
    let usbPresent: Bool
    let peerReachable: Bool
    let peerLastSeenAtMs: Int?
    let incomingEventID: String?
    let outgoingEventID: String?
    let newestIncomingRequestTimestamp: TimeInterval?
    let seenMessageCount: Int?
}

private struct Step: Decodable {
    let atMs: Int
    let input: StepInput
}

private enum StepInput: Decodable {
    case usbPresenceChanged(present: Bool)
    case receiveMessage(message: PeerMessage)
    case wakeCompleted(eventID: String, success: Bool)
    case switchCompleted(eventID: String, success: Bool)
    case coordinationChanged(enabled: Bool)
    case advanceTime

    enum CodingKeys: String, CodingKey {
        case kind
        case present
        case message
        case eventID
        case success
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "usbPresenceChanged":
            self = .usbPresenceChanged(present: try container.decode(Bool.self, forKey: .present))
        case "receiveMessage":
            self = .receiveMessage(message: try container.decode(PeerMessage.self, forKey: .message))
        case "wakeCompleted":
            self = .wakeCompleted(
                eventID: try container.decode(String.self, forKey: .eventID),
                success: try container.decode(Bool.self, forKey: .success)
            )
        case "switchCompleted":
            self = .switchCompleted(
                eventID: try container.decode(String.self, forKey: .eventID),
                success: try container.decode(Bool.self, forKey: .success)
            )
        case "coordinationChanged":
            self = .coordinationChanged(enabled: try container.decode(Bool.self, forKey: .enabled))
        case "advanceTime":
            self = .advanceTime
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported step input kind: \(kind)"
            )
        }
    }
}

private struct ExpectedAction: Decodable {
    let atMs: Int
    let kind: String
    let type: String?
    let eventID: String?
    let reason: String?
    let value: Bool?
    let count: Int?
    let wakeSucceeded: Bool?
}

private struct TimedAction: Equatable {
    let atMs: Int
    let kind: String
    let type: String?
    let eventID: String?
    let reason: String?
    let value: Bool?
    let count: Int?
    let wakeSucceeded: Bool?
}

private struct VectorHardwareCounter {
    var wake = 0
    var switchDisplay = 0
    var usbActions = 0
}

private final class VectorStateMachineRecorder {
    let clock: VirtualClock
    var actions: [TimedAction] = []
    var hardware = VectorHardwareCounter()
    var networkSends = 0

    init(clock: VirtualClock) {
        self.clock = clock
    }

    func recordHardware(_ kind: HandoffStateMachineTestSink.RecordedEvent) {
        switch kind {
        case .sendMessage:
            networkSends += 1
        case .sendBurst(let count):
            networkSends += count
        case .requestWake:
            hardware.wake += 1
        case .requestSwitch:
            hardware.switchDisplay += 1
        default:
            break
        }
    }

    func recordAction(_ action: HandoffAction) {
        actions.append(
            actionToTimedAction(action, atMs: Int(clock.currentRelativeTimeMs()))
        )
    }
}

private final class VirtualClock: HandoffClock {
    private let referenceTimeMs: Int64
    private(set) var nowMs: Int64 = 0

    init(referenceTime: TimeInterval) {
        referenceTimeMs = Int64((referenceTime * 1_000).rounded())
    }

    func currentTimeMs() -> Int64 {
        referenceTimeMs + nowMs
    }

    func currentRelativeTimeMs() -> Int64 {
        nowMs
    }

    func absoluteTimeMs(forRelativeTimeMs value: Int64) -> Int64 {
        referenceTimeMs + value
    }

    func relativeTimeMs(forAbsoluteTimeMs value: Int64) -> Int64 {
        value - referenceTimeMs
    }

    func advance(to ms: Int64) {
        nowMs = ms
    }
}

private final class VirtualEventIDSource: HandoffEventIDSource {
    private var queue: [String]
    private var fallback = 0

    init(queue: [String]) {
        self.queue = queue
    }

    func nextEventID() -> String {
        guard !queue.isEmpty else {
            fallback += 1
            return "00000000-0000-4000-8000-" + String(format: "%012d", fallback)
        }
        return queue.removeFirst()
    }
}

private struct VirtualTask {
    let key: String
    let dueMs: Int64
    let order: Int
    let action: () -> Void
}

private final class VirtualScheduler: HandoffScheduler {
    private let clock: VirtualClock
    private var tasks: [String: VirtualTask] = [:]
    private var orderCounter = 0

    init(clock: VirtualClock) {
        self.clock = clock
    }

    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void) {
        let dueMs = max(0, clock.currentRelativeTimeMs() + max(0, delayMs))
        orderCounter += 1
        tasks[key] = VirtualTask(
            key: key,
            dueMs: dueMs,
            order: orderCounter,
            action: action
        )
    }

    func cancel(_ key: String) {
        tasks.removeValue(forKey: key)
    }

    func runPending(until timeMs: Int64, includeEqual: Bool) {
        while true {
            let candidates = tasks.values.filter { includeEqual ? $0.dueMs <= timeMs : $0.dueMs < timeMs }
            guard let next = candidates.min(by: { lhs, rhs in
                if lhs.dueMs != rhs.dueMs {
                    return lhs.dueMs < rhs.dueMs
                }
                return lhs.order < rhs.order
            }) else {
                return
            }

            tasks.removeValue(forKey: next.key)
            clock.advance(to: next.dueMs)
            next.action()
        }
    }
}

private final class VectorStateMachineHarness {
    private let clock: VirtualClock
    private let scheduler: VirtualScheduler
    private let eventIDSource: VirtualEventIDSource
    private let recorder: VectorStateMachineRecorder
    private let stateMachine: HandoffStateMachine
    var actions: [TimedAction] { recorder.actions }
    var hardware: VectorHardwareCounter { recorder.hardware }
    var networkSends: Int { recorder.networkSends }

    init(initialState: InitialState, configuredPairingCode: String, referenceTime: TimeInterval) {
        clock = VirtualClock(referenceTime: referenceTime)
        scheduler = VirtualScheduler(clock: clock)
        eventIDSource = VirtualEventIDSource(queue: initialState.nextEventIDs)
        recorder = VectorStateMachineRecorder(clock: clock)

        let sink = HandoffStateMachineTestSink { [recorder] kind, _, _, _, _ in
            recorder.recordHardware(kind)
        }

        stateMachine = HandoffStateMachine(
            localPlatform: initialState.localPlatform == "mac" ? .mac : .windows,
            sink: sink,
            clock: clock,
            scheduler: scheduler,
            eventIDSource: eventIDSource,
            actionLog: { [recorder] action in
                recorder.recordAction(action)
            }
        )

        stateMachine.configure(
            coordinationEnabled: initialState.coordinationEnabled,
            usbAutomationEnabled: initialState.usbAutomationEnabled,
            usbPresent: initialState.usbPresent,
            peerReachable: initialState.peerReachable,
            peerLastSeenAtMs: initialState.peerLastSeenAtMs.map {
                clock.absoluteTimeMs(forRelativeTimeMs: Int64($0))
            },
            incomingEventID: initialState.incomingEventID,
            outgoingEventID: initialState.outgoingEventID,
            newestIncomingRequestTimestamp: initialState.newestIncomingRequestTimestamp,
            seenMessages: initialState.seenMessages.map { seen in
                (
                    type: seen.type,
                    eventID: seen.eventID,
                    seenAtMs: clock.absoluteTimeMs(forRelativeTimeMs: Int64(seen.seenAtMs))
                )
            },
            pairingCode: configuredPairingCode
        )
    }

    func run(_ vector: StateMachineVector) {
        for step in vector.steps.sorted(by: { $0.atMs < $1.atMs }) {
            scheduler.runPending(until: Int64(step.atMs), includeEqual: false)
            clock.advance(to: Int64(step.atMs))

            switch step.input {
            case .usbPresenceChanged(let present):
                stateMachine.handleUSBPresenceChanged(present)
            case .receiveMessage(let message):
                stateMachine.handleIncomingMessage(message)
            case .wakeCompleted(let eventID, let success):
                stateMachine.handleWakeCompleted(eventID: eventID, success: success)
            case .switchCompleted(let eventID, let success):
                stateMachine.handleSwitchCompleted(eventID: eventID, success: success)
            case .coordinationChanged(let enabled):
                stateMachine.setCoordinationEnabled(enabled)
            case .advanceTime:
                stateMachine.handleAdvanceTime(to: clock.currentTimeMs())
            }

            scheduler.runPending(until: Int64(step.atMs), includeEqual: true)
        }
    }

    func receive(_ message: PeerMessage) {
        stateMachine.handleIncomingMessage(message)
    }

    func snapshot() -> HandoffStateSnapshot {
        let snapshot = stateMachine.snapshot()
        return HandoffStateSnapshot(
            localPlatform: snapshot.localPlatform,
            coordinationEnabled: snapshot.coordinationEnabled,
            usbAutomationEnabled: snapshot.usbAutomationEnabled,
            usbPresent: snapshot.usbPresent,
            peerReachable: snapshot.peerReachable,
            peerLastSeenAtMs: snapshot.peerLastSeenAtMs.map(clock.relativeTimeMs(forAbsoluteTimeMs:)),
            incomingEventID: snapshot.incomingEventID,
            outgoingEventID: snapshot.outgoingEventID,
            newestIncomingRequestTimestamp: snapshot.newestIncomingRequestTimestamp,
            seenMessageCount: snapshot.seenMessageCount
        )
    }

    func expectedTimedActions(_ vector: StateMachineVector) -> [TimedAction] {
        vector.expectedActions.map { action in
            TimedAction(
                atMs: action.atMs,
                kind: action.kind,
                type: action.type,
                eventID: action.eventID,
                reason: action.reason,
                value: action.value,
                count: action.count,
                wakeSucceeded: action.wakeSucceeded
            )
        }
    }

    func expectedHardwareCalls(_ vector: StateMachineVector) -> VectorHardwareCalls {
        vector.expectedHardwareCalls
    }
}

private final class HandoffStateMachineTestSink: HandoffActionSink {
    enum RecordedEvent {
        case sendMessage
        case sendBurst(Int)
        case requestWake
        case requestSwitch
        case requestNone
    }

    private let hardwareRecorder: (RecordedEvent, PeerMessageType, String?, Bool?, Int?) -> Void

    init(onHardware: @escaping (RecordedEvent, PeerMessageType, String?, Bool?, Int?) -> Void) {
        hardwareRecorder = onHardware
    }

    func sendMessage(type: PeerMessageType, eventID: String, wakeSucceeded: Bool?) {
        hardwareRecorder(.sendMessage, type, eventID, wakeSucceeded, nil)
    }

    func sendBurst(type: PeerMessageType, count: Int, eventID: String, wakeSucceeded: Bool?) {
        hardwareRecorder(.sendBurst(count), type, eventID, wakeSucceeded, count)
    }

    func requestWake(eventID: String) {
        hardwareRecorder(.requestWake, .handoverRequest, eventID, nil, nil)
    }

    func requestSwitch(eventID: String) {
        hardwareRecorder(.requestSwitch, .handoverRequest, eventID, nil, nil)
    }

    func updatePeerReachable(_ reachable: Bool) {}
}

private func actionToTimedAction(_ action: HandoffAction, atMs: Int) -> TimedAction {
    switch action {
    case .acceptMessage(let type, let eventID):
        return TimedAction(atMs: atMs, kind: "acceptMessage", type: type.rawValue, eventID: eventID, reason: nil, value: nil, count: nil, wakeSucceeded: nil)
    case .rejectMessage(let type, let eventID, let reason):
        return TimedAction(atMs: atMs, kind: "rejectMessage", type: type.rawValue, eventID: eventID, reason: reason, value: nil, count: nil, wakeSucceeded: nil)
    case .sendMessage(let type, let eventID, let wakeSucceeded):
        return TimedAction(atMs: atMs, kind: "sendMessage", type: type.rawValue, eventID: eventID, reason: nil, value: nil, count: nil, wakeSucceeded: wakeSucceeded)
    case .sendBurst(let type, let count, let eventID, let wakeSucceeded):
        return TimedAction(atMs: atMs, kind: "sendBurst", type: type.rawValue, eventID: eventID, reason: nil, value: nil, count: count, wakeSucceeded: wakeSucceeded)
    case .requestWake(let eventID):
        return TimedAction(atMs: atMs, kind: "requestWake", type: nil, eventID: eventID, reason: nil, value: nil, count: nil, wakeSucceeded: nil)
    case .requestSwitch(let eventID):
        return TimedAction(atMs: atMs, kind: "requestSwitch", type: nil, eventID: eventID, reason: nil, value: nil, count: nil, wakeSucceeded: nil)
    case .setPeerReachable(let value):
        return TimedAction(atMs: atMs, kind: "setPeerReachable", type: nil, eventID: nil, reason: nil, value: value, count: nil, wakeSucceeded: nil)
    case .cancelOutgoing(let eventID):
        return TimedAction(atMs: atMs, kind: "cancelOutgoing", type: nil, eventID: eventID, reason: nil, value: nil, count: nil, wakeSucceeded: nil)
    }
}

private func actionEquals(_ lhs: TimedAction, _ rhs: TimedAction) -> Bool {
    lhs.atMs == rhs.atMs &&
    lhs.kind == rhs.kind &&
    (rhs.type == nil || lhs.type == rhs.type) &&
    (rhs.eventID == nil || lhs.eventID == rhs.eventID) &&
    (rhs.reason == nil || lhs.reason == rhs.reason) &&
    (rhs.value == nil || lhs.value == rhs.value) &&
    (rhs.count == nil || lhs.count == rhs.count) &&
    (rhs.wakeSucceeded == nil || lhs.wakeSucceeded == rhs.wakeSucceeded)
}

private func locateProjectRoot() -> URL {
    var cursor = URL(fileURLWithPath: #filePath)
    while cursor.path != "/" {
        if cursor.lastPathComponent == "DisplaySwitch" {
            return cursor
        }
        cursor = cursor.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

final class HandoffStateMachineVectorTests: XCTestCase {
    private let referenceTime: TimeInterval = 1_788_000_000
    private let validPairingCode = "TEST-CODE-0001"

    func testAllStateMachineVectors() throws {
        let root = locateProjectRoot()
        let fileURL = root.appendingPathComponent("contracts/protocol-v1/state-machine-vectors.json")
        let data = try Data(contentsOf: fileURL)
        let vectors = try JSONDecoder().decode(VectorFile.self, from: data)

        XCTAssertEqual(vectors.vectors.count, 15, "expected 15 state-machine vectors")

        for vector in vectors.vectors {
            let harness = VectorStateMachineHarness(
                initialState: vector.initialState,
                configuredPairingCode: vectors.configuredPairingCode,
                referenceTime: vectors.referenceTime
            )
            harness.run(vector)

            let actual = harness.actions
            let expected = harness.expectedTimedActions(vector)

            if actual.count != expected.count {
                XCTFail("SM vector \(vector.id): action count mismatch. actual \(actual.count), expected \(expected.count)")
            } else {
                for index in 0..<actual.count {
                    XCTAssertTrue(
                        actionEquals(actual[index], expected[index]),
                        "SM vector \(vector.id) mismatch at index \(index). expected \(expected[index]), actual \(actual[index])"
                    )
                }
            }

            XCTAssertEqual(
                VectorHardwareCalls(
                    wake: harness.hardware.wake,
                    switchDisplay: harness.hardware.switchDisplay,
                    usbActions: harness.hardware.usbActions
                ),
                harness.expectedHardwareCalls(vector),
                "SM vector \(vector.id) hardware counts mismatch"
            )

            let finalState = harness.snapshot()
            XCTAssertEqual(finalState.coordinationEnabled, vector.finalState.coordinationEnabled)
            XCTAssertEqual(finalState.usbPresent, vector.finalState.usbPresent)
            XCTAssertEqual(finalState.peerReachable, vector.finalState.peerReachable)
            XCTAssertEqual(finalState.peerLastSeenAtMs, vector.finalState.peerLastSeenAtMs.map(Int64.init))
            XCTAssertEqual(finalState.incomingEventID, vector.finalState.incomingEventID)
            XCTAssertEqual(finalState.outgoingEventID, vector.finalState.outgoingEventID)
            if let expectedNewest = vector.finalState.newestIncomingRequestTimestamp {
                XCTAssertEqual(finalState.newestIncomingRequestTimestamp, expectedNewest)
            }
            if let expectedSeenCount = vector.finalState.seenMessageCount {
                XCTAssertEqual(finalState.seenMessageCount, expectedSeenCount)
            }
        }
    }

    func testShortOrEmptyLocalPairingCodeProducesNoSideEffects() {
        for pairingCode in ["", "short"] {
            let harness = makeHarness(pairingCode: pairingCode)
            sendValidHandoverAndStatusMessages(to: harness, pairingCode: pairingCode)
            assertNoReceiveSideEffects(harness)
        }
    }

    func testDisabledCoordinationProducesNoSideEffects() {
        let harness = makeHarness(coordinationEnabled: false)
        sendValidHandoverAndStatusMessages(to: harness, pairingCode: validPairingCode)
        assertNoReceiveSideEffects(harness)
    }

    func testDisabledUSBAutomationProducesNoSideEffects() {
        let harness = makeHarness(usbAutomationEnabled: false)
        sendValidHandoverAndStatusMessages(to: harness, pairingCode: validPairingCode)
        assertNoReceiveSideEffects(harness)
    }

    private func makeHarness(
        pairingCode: String? = nil,
        coordinationEnabled: Bool = true,
        usbAutomationEnabled: Bool = true
    ) -> VectorStateMachineHarness {
        let initialState = InitialState(
            localPlatform: "mac",
            coordinationEnabled: coordinationEnabled,
            usbAutomationEnabled: usbAutomationEnabled,
            usbPresent: false,
            peerReachable: false,
            peerLastSeenAtMs: nil,
            incomingEventID: nil,
            outgoingEventID: nil,
            newestIncomingRequestTimestamp: nil,
            seenMessages: [],
            nextEventIDs: []
        )
        return VectorStateMachineHarness(
            initialState: initialState,
            configuredPairingCode: pairingCode ?? validPairingCode,
            referenceTime: referenceTime
        )
    }

    private func sendValidHandoverAndStatusMessages(
        to harness: VectorStateMachineHarness,
        pairingCode: String
    ) {
        harness.receive(message(
            type: .handoverRequest,
            eventID: "aa000000-0000-4000-8000-000000000001",
            pairingCode: pairingCode
        ))
        harness.receive(message(
            type: .statusProbe,
            eventID: "aa000000-0000-4000-8000-000000000002",
            pairingCode: pairingCode
        ))
    }

    private func message(
        type: PeerMessageType,
        eventID: String,
        pairingCode: String
    ) -> PeerMessage {
        PeerMessage(
            type: type,
            eventID: eventID,
            source: "windows",
            target: "mac",
            timestamp: referenceTime,
            pairingCode: pairingCode
        )
    }

    private func assertNoReceiveSideEffects(
        _ harness: VectorStateMachineHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(harness.actions.isEmpty, file: file, line: line)
        XCTAssertEqual(harness.networkSends, 0, file: file, line: line)
        XCTAssertEqual(harness.hardware.wake, 0, file: file, line: line)
        XCTAssertEqual(harness.hardware.switchDisplay, 0, file: file, line: line)
        XCTAssertEqual(harness.hardware.usbActions, 0, file: file, line: line)

        let snapshot = harness.snapshot()
        XCTAssertFalse(snapshot.peerReachable, file: file, line: line)
        XCTAssertNil(snapshot.peerLastSeenAtMs, file: file, line: line)
        XCTAssertNil(snapshot.incomingEventID, file: file, line: line)
        XCTAssertNil(snapshot.outgoingEventID, file: file, line: line)
        XCTAssertEqual(snapshot.seenMessageCount, 0, file: file, line: line)
    }
}
