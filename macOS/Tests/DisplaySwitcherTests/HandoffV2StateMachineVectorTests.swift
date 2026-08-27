import Foundation
import XCTest

final class HandoffV2StateMachineVectorTests: XCTestCase {
    func testAllTwentyPublicV2StateMachineVectors() throws {
        let url = try XCTUnwrap(Bundle(for: HandoffV2StateMachineVectorTests.self).resourceURL)
            .appendingPathComponent("contracts/protocol-v2/state-machine-vectors.json")
        let file = try JSONDecoder().decode(V2VectorFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.vectors.count, 20)

        for vector in file.vectors {
            let clock = V2VectorClock()
            let scheduler = V2VectorScheduler(clock: clock)
            let sink = V2VectorSink()
            var actions: [V2TimedAction] = []
            let machine = HandoffV2StateMachine(
                localEndpointID: vector.initialState.localEndpointID,
                sink: sink,
                scheduler: scheduler,
                eventIDSource: V2VectorEventIDs(),
                actionLog: { actions.append(V2TimedAction(action: $0, atMs: clock.nowMs)) }
            )
            machine.configure(
                localEndpointID: vector.initialState.localEndpointID,
                coordinationEnabled: vector.initialState.coordinationEnabled,
                sourceInputPresent: vector.initialState.sourceInputPresent,
                targetInputPresent: vector.initialState.targetInputPresent,
                state: try XCTUnwrap(V2HandoffState(rawValue: vector.initialState.state)),
                activeEventID: vector.initialState.activeEventID,
                lockedTargetEndpointID: vector.initialState.lockedTargetEndpointID,
                enabledTargets: try vector.initialState.enabledTargets.map {
                    V2HandoffTarget(
                        endpointID: $0.endpointID,
                        capability: try XCTUnwrap(V2PeerCapability(rawValue: $0.capability)),
                        reachable: $0.reachable
                    )
                }
            )

            for step in vector.steps {
                scheduler.run(until: Int64(step.atMs), includingBoundary: false)
                clock.nowMs = Int64(step.atMs)
                try apply(step.input, to: machine)
                scheduler.run(until: Int64(step.atMs), includingBoundary: true)
            }

            let expected = vector.expectedActions.map(V2TimedAction.init(expected:))
            XCTAssertEqual(actions, expected, "\(vector.id): \(vector.description)")
            XCTAssertEqual(sink.wakeCalls, vector.expectedHardwareCalls.wake, vector.id)
            XCTAssertEqual(sink.switchCalls, vector.expectedHardwareCalls.switchDisplay, vector.id)
            XCTAssertEqual(sink.inputCalls, vector.expectedHardwareCalls.inputActions, vector.id)
            let snapshot = machine.snapshot()
            XCTAssertEqual(snapshot.state.rawValue, vector.finalState.state, vector.id)
            XCTAssertEqual(snapshot.activeEventID, vector.finalState.activeEventID, vector.id)
            XCTAssertEqual(snapshot.lockedTargetEndpointID, vector.finalState.lockedTargetEndpointID, vector.id)
        }
    }

