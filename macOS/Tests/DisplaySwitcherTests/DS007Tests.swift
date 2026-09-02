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

    func testLinkedSettingsProjectionHandlesZeroOneAndRestoresIndividualLayout() {
        XCTAssertTrue(LinkedDDCControlProjection.entries(
            configurations: [], displays: [], visibility: .settings,
            sample: { _, _ in nil }
        ).isEmpty)

        var display = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        display.brightnessEnabled = true
        let entries = LinkedDDCControlProjection.entries(
            configurations: [runtimeDisplay(id: display.id, index: 1, name: display.name)],
            displays: [display],
            visibility: .settings,
            sample: { _, _ in nil }
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].command, .luminance)
        XCTAssertEqual(entries[0].targets.map(\.stableID), ["display-a"])
        XCTAssertEqual(entries[0].value, .unknown)
        XCTAssertEqual(entries[0].maximum, 100)

        XCTAssertEqual(
            DisplaySettingsControlProjection.make(
                linkAllDisplays: true, linkedEntries: entries
            ),
            DisplaySettingsControlProjection(
                showsLinkedControls: true,
                showsIndividualSliders: false,
                linkedCommands: [.luminance]
            )
        )
        XCTAssertEqual(
            DisplaySettingsControlProjection.make(
                linkAllDisplays: false, linkedEntries: entries
            ),
            DisplaySettingsControlProjection(
                showsLinkedControls: false,
                showsIndividualSliders: true,
                linkedCommands: []
            )
        )
    }

    func testLinkedValuesAreUniformMixedOrUnknownAndUseSafeMaximumIntersection() {
        var first = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        var second = configuredDisplay(id: "display-b", name: "Second", selector: "selector-b")
        var third = configuredDisplay(id: "display-c", name: "Third", selector: "selector-c")
        first.brightnessEnabled = true
        second.brightnessEnabled = true
        third.brightnessEnabled = true
        let configurations = [
            runtimeDisplay(id: first.id, index: 1, name: first.name),
            runtimeDisplay(id: second.id, index: 2, name: second.name),
            runtimeDisplay(id: third.id, index: 3, name: third.name)
        ]
        let displays = [first, second, third]

        func entry(_ samples: [String: DDCControlValueSample]) -> LinkedDDCControlProjection.Entry {
            LinkedDDCControlProjection.entries(
                configurations: configurations,
                displays: displays,
                visibility: .settings,
                sample: { stableID, _ in samples[stableID.lowercased()] }
            )[0]
        }

        var samples = [
            "display-a": DDCControlValueSample(value: 40, maximum: 100, estimated: false),
            "display-b": DDCControlValueSample(value: 40, maximum: 80, estimated: true),
            "display-c": DDCControlValueSample(value: 40, maximum: 60, estimated: false)
        ]
        XCTAssertEqual(entry(samples).value, .uniform(value: 40, estimated: true))
        XCTAssertEqual(entry(samples).value.displayText, "≈40")
        XCTAssertEqual(entry(samples).value.accessibilityValue, "约 40")
        XCTAssertEqual(entry(samples).maximum, 60)
        samples["display-b"] = DDCControlValueSample(value: 50, maximum: 80, estimated: false)
        XCTAssertEqual(entry(samples).value, .mixed)
        XCTAssertEqual(entry(samples).value.displayText, "混合")
        XCTAssertEqual(entry(samples).value.accessibilityValue, "混合")
        samples.removeValue(forKey: "display-c")
        XCTAssertEqual(entry(samples).value, .unknown)
        XCTAssertEqual(entry(samples).value.displayText, "—")
        XCTAssertEqual(entry(samples).value.accessibilityValue, "未知")
        XCTAssertEqual(entry(samples).maximum, 80)
    }

    func testLinkedSliderVisualStateHidesSpecificValueUntilUserInteraction() {
        XCTAssertEqual(
            LinkedDDCSliderVisualState(.uniform(value: 42, estimated: true)),
            .uniform(value: 42, estimated: true)
        )
        XCTAssertTrue(
            LinkedDDCSliderVisualState(.uniform(value: 42, estimated: false)).showsSpecificValue
        )
        XCTAssertFalse(LinkedDDCSliderVisualState(.mixed).showsSpecificValue)
        XCTAssertFalse(LinkedDDCSliderVisualState(.unknown).showsSpecificValue)
        XCTAssertEqual(
            LinkedDDCSliderVisualState(.mixed).acceptingUserValue(37),
            .uniform(value: 37, estimated: false)
        )
        XCTAssertEqual(
            LinkedDDCSliderVisualState(.unknown).acceptingUserValue(61),
            .uniform(value: 61, estimated: false)
        )
    }

    func testLinkedSliderViewTransitionsFromNeutralToSpecificKnobOnFirstInteraction() {
        let slider = LinkedDDCSlider(frame: .zero)
        slider.apply(aggregate: .uniform(value: 25, estimated: false), maximum: 80, isEnabled: true)
        XCTAssertTrue(slider.drawsSpecificValue)
        XCTAssertEqual(slider.integerValue, 25)

        slider.apply(aggregate: .mixed, maximum: 80, isEnabled: true)
        XCTAssertFalse(slider.drawsSpecificValue)
        XCTAssertEqual(slider.accessibilityValue() as? String, "混合")
        slider.integerValue = 36
        XCTAssertEqual(slider.acceptCurrentUserValue(), .uniform(value: 36, estimated: false))
        XCTAssertTrue(slider.drawsSpecificValue)
        XCTAssertEqual(slider.accessibilityValue() as? String, "36")

        slider.apply(aggregate: .unknown, maximum: 80, isEnabled: true)
        XCTAssertFalse(slider.drawsSpecificValue)
        XCTAssertEqual(slider.accessibilityValue() as? String, "未知")
        slider.integerValue = 49
        XCTAssertEqual(slider.acceptCurrentUserValue(), .uniform(value: 49, estimated: false))
        XCTAssertTrue(slider.drawsSpecificValue)
        XCTAssertEqual(slider.accessibilityValue() as? String, "49")
    }

    func testLinkedTrayIsFlatAndTrayEligibilityDoesNotRestrictWriteTargets() {
        var first = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        var second = configuredDisplay(id: "display-b", name: "Second", selector: "selector-b")
        first.brightnessEnabled = true
        second.brightnessEnabled = true
        second.brightnessShowInTray = true
        let configurations = [
            runtimeDisplay(id: first.id, index: 1, name: first.name),
            runtimeDisplay(id: second.id, index: 2, name: second.name)
        ]
        let projection = TrayDisplayMenuProjection.projection(
            configurations: configurations,
            displays: [first, second],
            linkAllDisplays: true
        )

        XCTAssertTrue(projection.displayEntries.isEmpty)
        XCTAssertEqual(projection.linkedCommands, [.luminance])
        XCTAssertEqual(projection.dynamicItemCount, 1)

        let unlinked = TrayDisplayMenuProjection.projection(
            configurations: configurations,
            displays: [first, second],
            linkAllDisplays: false
        )
        XCTAssertTrue(unlinked.linkedCommands.isEmpty)
        XCTAssertEqual(unlinked.displayEntries.map(\.displayID), [2])

        let entry = LinkedDDCControlProjection.entries(
            configurations: configurations,
            displays: [first, second],
            visibility: .tray,
            sample: { _, _ in nil }
        )[0]
        XCTAssertEqual(entry.targets.map(\.stableID), ["display-a", "display-b"])
        XCTAssertEqual(
            LinkedDDCControlProjection.writeRequests(
                command: .luminance, value: 55, entry: entry
            ).map { $0.key.stableID },
            ["display-a", "display-b"]
        )
    }

    func testLinkedTrayVisibilityUsesStoredPreferenceButWritesOnlyOnlineTargets() {
        var online = configuredDisplay(id: "display-a", name: "Online", selector: "selector-a")
        var offline = configuredDisplay(id: "display-b", name: "Offline", selector: "selector-b")
        online.brightnessEnabled = true
        offline.brightnessEnabled = true
        offline.brightnessShowInTray = true

        let entry = LinkedDDCControlProjection.entries(
            configurations: [runtimeDisplay(id: online.id, index: 1, name: online.name)],
            displays: [online, offline],
            visibility: .tray,
            sample: { _, _ in nil }
        )[0]

        XCTAssertEqual(entry.command, .luminance)
        XCTAssertEqual(entry.targets.map(\.stableID), ["display-a"])
        XCTAssertEqual(entry.value, .unknown)
    }

    func testLinkedSettingsKeepsConfiguredControlVisibleButDisabledWithoutRuntimeTargets() {
        var stored = configuredDisplay(id: "display-a", name: "Offline", selector: "selector-a")
        stored.contrastEnabled = true

        let entry = LinkedDDCControlProjection.entries(
            configurations: [],
            displays: [stored],
            visibility: .settings,
            sample: { _, _ in nil }
        )[0]

        XCTAssertEqual(entry.command, .contrast)
        XCTAssertTrue(entry.targets.isEmpty)
        XCTAssertEqual(entry.value, .unknown)
        XCTAssertTrue(LinkedDDCControlProjection.writeRequests(
            command: .contrast, value: 20, entry: entry
        ).isEmpty)
    }

    func testLinkedProjectionFiltersOfflineAndAmbiguousRuntimeTargets() {
        var online = configuredDisplay(id: "display-a", name: "Online", selector: "selector-a")
        var offline = configuredDisplay(id: "display-b", name: "Offline", selector: "selector-b")
        var ambiguous = configuredDisplay(id: "display-c", name: "Ambiguous", selector: "selector-c")
        online.volumeEnabled = true
        offline.volumeEnabled = true
        ambiguous.volumeEnabled = true
        let configurations = [
            runtimeDisplay(id: online.id, index: 1, name: online.name),
            DisplayConfiguration(
                id: ambiguous.id, index: 2, name: ambiguous.name,
                selector: "duplicate-selector", localInput: nil, targetInput: nil, readEnabled: false
            ),
            DisplayConfiguration(
                id: "display-d", index: 3, name: "Duplicate",
                selector: "duplicate-selector", localInput: nil, targetInput: nil, readEnabled: false
            )
        ]
        let entries = LinkedDDCControlProjection.entries(
            configurations: configurations,
            displays: [online, offline, ambiguous],
            visibility: .settings,
            sample: { _, _ in nil }
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].targets.map(\.stableID), ["display-a"])
    }

    func testLinkedWriteRejectsValuesAboveSafeIntersection() {
        var first = configuredDisplay(id: "display-a", name: "First", selector: "selector-a")
        var second = configuredDisplay(id: "display-b", name: "Second", selector: "selector-b")
        first.contrastEnabled = true
        second.contrastEnabled = true
        let samples = [
            "display-a": DDCControlValueSample(value: 20, maximum: 100, estimated: false),
            "display-b": DDCControlValueSample(value: 20, maximum: 45, estimated: false)
        ]
        let entry = LinkedDDCControlProjection.entries(
            configurations: [
                runtimeDisplay(id: first.id, index: 1, name: first.name),
                runtimeDisplay(id: second.id, index: 2, name: second.name)
            ],
            displays: [first, second],
            visibility: .settings,
            sample: { stableID, _ in samples[stableID.lowercased()] }
        )[0]

        XCTAssertEqual(entry.maximum, 45)
        XCTAssertEqual(
            LinkedDDCControlProjection.writeRequests(
                command: .contrast, value: 45, entry: entry
            ).count,
            2
        )
        XCTAssertTrue(LinkedDDCControlProjection.writeRequests(
            command: .contrast, value: 46, entry: entry
        ).isEmpty)
    }

    func testLinkedBatchWritesSameAbsoluteValueAndKeepsFailuresIsolated() {
        let entry = LinkedDDCControlProjection.Entry(
            command: .volume,
            targets: [
                .init(displayID: 1, stableID: "display-a", selector: "selector-a"),
                .init(displayID: 2, stableID: "display-b", selector: "selector-b")
            ],
            value: .mixed,
            maximum: 100
        )
        let requests = LinkedDDCControlProjection.writeRequests(
            command: .volume,
            value: 33,
            entry: entry
        )
        let executor = ControlledWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var completions: [String: Bool] = [:]
        coordinator.onCompletion = { request, result in
            completions[request.key.stableID] = (try? result.get()) != nil
        }

        requests.forEach(coordinator.submit)
        XCTAssertEqual(Set(executor.started.map(\.value)), [33])
        XCTAssertEqual(executor.maximumConcurrent, 2)
        executor.completeNext(success: false)
        executor.completeNext(success: true)

        XCTAssertEqual(completions["display-a"], false)
        XCTAssertEqual(completions["display-b"], true)
    }

    func testDS024StaticTrayActionsOnlyContainSettingsAndQuit() {
        XCTAssertEqual(TrayStaticMenuAction.allCases, [.settings, .quit])
    }

    func testDS024DynamicSeparatorRequiresVisibleDynamicContent() {
        XCTAssertFalse(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 0, displayControlItemCount: 0
        ))
        XCTAssertTrue(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 1, displayControlItemCount: 0
        ))
        XCTAssertTrue(TrayMenuSeparatorProjection.showsDynamicContentSeparator(
            profileCount: 0, displayControlItemCount: 1
        ))
    }

    func testDS028USBStatusUsesOnlyExactOperationalText() {
        let enabled = TrayUSBStatusPresentation(isOperational: true)
        let disabled = TrayUSBStatusPresentation(isOperational: false)

        XCTAssertEqual(enabled.title, "USB 切换已开启")
        XCTAssertEqual(disabled.title, "USB 切换已关闭")
        XCTAssertEqual(enabled.accessibilityLabel, enabled.title)
        XCTAssertEqual(disabled.accessibilityLabel, disabled.title)
        XCTAssertFalse(enabled.title.contains("VID"))
        XCTAssertFalse(enabled.title.contains("PID"))
    }

    func testDS028AllVisibleTrayRolesHaveSemanticSymbols() {
        let icons: [TraySemanticIcon] = [
            .usbStatus(isOperational: true),
            .usbStatus(isOperational: false),
            .collaborationSwitch,
            .display,
            .luminance,
            .contrast,
            .volume,
            .settings,
            .quit
        ]
        XCTAssertTrue(icons.allSatisfy { !$0.symbolName.isEmpty })
        XCTAssertEqual(Set(icons.map(\.symbolName)).count, icons.count)
    }

    func testDS028TrayDDCRowUsesCompactSingleLineLayout() {
        XCTAssertTrue(TrayControlRowLayout.isInsideCompactTarget)
        XCTAssertEqual(TrayControlRowLayout.width, 252)
        XCTAssertEqual(TrayControlRowLayout.height, 30)
        XCTAssertGreaterThanOrEqual(TrayControlRowLayout.sliderWidth, 100)
        XCTAssertEqual(
            TrayControlRowLayout.horizontalInset * 2
                + TrayControlRowLayout.iconWidth
                + TrayControlRowLayout.iconTitleSpacing
                + TrayControlRowLayout.titleWidth
                + TrayControlRowLayout.titleSliderSpacing
                + TrayControlRowLayout.sliderWidth
                + TrayControlRowLayout.sliderValueSpacing
                + TrayControlRowLayout.valueWidth,
            TrayControlRowLayout.width,
            accuracy: 0.001
        )
    }

    func testDS028BothStatusItemButtonsRouteOnlyToTrayMenu() {
        XCTAssertTrue(StatusItemClickRouting.supportedEventMask.contains(.leftMouseUp))
        XCTAssertTrue(StatusItemClickRouting.supportedEventMask.contains(.rightMouseUp))
        XCTAssertFalse(StatusItemClickRouting.supportedEventMask.contains(.leftMouseDown))
        XCTAssertEqual(StatusItemClickRouting.destination(for: .leftMouseUp), .trayMenu)
        XCTAssertEqual(StatusItemClickRouting.destination(for: .rightMouseUp), .trayMenu)
        XCTAssertEqual(StatusItemClickRouting.destination(for: .other), .none)
        XCTAssertEqual(TrayStaticMenuAction.allCases, [.settings, .quit])
    }

    func testDS028SettingsWindowLifecycleShowsAndHidesDockWithoutChangingWindowLevel() {
        XCTAssertEqual(SettingsWindowLifecycleState.open.activationPolicy, .regular)
        XCTAssertEqual(SettingsWindowLifecycleState.closed.activationPolicy, .accessory)
        XCTAssertEqual(SettingsWindowLifecycleState.open.windowLevel, .normal)
        XCTAssertEqual(SettingsWindowLifecycleState.closed.windowLevel, .normal)
        XCTAssertFalse(SettingsWindowLifecycleState.open.hidesOnDeactivate)
        XCTAssertFalse(SettingsWindowLifecycleState.open.isReleasedWhenClosed)
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
