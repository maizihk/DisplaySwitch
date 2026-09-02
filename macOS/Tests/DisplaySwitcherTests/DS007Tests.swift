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

    func testDS024NoTrayControlsProducesNoDisplayGroups() {
        let display = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        let entries = TrayDisplayMenuProjection.entries(
            configurations: [runtimeDisplay(id: display.id, index: 1, name: display.name)],
            displays: [display]
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testDS024OnlyDisplaysWithTrayControlsProduceGroups() {
        var hidden = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        hidden.brightnessEnabled = true
        var visible = configuredDisplay(id: "display-b", name: "Second", selector: "selector-b")
        visible.contrastEnabled = true
        visible.contrastShowInTray = true
        let entries = TrayDisplayMenuProjection.entries(
            configurations: [
                runtimeDisplay(id: hidden.id, index: 1, name: hidden.name),
                runtimeDisplay(id: visible.id, index: 2, name: visible.name)
            ],
            displays: [hidden, visible]
        )

        XCTAssertEqual(entries, [
            TrayDisplayMenuProjection.Entry(
                displayID: 2, title: "Second", commands: [.contrast]
            )
        ])
    }

    func testDS024DisplayGroupContainsOnlyEnabledTrayControls() {
        var display = configuredDisplay(id: "display-a", name: "Display", selector: "selector-a")
        display.brightnessEnabled = true
        display.brightnessShowInTray = true
        display.contrastEnabled = true
        display.volumeShowInTray = true
        let entries = TrayDisplayMenuProjection.entries(
            configurations: [runtimeDisplay(id: display.id, index: 1, name: display.name)],
            displays: [display]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].commands, [.luminance])
    }

    func testDS024StaticTrayActionsOnlyContainSettingsAndQuit() {
        XCTAssertEqual(TrayStaticMenuAction.allCases, [.settings, .quit])
    }

    func testDS024DynamicSeparatorRequiresVisibleDynamicContent() {
        XCTAssertFalse(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 0, displayGroupCount: 0
        ))
        XCTAssertTrue(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 1, displayGroupCount: 0
        ))
        XCTAssertTrue(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 0, displayGroupCount: 1
        ))
    }

    func testDS024LinkedControlTargetsUsePersistedSetting() {
        XCTAssertEqual(
            DisplayControlTargetProjection.displayIDs(
                selectedDisplayID: 2, availableDisplayIDs: [3, 1, 2], linkAllDisplays: false
            ),
            [2]
        )
        XCTAssertEqual(
            DisplayControlTargetProjection.displayIDs(
                selectedDisplayID: 2, availableDisplayIDs: [3, 1, 2], linkAllDisplays: true
            ),
            [1, 2, 3]
        )
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

    func testDS009DifferentDisplaysRemainFailureIsolated() {
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var completions: [String: Bool] = [:]
        coordinator.onCompletion = { request, result in
            completions[request.key.stableID] = (try? result.get()) != nil
        }
        coordinator.submit(request(displayID: "display-a", command: .luminance, value: 30))
        coordinator.submit(request(displayID: "display-b", command: .luminance, value: 70))

        XCTAssertEqual(executor.maximumConcurrent, 2)
        executor.completeNext(success: false)
        executor.completeNext(success: true)

        XCTAssertEqual(completions["display-a"], false)
        XCTAssertEqual(completions["display-b"], true)
    }

    func testDS009RefreshOrWindowCloseDropsPendingAndLateUICompletion() {
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var published = 0
        coordinator.onCompletion = { _, _ in published += 1 }
        coordinator.submit(request(command: .contrast, value: 20))
        coordinator.submit(request(command: .contrast, value: 80))

        coordinator.cancelAll()
        executor.completeNext(success: true)

        XCTAssertEqual(executor.started.map(\.value), [20])
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
        request(displayID: "display", command: command, value: value)
    }

    private func request(displayID: String, command: DDCCommand, value: Int) -> DDCWriteRequest {
        DDCWriteRequest(key: DDCWriteKey(stableID: displayID, command: command),
                        selector: "selector", value: value)
    }

    private func configuredDisplay(
        id: String = UUID().uuidString,
        name: String = "Display",
        selector: String = "selector"
    ) -> DisplayConfigurationV4Display {
        DisplayConfigurationV4Display(
            id: id, name: name, selector: selector,
            localInput: nil, readEnabled: false
        )
    }

    private func runtimeDisplay(id: String, index: Int, name: String) -> DisplayConfiguration {
        DisplayConfiguration(
            id: id, index: index, name: name, selector: "selector-\(index)",
            localInput: nil, targetInput: nil, readEnabled: false
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