    func testDisabledCoordinationAndLateCallbacksHaveZeroHardwareAndNetworkEffects() {
        let clock = V2VectorClock()
        let scheduler = V2VectorScheduler(clock: clock)
        let sink = V2VectorSink()
        var actions: [V2HandoffAction] = []
        let machine = HandoffV2StateMachine(
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            sink: sink,
            scheduler: scheduler,
            eventIDSource: V2VectorEventIDs(),
            actionLog: { actions.append($0) }
        )
        machine.configure(
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            coordinationEnabled: false,
            sourceInputPresent: true,
            targetInputPresent: false,
            enabledTargets: [V2HandoffTarget(
                endpointID: "22222222-2222-4222-8222-222222222222",
                capability: .v2,
                reachable: true
            )]
        )
        let eventID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        machine.handleManualSelect(endpointID: "22222222-2222-4222-8222-222222222222", eventID: eventID)
        machine.handleSourceInputPresenceChanged(false, eventID: eventID)
        machine.handleTargetInputPresenceChanged(true, eventID: eventID)
        machine.handleHandoverRequest(endpointID: "22222222-2222-4222-8222-222222222222", eventID: eventID, authenticated: true, intent: .manual)
        machine.handleWakeCompleted(eventID: eventID, success: true)
        machine.handleSwitchCompleted(eventID: eventID, success: true)
        scheduler.run(until: 5_000, includingBoundary: true)

        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sink.networkSends, 0)
        XCTAssertEqual(sink.wakeCalls, 0)
        XCTAssertEqual(sink.switchCalls, 0)
        XCTAssertEqual(sink.inputCalls, 0)
    }

    func testLocalInputAdapterRecordsStartupAndDoesNotAnnounceWhenSourceInputReturns() {
        let clock = V2VectorClock()
        let scheduler = V2VectorScheduler(clock: clock)
        let sink = V2VectorSink()
        var actions: [V2HandoffAction] = []
        let machine = HandoffV2StateMachine(
            localEndpointID: "10000000-0000-4000-8000-000000000001",
            sink: sink,
            scheduler: scheduler,
            eventIDSource: V2VectorEventIDs(),
            actionLog: { actions.append($0) }
        )
        machine.configure(
            localEndpointID: "10000000-0000-4000-8000-000000000001",
            coordinationEnabled: true,
            sourceInputPresent: false,
            targetInputPresent: false,
            enabledTargets: [
                V2HandoffTarget(
                    endpointID: "20000000-0000-4000-8000-000000000002",
                    capability: .v2,
                    reachable: true
                )
            ]
        )

        machine.recordInitialLocalInputPresence(true)
        XCTAssertTrue(machine.snapshot().sourceInputPresent)
        XCTAssertTrue(machine.snapshot().targetInputPresent)
        XCTAssertTrue(actions.isEmpty)

        machine.handleLocalInputPresenceChanged(false, eventID: "30000000-0000-4000-8000-000000000003")
        scheduler.run(until: 150, includingBoundary: true)
        machine.handleLocalInputPresenceChanged(true)

        XCTAssertFalse(actions.contains { action in
            if case .sendMessage(type: .inputPresent, eventID: _, endpointID: _, intent: _, wakeSucceeded: _, switchSucceeded: _, reason: _) = action {
                return true
            }
            return false
        })
    }

    private func apply(_ input: V2VectorInput, to machine: HandoffV2StateMachine) throws {
        switch input.kind {
        case "statusProbe":
            machine.handleStatusProbe(endpointID: try input.requiredEndpoint(), eventID: try input.requiredEvent(), authenticated: input.authenticated ?? false)
        case "manualSelect":
            machine.handleManualSelect(endpointID: try input.requiredEndpoint(), eventID: try input.requiredEvent())
        case "sourceInputPresenceChanged":
            machine.handleSourceInputPresenceChanged(try XCTUnwrap(input.present), eventID: input.eventID)
        case "targetInputPresenceChanged":
            machine.handleTargetInputPresenceChanged(try XCTUnwrap(input.present), eventID: input.eventID)
        case "peerInputPresent":
            machine.handlePeerInputPresent(endpointID: try input.requiredEndpoint(), eventID: try input.requiredEvent(), authenticated: input.authenticated ?? false)
        case "receiveHandoverRequest":
            machine.handleHandoverRequest(
                endpointID: try input.requiredEndpoint(),
                eventID: try input.requiredEvent(),
                authenticated: input.authenticated ?? false,
                intent: try XCTUnwrap(input.intent.flatMap(V2HandoverIntent.init(rawValue:)))
            )
        case "receiveTargetReady":
            machine.handleTargetReady(endpointID: try input.requiredEndpoint(), eventID: try input.requiredEvent(), authenticated: input.authenticated ?? false, wakeSucceeded: input.wakeSucceeded ?? false)
        case "receiveCommitted":
            machine.handleCommitted(endpointID: try input.requiredEndpoint(), eventID: try input.requiredEvent(), authenticated: input.authenticated ?? false, switchSucceeded: input.switchSucceeded ?? false)
        case "wakeCompleted":
            machine.handleWakeCompleted(eventID: try input.requiredEvent(), success: input.success ?? false)
        case "switchCompleted":
            machine.handleSwitchCompleted(eventID: try input.requiredEvent(), success: input.success ?? false)
        case "configurationChanged":
            machine.handleConfigurationChanged()
        case "receiveV1Message":
            machine.handleV1Message()
        case "advanceTime":
            machine.handleAdvanceTime()
        default:
            XCTFail("Unsupported v2 vector input: \(input.kind)")
        }
    }
}

private struct V2VectorFile: Decodable { let vectors: [V2StateVector] }
private struct V2StateVector: Decodable {
    let id: String
    let description: String
    let initialState: V2InitialState
    let steps: [V2VectorStep]
    let expectedActions: [V2ExpectedAction]
    let expectedHardwareCalls: V2HardwareCalls
    let finalState: V2FinalState
}
private struct V2InitialState: Decodable {
    let localEndpointID: String
    let coordinationEnabled: Bool
    let sourceInputPresent: Bool
    let targetInputPresent: Bool
    let state: String
    let activeEventID: String?
    let lockedTargetEndpointID: String?
    let enabledTargets: [V2VectorTarget]
}
private struct V2VectorTarget: Decodable { let endpointID: String; let capability: String; let reachable: Bool }
private struct V2VectorStep: Decodable { let atMs: Int; let input: V2VectorInput }
private struct V2VectorInput: Decodable {
    let kind: String
    let endpointID: String?
    let eventID: String?
    let authenticated: Bool?
    let present: Bool?
    let intent: String?
    let wakeSucceeded: Bool?
    let switchSucceeded: Bool?
    let success: Bool?

