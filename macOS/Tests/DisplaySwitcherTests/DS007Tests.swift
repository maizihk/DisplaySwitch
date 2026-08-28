import XCTest

final class DS007Tests: XCTestCase {
    func testU015V1MissingWrongAndUnknownVersionsAreRejectedBeforeRuntime() {
        for payload in [
            #"{"version":1}"#,
            #"{"type":"status_probe"}"#,
            #"{"version":"2"}"#,
            #"{"version":2.0}"#,
            #"{"version":9}"#
        ] {
            XCTAssertFalse(V2OnlyDatagramGate.accepts(Data(payload.utf8)))
        }
        XCTAssertTrue(V2OnlyDatagramGate.accepts(Data(#"{"version":2}"#.utf8)))
    }

    func testU009TrayRequiresBothFeatureAndTrayFlags() {
        var display = configuredDisplay()
        XCTAssertTrue(DisplaySettingsSemantics.trayCommands(for: display).isEmpty)
        display.brightnessShowInTray = true
        XCTAssertTrue(DisplaySettingsSemantics.trayCommands(for: display).isEmpty)
        display.brightnessEnabled = true
        XCTAssertEqual(DisplaySettingsSemantics.trayCommands(for: display), [.luminance])
        display.brightnessEnabled = false
        XCTAssertTrue(DisplaySettingsSemantics.trayCommands(for: display).isEmpty)
    }

    func testV1PeerIdentityCanNeverBeConfirmedInV2OnlyConfiguration() {
        let profile = completeProfile(name: "Peer", displayID: UUID().uuidString)
        XCTAssertEqual(
            DisplayConfigurationStore.checkPeerIdentity(
                profile, endpointID: UUID().uuidString, protocolVersion: 1
            ),
            .invalid
        )
    }

    func testReturnToLocalDisabledTracksPresenceWithoutAnnouncement() {
        let sink = DS007V2Sink()
        let scheduler = DS007Scheduler()
        let machine = HandoffV2StateMachine(
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            sink: sink,
            scheduler: scheduler,
            eventIDSource: DS007EventIDs()
        )
        machine.configure(
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            coordinationEnabled: true,
            sourceInputPresent: false,
            targetInputPresent: false,
            enabledTargets: [V2HandoffTarget(
                endpointID: "22222222-2222-4222-8222-222222222222",
                capability: .v2,
                reachable: true
            )]
        )
        machine.handleLocalInputPresenceChanged(true, announceUnsolicitedArrival: false)
        XCTAssertEqual(machine.snapshot().sourceInputPresent, true)
        XCTAssertEqual(sink.networkCalls + sink.hardwareCalls, 0)
    }

    func testU018ToU020StatusesAreIndependentAndExpireAfterSixSeconds() {
        let display = configuredDisplay()
        var first = completeProfile(name: "First", displayID: display.id)
        var second = completeProfile(name: "Second", displayID: display.id)
        let store = CollaborationStatusStore()

        XCTAssertEqual(store.state(for: first, displays: [display], nowMs: 0), .neverChecked)
        store.beginCheck(profileID: first.id)
        XCTAssertEqual(store.state(for: first, displays: [display], nowMs: 0), .checking)
        store.finishCheck(profileID: first.id, responded: false)
        XCTAssertEqual(store.state(for: first, displays: [display], nowMs: 1_000), .noResponse)
        XCTAssertEqual(store.state(for: second, displays: [display], nowMs: 1_000), .neverChecked)

        store.recordAuthenticatedMessage(profileID: second.id, nowMs: 2_000)
        XCTAssertEqual(store.state(for: second, displays: [display], nowMs: 8_000), .connected)
        XCTAssertEqual(store.state(for: second, displays: [display], nowMs: 8_001), .disconnected)
        first.coordinationEnabled = false
        XCTAssertEqual(store.state(for: first, displays: [display], nowMs: 8_001), .disabled)
        second.peerHost = ""
        XCTAssertEqual(store.state(for: second, displays: [display], nowMs: 8_001), .incomplete)
    }

    func testU021OneHundredRapidWritesCoalesceToInflightAndLatest() {
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var completed: [Int] = []
        coordinator.onCompletion = { request, result in
            if case .success = result { completed.append(request.value) }
        }
        for value in 1...100 {
            coordinator.submit(request(command: .luminance, value: value))
        }
        XCTAssertEqual(executor.started.map(\.value), [1])
        executor.completeNext(success: true)
        XCTAssertEqual(executor.started.map(\.value), [1, 100])
        executor.completeNext(success: true)
        XCTAssertEqual(completed, [1, 100])
    }

    func testU022InterleavedItemsRemainIndependentAndTransportSerial() {
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        coordinator.submit(request(command: .luminance, value: 10))
        coordinator.submit(request(command: .contrast, value: 20))
        coordinator.submit(request(command: .luminance, value: 30))
        XCTAssertEqual(executor.maximumConcurrent, 1)
        XCTAssertEqual(executor.started.map { ($0.key.command, $0.value) }.first?.0, .luminance)
        executor.completeNext(success: true)
        XCTAssertEqual(executor.maximumConcurrent, 1)
        executor.completeNext(success: true)
        executor.completeNext(success: true)
        XCTAssertEqual(executor.started.count, 3)
        XCTAssertTrue(executor.started.contains { $0.key.command == .luminance && $0.value == 30 })
        XCTAssertTrue(executor.started.contains { $0.key.command == .contrast && $0.value == 20 })
    }

    func testU025CancelClearsPendingAndLateCompletionIsIgnored() {
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var published = 0
        coordinator.onCompletion = { _, _ in published += 1 }
        coordinator.submit(request(command: .volume, value: 1))
        coordinator.submit(request(command: .volume, value: 99))
        coordinator.cancelAll()
        executor.completeNext(success: true)
        XCTAssertEqual(executor.started.map(\.value), [1])
        XCTAssertEqual(published, 0)
        XCTAssertEqual(executor.cancelCount, 1)
    }

    func testU023RecoveryRetriesExactlyOnce() throws {
        var attempts = 0
        var recoveries = 0
        try DDCSingleRetry.perform(operation: {
            attempts += 1
            if attempts == 1 { throw DDCBackendError.writeFailed(stableID: "display", command: .luminance) }
        }, recover: {
            recoveries += 1
        })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(recoveries, 1)
    }

    func testU024FailedRetryDoesNotBecomePermanent() {
        var attempts = 0
        XCTAssertThrowsError(try DDCSingleRetry.perform(operation: {
            attempts += 1
            throw DDCBackendError.writeFailed(stableID: "display", command: .contrast)
        }, recover: {}))
        XCTAssertEqual(attempts, 2)
        attempts = 0
        XCTAssertNoThrow(try DDCSingleRetry.perform(operation: { attempts += 1 }, recover: {}))
        XCTAssertEqual(attempts, 1)
    }

    private func request(command: DDCCommand, value: Int) -> DDCWriteRequest {
        DDCWriteRequest(key: DDCWriteKey(stableID: "display", command: command),
                        selector: "selector", value: value)
    }

    private func configuredDisplay() -> DisplayConfigurationV4Display {
        DisplayConfigurationV4Display(
            id: UUID().uuidString, name: "Display", selector: "selector",
            localInput: nil, readEnabled: false
        )
    }

    private func completeProfile(name: String, displayID: String) -> CollaborationProfile {
        CollaborationProfile(
            id: UUID().uuidString, name: name, peerHost: "peer.example", peerPort: 49731,
            pairingCode: UUID().uuidString, peerEndpointID: UUID().uuidString,
            peerProtocolVersion: 2, coordinationEnabled: true,
            displayInputs: [DisplayInputMapping(displayID: displayID, peerInput: 18)],
            triggerDevices: []
        )
    }
}

private final class DS007V2Sink: V2HandoffActionSink {
    private(set) var networkCalls = 0
    private(set) var hardwareCalls = 0
    func sendV2Message(type: V2MessageType, eventID: String, endpointID: String,
                       intent: V2HandoverIntent?, wakeSucceeded: Bool?,
                       switchSucceeded: Bool?, reason: V2CancellationReason?) { networkCalls += 1 }
    func requestV2Wake(eventID: String) { hardwareCalls += 1 }
    func requestV2Switch(eventID: String, endpointID: String) { hardwareCalls += 1 }
    func promptV2ManualSelection() {}
    func updateV2PeerReachable(_ reachable: Bool, endpointID: String) {}
}

private final class DS007Scheduler: HandoffScheduler {
    func schedule(_ key: String, after delayMs: Int64, _ action: @escaping () -> Void) {}
    func cancel(_ key: String) {}
}

private struct DS007EventIDs: HandoffEventIDSource {
    func nextEventID() -> String { "33333333-3333-4333-8333-333333333333" }
}

private final class ControlledWriteExecutor: DDCWriteExecuting {
    private var completions: [(Result<Int, Error>) -> Void] = []
    private(set) var started: [DDCWriteRequest] = []
    private(set) var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var cancelCount = 0

    func execute(_ request: DDCWriteRequest, completion: @escaping (Result<Int, Error>) -> Void) {
        started.append(request)
        completions.append(completion)
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
    }

    func completeNext(success: Bool) {
        let completion = completions.removeFirst()
        active -= 1
        completion(success ? .success(started[completions.isEmpty ? started.count - 1 : 0].value)
                           : .failure(DDCBackendError.writeFailed(stableID: "display", command: .luminance)))
    }

    func cancelAll() { cancelCount += 1 }
}