    func requiredEndpoint() throws -> String { try XCTUnwrap(endpointID) }
    func requiredEvent() throws -> String { try XCTUnwrap(eventID) }
}
private struct V2ExpectedAction: Decodable {
    let atMs: Int
    let kind: String
    let type: String?
    let eventID: String?
    let endpointID: String?
    let reason: String?
    let value: Bool?
    let intent: String?
    let wakeSucceeded: Bool?
    let switchSucceeded: Bool?
}
private struct V2HardwareCalls: Decodable { let wake: Int; let switchDisplay: Int; let inputActions: Int }
private struct V2FinalState: Decodable { let state: String; let activeEventID: String?; let lockedTargetEndpointID: String? }

private struct V2TimedAction: Equatable {
    let atMs: Int
    let kind: String
    let type: String?
    let eventID: String?
    let endpointID: String?
    let reason: String?
    let value: Bool?
    let intent: String?
    let wakeSucceeded: Bool?
    let switchSucceeded: Bool?

    init(expected: V2ExpectedAction) {
        atMs = expected.atMs; kind = expected.kind; type = expected.type
        eventID = expected.eventID; endpointID = expected.endpointID; reason = expected.reason
        value = expected.value; intent = expected.intent; wakeSucceeded = expected.wakeSucceeded
        switchSucceeded = expected.switchSucceeded
    }

    init(action: V2HandoffAction, atMs: Int64) {
        self.atMs = Int(atMs)
        switch action {
        case let .sendMessage(type, eventID, endpointID, intent, wakeSucceeded, switchSucceeded, _):
            kind = "sendMessage"; self.type = type.rawValue; self.eventID = eventID
            self.endpointID = endpointID; reason = nil; value = nil; self.intent = intent?.rawValue
            self.wakeSucceeded = wakeSucceeded; self.switchSucceeded = switchSucceeded
        case let .requestWake(eventID):
            kind = "requestWake"; type = nil; self.eventID = eventID; endpointID = nil; reason = nil; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .requestSwitch(eventID, endpointID):
            kind = "requestSwitch"; type = nil; self.eventID = eventID; self.endpointID = endpointID; reason = nil; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .lockTarget(endpointID):
            kind = "lockTarget"; type = nil; eventID = nil; self.endpointID = endpointID; reason = nil; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case .startDiscovery:
            kind = "startDiscovery"; type = nil; eventID = nil; endpointID = nil; reason = nil; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .promptManualSelection(reason):
            kind = "promptManualSelection"; type = nil; eventID = nil; endpointID = nil; self.reason = reason.rawValue; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .ignoreMessage(reason, eventID, endpointID):
            kind = "ignoreMessage"; type = nil; self.eventID = eventID; self.endpointID = endpointID; self.reason = reason.rawValue; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .clearEvent(reason):
            kind = "clearEvent"; type = nil; eventID = nil; endpointID = nil; self.reason = reason?.rawValue; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case .routeToV1:
            kind = "routeToV1"; type = nil; eventID = nil; endpointID = nil; reason = nil; value = nil; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        case let .setPeerReachable(value):
            kind = "setPeerReachable"; type = nil; eventID = nil; endpointID = nil; reason = nil; self.value = value; intent = nil; wakeSucceeded = nil; switchSucceeded = nil
        }
    }
}

private final class V2VectorClock { var nowMs: Int64 = 0 }
private struct V2ScheduledTask { let key: String; let dueMs: Int64; let order: Int; let action: () -> Void }
private final class V2VectorScheduler: HandoffScheduler {
    private let clock: V2VectorClock
    private var tasks: [String: V2ScheduledTask] = [:]
    private var nextOrder = 0
    init(clock: V2VectorClock) { self.clock = clock }
    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void) {
        nextOrder += 1
        tasks[key] = V2ScheduledTask(key: key, dueMs: clock.nowMs + delayMs, order: nextOrder, action: action)
    }
    func cancel(_ key: String) { tasks.removeValue(forKey: key) }
    func run(until target: Int64, includingBoundary: Bool) {
        while let task = tasks.values
            .filter({ includingBoundary ? $0.dueMs <= target : $0.dueMs < target })
            .sorted(by: { ($0.dueMs, $0.order) < ($1.dueMs, $1.order) }).first {
            tasks.removeValue(forKey: task.key)
            clock.nowMs = task.dueMs
            task.action()
        }
        clock.nowMs = target
    }
}
private final class V2VectorEventIDs: HandoffEventIDSource {
    func nextEventID() -> String { "00000000-0000-4000-8000-000000000001" }
}
private final class V2VectorSink: V2HandoffActionSink {
    var networkSends = 0
    var wakeCalls = 0
    var switchCalls = 0
    var inputCalls = 0
    func sendV2Message(type: V2MessageType, eventID: String, endpointID: String, intent: V2HandoverIntent?, wakeSucceeded: Bool?, switchSucceeded: Bool?, reason: V2CancellationReason?) { networkSends += 1 }
    func requestV2Wake(eventID: String) { wakeCalls += 1 }
    func requestV2Switch(eventID: String, endpointID: String) { switchCalls += 1 }
    func promptV2ManualSelection() {}
    func updateV2PeerReachable(_ reachable: Bool, endpointID: String) {}
}
