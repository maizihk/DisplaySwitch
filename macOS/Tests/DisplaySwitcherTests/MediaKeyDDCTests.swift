import CoreAudio
import XCTest

final class MediaKeyDDCTests: XCTestCase {
    func testNormalizerAcceptsFinalMediaActionsAndPreservesRepeat() {
        XCTAssertEqual(normalize(key: 3), event(.brightnessDown))
        XCTAssertEqual(normalize(key: 2), event(.brightnessUp))
        XCTAssertEqual(normalize(key: 7), event(.mute))
        XCTAssertEqual(normalize(key: 1), event(.volumeDown))
        XCTAssertEqual(normalize(key: 0, repeatEvent: true), event(.volumeUp, repeatEvent: true))
    }

    func testNormalizerRejectsKeyUpWrongSubtypeAndUnknownAction() {
        XCTAssertNil(MediaKeyEventNormalizer.normalize(subtype: 7, data1: data1(key: 2)))
        XCTAssertNil(MediaKeyEventNormalizer.normalize(
            subtype: MediaKeyEventNormalizer.auxiliaryControlButtonsSubtype,
            data1: (2 << 16) | (11 << 8)
        ))
        XCTAssertNil(normalize(key: 99))
        XCTAssertFalse(MediaKeyEventMonitor.consumesSystemEvents)
    }

    func testIndependentStepPreservesPerDisplayDifferenceAndSkipsUnknown() {
        var router = MediaKeyDDCRouter()
        let plan = router.plan(
            event: event(.brightnessUp),
            linkAllDisplays: false,
            targets: [target("A", value: 40), target("B", value: 60), target("C", value: nil)]
        )
        XCTAssertEqual(plan.requests.map(\.value), [45, 65])
        XCTAssertEqual(plan.requests.map(\.key.stableID), ["A", "B"])
        XCTAssertEqual(plan.outcome, .applied(2))
    }

    func testEstimatedValuesAreNotTrustedForRelativeWrites() {
        var router = MediaKeyDDCRouter()
        let plan = router.plan(
            event: event(.volumeDown),
            linkAllDisplays: false,
            targets: [target("A", value: 50, estimated: true)]
        )
        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertEqual(plan.outcome, .missingTrustedValues)
    }

    func testLinkedStepWritesOneAbsoluteValueOnlyFromUniformTrustedSamples() {
        var uniformRouter = MediaKeyDDCRouter()
        let uniform = uniformRouter.plan(
            event: event(.brightnessUp),
            linkAllDisplays: true,
            targets: [target("A", value: 40, maximum: 100), target("B", value: 40, maximum: 80)]
        )
        XCTAssertEqual(uniform.requests.map(\.value), [45, 45])

        var mixedRouter = MediaKeyDDCRouter()
        let mixed = mixedRouter.plan(
            event: event(.brightnessUp),
            linkAllDisplays: true,
            targets: [target("A", value: 40), target("B", value: 41)]
        )
        XCTAssertTrue(mixed.requests.isEmpty)
        XCTAssertEqual(mixed.outcome, .mixedLinkedValues)

        var unknownRouter = MediaKeyDDCRouter()
        let unknown = unknownRouter.plan(
            event: event(.brightnessUp),
            linkAllDisplays: true,
            targets: [target("A", value: 40), target("B", value: nil)]
        )
        XCTAssertTrue(unknown.requests.isEmpty)
        XCTAssertEqual(unknown.outcome, .missingTrustedValues)
    }

    func testRepeatedAdjustmentRoutesButRepeatedMuteDoesNotToggle() {
        var router = MediaKeyDDCRouter()
        let firstAdjustment = router.plan(
            event: event(.volumeUp, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 25)]
        )
        XCTAssertEqual(firstAdjustment.requests.map(\.value), [30])
        let secondAdjustment = router.plan(
            event: event(.volumeUp, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 25)]
        )
        XCTAssertEqual(secondAdjustment.requests.map(\.value), [35])
        let mute = router.plan(
            event: event(.mute, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 25)]
        )
        XCTAssertTrue(mute.requests.isEmpty)
        XCTAssertEqual(mute.outcome, .ignoredMuteRepeat)
    }

    func testLatestWinsProjectionSurvivesOlderCompletionAndClearsOnFailure() {
        var router = MediaKeyDDCRouter()
        let first = router.plan(
            event: event(.volumeUp, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 25)]
        ).requests[0]
        _ = router.plan(
            event: event(.volumeUp, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 25)]
        )
        router.recordCompletion(first, succeeded: true)
        let third = router.plan(
            event: event(.volumeUp, repeatEvent: true),
            linkAllDisplays: false,
            targets: [target("A", value: 30)]
        )
        XCTAssertEqual(third.requests.map(\.value), [40])

        router.recordCompletion(third.requests[0], succeeded: false)
        let afterFailure = router.plan(
            event: event(.volumeUp),
            linkAllDisplays: false,
            targets: [target("A", value: nil)]
        )
        XCTAssertTrue(afterFailure.requests.isEmpty)
        XCTAssertEqual(afterFailure.outcome, .missingTrustedValues)
    }

    func testIndependentMuteStoresAndRestoresEachTrustedNonzeroValue() {
        var router = MediaKeyDDCRouter()
        let muted = router.plan(
            event: event(.mute),
            linkAllDisplays: false,
            targets: [target("A", value: 30), target("B", value: 55), target("C", value: nil)]
        )
        XCTAssertEqual(muted.requests.map(\.value), [0, 0])
        let restored = router.plan(
            event: event(.mute),
            linkAllDisplays: false,
            targets: [target("A", value: 0), target("B", value: 0), target("C", value: nil)]
        )
        XCTAssertEqual(restored.requests.map(\.value), [30, 55])
    }

    func testMuteMemoryIsSessionOnlyAndLinkedRestoreNeverBreaksAbsoluteSemantics() {
        var router = MediaKeyDDCRouter()
        let muted = router.plan(
            event: event(.mute),
            linkAllDisplays: true,
            targets: [target("A", value: 35), target("B", value: 35)]
        )
        XCTAssertEqual(muted.requests.map(\.value), [0, 0])
        let restored = router.plan(
            event: event(.mute),
            linkAllDisplays: true,
            targets: [target("A", value: 0), target("B", value: 0)]
        )
        XCTAssertEqual(restored.requests.map(\.value), [35, 35])

        router.invalidateSessionState()
        let afterReload = router.plan(
            event: event(.mute),
            linkAllDisplays: true,
            targets: [target("A", value: 0), target("B", value: 0)]
        )
        XCTAssertTrue(afterReload.requests.isEmpty)
        XCTAssertEqual(afterReload.outcome, .noStoredMuteValue)
    }

    func testUntrustedVirtualOrIncompleteTopologyBlocksMediaRouting() {
        XCTAssertFalse(MediaKeyTopologyPolicy.allows(.untrusted))
        XCTAssertFalse(MediaKeyTopologyPolicy.allows(DDCPhysicalEnumerationEvidence(
            cgEnumerationSucceeded: true,
            externalCGDisplayCount: 2,
            extractedIdentityCount: 2,
            registryEnumerationSucceeded: true,
            externalRegistryServiceCount: 1,
            matchedPhysicalTransportCount: 1
        )))
        XCTAssertTrue(MediaKeyTopologyPolicy.allows(DDCPhysicalEnumerationEvidence(
            cgEnumerationSucceeded: true,
            externalCGDisplayCount: 2,
            extractedIdentityCount: 2,
            registryEnumerationSucceeded: true,
            externalRegistryServiceCount: 2,
            matchedPhysicalTransportCount: 2
        )))
    }

    func testPermissionPresentationIsSafeAndExplicit() {
        let presentation = MediaKeyShortcutPresentation.make(
            state: .permissionRequired,
            lastRoute: nil
        )
        XCTAssertEqual(presentation.actionTitle, "申请权限")
        XCTAssertTrue(presentation.title.contains("输入监控权限"))
        XCTAssertTrue(presentation.detail.contains("其他功能不受影响"))
    }

    func testConfigurationReloadGenerationSuppressesLateMediaWriteCompletion() {
        let executor = ControlledMediaKeyWriteExecutor()
        let coordinator = DDCLatestWinsCoordinator(executor: executor)
        var published: [DDCWriteRequest] = []
        coordinator.onCompletion = { request, _ in published.append(request) }
        coordinator.submit(DDCWriteRequest(
            key: DDCWriteKey(stableID: "A", command: .luminance),
            selector: "selector-A",
            value: 45
        ))
        XCTAssertEqual(executor.pending.count, 1)
        coordinator.setOperationsAllowed(false)
        executor.completeFirst()
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(executor.cancelCount, 1)
    }

    func testColdStartFirstEventWaitsForFreshReadBeforeRouting() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var plans: [MediaKeyDDCPlan] = []
        var router = MediaKeyDDCRouter()
        coordinator.onCompletion = { result, advance in
            router.beginFreshReadRouting(command: .luminance, targets: result.targets)
            plans.append(router.plan(
                event: result.request.event,
                linkAllDisplays: result.request.linkAllDisplays,
                targets: result.targets
            ))
            advance()
        }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(executor.pending.count, 1)

        executor.completeFirst(samples: [
            "a": DDCControlValueSample(value: 40, maximum: 100, estimated: false)
        ])
        XCTAssertEqual(plans.first?.requests.map(\.value), [45])
        XCTAssertEqual(plans.first?.outcome, .applied(1))
    }

    func testIndependentFreshReadFailureSkipsOnlyFailedTarget() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var plan: MediaKeyDDCPlan?
        var router = MediaKeyDDCRouter()
        coordinator.onCompletion = { result, advance in
            router.beginFreshReadRouting(command: .volume, targets: result.targets)
            plan = router.plan(
                event: result.request.event,
                linkAllDisplays: false,
                targets: result.targets
            )
            advance()
        }
        coordinator.submit(freshRequest(
            .volumeDown,
            targets: [freshTarget("A"), freshTarget("B")]
        ))
        executor.completeFirst(samples: [
            "a": DDCControlValueSample(value: 50, maximum: 100, estimated: false)
        ])

        XCTAssertEqual(plan?.requests.map(\.key.stableID), ["A"])
        XCTAssertEqual(plan?.requests.map(\.value), [45])
        XCTAssertEqual(plan?.outcome, .applied(1))
    }

    func testLinkedFreshReadFailureOrMixedValuesBlocksWholeGroup() {
        func route(samples: [String: DDCControlValueSample]) -> MediaKeyDDCPlan? {
            let executor = ControlledMediaKeyFreshReadExecutor()
            let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
            var plan: MediaKeyDDCPlan?
            var router = MediaKeyDDCRouter()
            coordinator.onCompletion = { result, advance in
                router.beginFreshReadRouting(command: .luminance, targets: result.targets)
                plan = router.plan(
                    event: result.request.event,
                    linkAllDisplays: true,
                    targets: result.targets
                )
                advance()
            }
            coordinator.submit(freshRequest(
                .brightnessUp,
                linked: true,
                targets: [freshTarget("A"), freshTarget("B")]
            ))
            executor.completeFirst(samples: samples)
            return plan
        }

        let unknown = route(samples: [
            "a": DDCControlValueSample(value: 40, maximum: 100, estimated: false)
        ])
        XCTAssertTrue(unknown?.requests.isEmpty == true)
        XCTAssertEqual(unknown?.outcome, .missingTrustedValues)

        let mixed = route(samples: [
            "a": DDCControlValueSample(value: 40, maximum: 100, estimated: false),
            "b": DDCControlValueSample(value: 41, maximum: 100, estimated: false)
        ])
        XCTAssertTrue(mixed?.requests.isEmpty == true)
        XCTAssertEqual(mixed?.outcome, .mixedLinkedValues)
    }

    func testHeldRepeatEventsShareOneBoundedFreshRead() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var result: MediaKeyFreshReadResult?
        coordinator.onCompletion = { completed, advance in
            result = completed
            advance()
        }

        coordinator.submit(freshRequest(.brightnessUp))
        for _ in 0..<MediaKeyFreshReadCoordinator.maximumCoalescedRepeatCount {
            XCTAssertEqual(
                coordinator.submit(freshRequest(.brightnessUp, repeatEvent: true)),
                .coalesced
            )
        }
        XCTAssertEqual(
            coordinator.submit(freshRequest(.brightnessUp, repeatEvent: true)),
            .repeatLimitReached
        )
        XCTAssertEqual(executor.pending.count, 1)
        executor.completeFirst(samples: [
            "a": DDCControlValueSample(value: 20, maximum: 100, estimated: false)
        ])
        XCTAssertEqual(
            result?.coalescedRepeatCount,
            MediaKeyFreshReadCoordinator.maximumCoalescedRepeatCount
        )
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testPendingTailRepeatCoalescesWithoutExtraRead() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var completed: [MediaKeyFreshReadResult] = []
        coordinator.onCompletion = { result, advance in
            completed.append(result)
            advance()
        }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        XCTAssertEqual(coordinator.submit(freshRequest(.volumeDown)), .queued)
        XCTAssertEqual(
            coordinator.submit(freshRequest(.volumeDown, repeatEvent: true)),
            .coalesced
        )
        XCTAssertEqual(executor.pending.count, 1)

        executor.completeFirst(samples: [:])
        XCTAssertEqual(executor.pending.count, 1)
        XCTAssertEqual(executor.pending.first?.command, .volume)
        executor.completeFirst(samples: [:])
        XCTAssertEqual(completed.map(\.coalescedRepeatCount), [0, 1])
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testNextReadWaitsUntilCurrentRoutingIsAcknowledged() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var advances: [() -> Void] = []
        coordinator.onCompletion = { _, advance in advances.append(advance) }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        XCTAssertEqual(coordinator.submit(freshRequest(.volumeDown)), .queued)
        executor.completeFirst(samples: [:])

        XCTAssertTrue(executor.pending.isEmpty)
        XCTAssertEqual(advances.count, 1)
        advances.removeFirst()()
        XCTAssertEqual(executor.pending.count, 1)
        XCTAssertEqual(executor.pending.first?.command, .volume)
        executor.completeFirst(samples: [:])
        advances.removeFirst()()
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testInterleavedRepeatPreservesFIFOOrderAtBoundary() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var router = MediaKeyDDCRouter()
        var currentValue = 98
        var completedActions: [MediaKeyAction] = []
        var writtenValues: [Int] = []
        coordinator.onCompletion = { result, advance in
            let command = result.request.event.action.command
            router.beginFreshReadRouting(command: command, targets: result.targets)
            let plan = router.plan(
                event: result.request.event,
                linkAllDisplays: false,
                targets: result.targets
            )
            completedActions.append(result.request.event.action)
            if let value = plan.requests.first?.value {
                currentValue = value
                writtenValues.append(value)
            }
            advance()
        }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessDown)), .queued)
        XCTAssertEqual(
            coordinator.submit(freshRequest(.brightnessUp, repeatEvent: true)),
            .queued
        )

        executor.completeFirst(samples: freshSamples(currentValue))
        executor.completeFirst(samples: freshSamples(currentValue))
        executor.completeFirst(samples: freshSamples(currentValue))

        XCTAssertEqual(completedActions, [.brightnessUp, .brightnessDown, .brightnessUp])
        XCTAssertEqual(writtenValues, [100, 95, 100])
        XCTAssertEqual(currentValue, 100)
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testBrightnessVolumeAndMuteBatchesAllCompleteInArrivalOrder() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var completedActions: [MediaKeyAction] = []
        coordinator.onCompletion = { result, advance in
            completedActions.append(result.request.event.action)
            advance()
        }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        XCTAssertEqual(coordinator.submit(freshRequest(.volumeDown)), .queued)
        XCTAssertEqual(coordinator.submit(freshRequest(.mute)), .queued)

        executor.completeFirst(samples: [:])
        executor.completeFirst(samples: [:])
        executor.completeFirst(samples: [:])

        XCTAssertEqual(completedActions, [.brightnessUp, .volumeDown, .mute])
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testQueueLimitReturnsExplicitDispositionWithoutReplacingEarlierBatches() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var completedActions: [MediaKeyAction] = []
        coordinator.onCompletion = { result, advance in
            completedActions.append(result.request.event.action)
            advance()
        }

        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessUp)), .started)
        let queuedActions = (0..<MediaKeyFreshReadCoordinator.maximumPendingBatchCount).map {
            $0.isMultiple(of: 2) ? MediaKeyAction.volumeDown : MediaKeyAction.mute
        }
        for action in queuedActions {
            XCTAssertEqual(coordinator.submit(freshRequest(action)), .queued)
        }
        XCTAssertEqual(coordinator.submit(freshRequest(.brightnessDown)), .queueFull)

        executor.completeFirst(samples: [:])
        for _ in queuedActions {
            executor.completeFirst(samples: [:])
        }
        XCTAssertEqual(completedActions, [.brightnessUp] + queuedActions)
        XCTAssertFalse(completedActions.contains(.brightnessDown))
    }

    func testGenerationChangeClearsQueueAndDiscardsLateFreshReadCompletion() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var completions = 0
        coordinator.onCompletion = { _, advance in
            completions += 1
            advance()
        }
        coordinator.submit(freshRequest(.volumeUp, generation: 7))
        coordinator.submit(freshRequest(.brightnessDown, generation: 7))
        coordinator.submit(freshRequest(.mute, generation: 7))

        coordinator.invalidate()
        executor.completeFirst(samples: [
            "a": DDCControlValueSample(value: 20, maximum: 100, estimated: false)
        ])
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(executor.cancelCount, 1)
        XCTAssertTrue(executor.pending.isEmpty)
    }

    func testVirtualRDPOrIncompleteTopologyProducesZeroFreshReadsAndWrites() {
        let executor = ControlledMediaKeyFreshReadExecutor()
        let coordinator = MediaKeyFreshReadCoordinator(executor: executor)
        var writes = 0
        coordinator.onCompletion = { result, advance in
            var router = MediaKeyDDCRouter()
            writes += router.plan(
                event: result.request.event,
                linkAllDisplays: result.request.linkAllDisplays,
                targets: result.targets
            ).requests.count
            advance()
        }
        let targets = [freshTarget("A")]
        for evidence in [
            DDCPhysicalEnumerationEvidence.untrusted,
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 2,
                extractedIdentityCount: 1,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 1,
                matchedPhysicalTransportCount: 1
            )
        ] {
            if MediaKeyFreshReadAdmission.allows(
                operationsAllowed: true,
                physicalEvidence: evidence,
                targets: targets
            ) {
                coordinator.submit(freshRequest(.brightnessUp))
            }
        }
        XCTAssertTrue(executor.pending.isEmpty)
        XCTAssertEqual(writes, 0)
    }

    func testFreshReadExecutorRejectsEstimatedCacheFallback() {
        let completed = expectation(description: "fresh read filtered")
        var batch = DDCReadBatchResult()
        batch.readings["A"] = [
            .luminance: DDCResolvedReading(
                reading: DDCReading(current: 70, maximum: 100, estimated: true),
                estimated: true
            )
        ]
        let executor = DDCControllerMediaKeyFreshReadExecutor(
            queue: DispatchQueue(label: "MediaKeyDDCTests.fresh-read"),
            read: { _ in batch },
            cancellation: {}
        )
        executor.execute(targets: [freshTarget("A")], command: .luminance) { samples in
            XCTAssertTrue(samples.isEmpty)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testRuntimeTraceUsesSanitizedStageNames() {
        var trace = MediaKeyRuntimeStageTrace()
        trace.beginEvent()
        trace.append(.freshReadStarted)
        trace.append(.freshReadFailed)
        trace.append(.routeBlocked)
        XCTAssertEqual(
            trace.diagnosticValue,
            "event-seen,fresh-read-started,fresh-read-failed,route-blocked"
        )
    }

    func testCapturedNormalizerIncludesSoundKeyUpButNeverTreatsItAsDDCAction() {
        let captured = MediaKeyEventNormalizer.capture(
            subtype: MediaKeyEventNormalizer.auxiliaryControlButtonsSubtype,
            data1: (0 << 16) | (MediaKeyEventNormalizer.keyUpState << 8)
        )
        XCTAssertEqual(captured, CapturedMediaKeyEvent(
            action: .volumeUp, phase: .up, isRepeat: false
        ))
        XCTAssertNil(captured?.normalizedKeyDown)
        XCTAssertEqual(MediaKeyEventTapMode.passive.options, .listenOnly)
        XCTAssertEqual(MediaKeyEventTapMode.passive.placement, .tailAppendEventTap)
        XCTAssertEqual(MediaKeyEventTapMode.activeTakeover.options, .defaultTap)
        XCTAssertEqual(MediaKeyEventTapMode.activeTakeover.placement, .headInsertEventTap)
    }

    func testTakeoverGateRequiresPermissionExactDisplayTransportAndUnwritableSystemVolume() {
        let hdmi = audioRoute(.hdmi)
        XCTAssertTrue(MediaKeyVolumeTakeoverGate.allows(
            optIn: true, accessibilityTrusted: true, route: hdmi,
            topologyTrusted: true, targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
        XCTAssertFalse(MediaKeyVolumeTakeoverGate.allows(
            optIn: false, accessibilityTrusted: true, route: hdmi,
            topologyTrusted: true, targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
        XCTAssertFalse(MediaKeyVolumeTakeoverGate.allows(
            optIn: true, accessibilityTrusted: false, route: hdmi,
            topologyTrusted: true, targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
        XCTAssertFalse(MediaKeyVolumeTakeoverGate.allows(
            optIn: true, accessibilityTrusted: true,
            route: audioRoute(.other), topologyTrusted: true,
            targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
        XCTAssertFalse(MediaKeyVolumeTakeoverGate.allows(
            optIn: true, accessibilityTrusted: true,
            route: audioRoute(.displayPort, volumeSettable: true), topologyTrusted: true,
            targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
        XCTAssertFalse(MediaKeyVolumeTakeoverGate.allows(
            optIn: true, accessibilityTrusted: true,
            route: audioRoute(.hdmi, muteSettable: true), topologyTrusted: true,
            targetCount: 1, freshTargetCount: 1,
            runtimeGenerationMatches: true, audioGenerationMatches: true
        ))
    }

    func testOptInVolumeRoutingSkipsFreshReadAndWritesForSystemManagedOutputs() {
        var freshReadCount = 0
        var writeCount = 0
        func route(_ snapshot: AudioOutputRouteSnapshot) {
            guard MediaKeyVolumeDDCRoutePolicy.allowsDDCProcessing(
                optIn: true, route: snapshot
            ) else { return }
            freshReadCount += 1
            writeCount += 1
        }

        route(audioRoute(.other)) // built-in, headphone, USB, Bluetooth, or AirPlay
        route(.unavailable)
        route(audioRoute(.hdmi, volumeSettable: true))
        route(audioRoute(.displayPort, muteSettable: true))
        XCTAssertEqual(freshReadCount, 0)
        XCTAssertEqual(writeCount, 0)

        route(audioRoute(.hdmi))
        XCTAssertEqual(freshReadCount, 1)
        XCTAssertEqual(writeCount, 1)
        XCTAssertTrue(MediaKeyVolumeDDCRoutePolicy.allowsDDCProcessing(
            optIn: false, route: audioRoute(.other)
        ))
    }

    func testCoreAudioTransportProjectionRecognizesOnlyHDMIAndDisplayPort() {
        XCTAssertEqual(AudioOutputTransport(coreAudioValue: kAudioDeviceTransportTypeHDMI), .hdmi)
        XCTAssertEqual(
            AudioOutputTransport(coreAudioValue: kAudioDeviceTransportTypeDisplayPort),
            .displayPort
        )
        XCTAssertEqual(AudioOutputTransport(coreAudioValue: kAudioDeviceTransportTypeBuiltIn), .other)
        XCTAssertEqual(AudioOutputTransport(coreAudioValue: nil), .unavailable)
    }

    func testFirstSoundPressArmsAndLongIdleStillConsumesOnlyAfterANewFreshRead() {
        var now: TimeInterval = 10
        let consumption = MediaKeyEventConsumptionController()
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeUp)),
            .passThrough
        )

        let controller = takeoverController(now: { now })
        let result = volumeReadResult(value: 40)
        controller.recordFreshRead(result)
        let requests = controller.prepare(
            requests: [volumeWrite(value: 45)], event: event(.volumeUp)
        )
        XCTAssertFalse(controller.isArmed)
        guard case .succeeded(let hud) = controller.recordCompletion(
            requests[0], succeeded: true
        ) else { return XCTFail("expected successful arming") }
        XCTAssertEqual(hud.title, "DDC 音量")
        XCTAssertEqual(hud.detail, "已提交 45 / 100（45%）")
        XCTAssertEqual(hud.fraction, 0.45, accuracy: 0.001)

        consumption.update(controller.consumptionSnapshot())
        XCTAssertEqual(consumption.disposition(for: captured(.volumeUp)), .consume)
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeUp, repeatEvent: true)),
            .consume
        )
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeUp, phase: .up)),
            .consume
        )
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeUp, phase: .up)),
            .passThrough
        )
        XCTAssertEqual(consumption.disposition(for: captured(.brightnessUp)), .passThrough)
        now += 60 * 60
        consumption.update(controller.consumptionSnapshot())
        XCTAssertEqual(consumption.disposition(for: captured(.volumeDown)), .consume)
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeDown, phase: .up)),
            .consume
        )

        // Long-idle arming is session-scoped, but the next write still requires a new read.
        controller.recordFreshRead(volumeReadResult(value: 45, action: .volumeDown))
        let afterIdle = controller.prepare(
            requests: [volumeWrite(value: 40)],
            event: NormalizedMediaKeyEvent(
                action: .volumeDown, isRepeat: false, wasConsumed: true
            )
        )
        XCTAssertEqual(afterIdle[0].origin, .mediaKey(2))
        XCTAssertEqual(controller.armedAt, 10)
    }

    func testArmedSessionCannotReusePreviousEventEvidenceAndReadFailureDisarms() {
        let withoutNewRead = takeoverController()
        withoutNewRead.recordFreshRead(volumeReadResult(value: 40))
        let first = withoutNewRead.prepare(
            requests: [volumeWrite(value: 45)], event: event(.volumeUp)
        )
        _ = withoutNewRead.recordCompletion(first[0], succeeded: true)
        XCTAssertTrue(withoutNewRead.isArmed)

        let rejected = withoutNewRead.prepare(
            requests: [volumeWrite(value: 50)],
            event: NormalizedMediaKeyEvent(
                action: .volumeUp, isRepeat: false, wasConsumed: true
            )
        )
        XCTAssertEqual(rejected[0].origin, .user)
        XCTAssertFalse(withoutNewRead.isArmed)

        let failedRead = takeoverController()
        failedRead.recordFreshRead(volumeReadResult(value: 40))
        let arming = failedRead.prepare(
            requests: [volumeWrite(value: 45)], event: event(.volumeUp)
        )
        _ = failedRead.recordCompletion(arming[0], succeeded: true)
        failedRead.recordFreshRead(MediaKeyFreshReadResult(
            request: MediaKeyFreshReadRequest(
                event: event(.volumeDown), linkAllDisplays: false,
                runtimeGeneration: 3, audioRouteGeneration: 7,
                targets: [freshTarget("A")]
            ),
            targets: [target("A", value: nil)],
            coalescedRepeatCount: 0
        ))
        XCTAssertFalse(failedRead.isArmed)
        XCTAssertEqual(failedRead.consumptionSnapshot(), .disarmed)
    }

    func testAudioOutputSwitchAndGenerationMismatchDisarmWithoutPreparingMediaWrites() {
        let controller = takeoverController()
        controller.recordFreshRead(volumeReadResult(value: 50))
        let armedRequests = controller.prepare(
            requests: [volumeWrite(value: 55)], event: event(.volumeUp)
        )
        _ = controller.recordCompletion(armedRequests[0], succeeded: true)
        XCTAssertTrue(controller.isArmed)

        controller.updateContext(takeoverContext(route: audioRoute(.other, generation: 8)))
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(controller.consumptionSnapshot(), .disarmed)

        controller.updateContext(takeoverContext(route: audioRoute(.hdmi, generation: 9)))
        controller.recordFreshRead(volumeReadResult(value: 55, audioGeneration: 7))
        let unmatched = controller.prepare(
            requests: [volumeWrite(value: 60)], event: event(.volumeUp)
        )
        XCTAssertEqual(unmatched[0].origin, .user)
    }

    func testWriteFailureAndTapDisableImmediatelyDisarmAndNextSoundEventPasses() {
        let controller = takeoverController()
        controller.recordFreshRead(volumeReadResult(value: 60))
        let first = controller.prepare(
            requests: [volumeWrite(value: 65)], event: event(.volumeUp)
        )
        _ = controller.recordCompletion(first[0], succeeded: true)
        XCTAssertTrue(controller.isArmed)

        controller.recordFreshRead(volumeReadResult(value: 65))
        let second = controller.prepare(
            requests: [volumeWrite(value: 70)],
            event: NormalizedMediaKeyEvent(
                action: .volumeUp, isRepeat: false, wasConsumed: true
            )
        )
        XCTAssertEqual(
            controller.recordCompletion(second[0], succeeded: false),
            .failed(showHUD: true)
        )
        XCTAssertFalse(controller.isArmed)

        let consumption = MediaKeyEventConsumptionController()
        consumption.update(MediaKeyConsumptionSnapshot(
            canConsumeVolume: true, canConsumeMute: true
        ))
        consumption.disarm() // same fail-open action used for event-tap timeout/disable
        XCTAssertEqual(consumption.disposition(for: captured(.volumeDown)), .passThrough)
    }

    func testTapDisableSynchronouslyFailsOpenAndClearsStaleKeyUpOwnership() {
        let consumption = MediaKeyEventConsumptionController()
        consumption.update(MediaKeyConsumptionSnapshot(
            canConsumeVolume: true, canConsumeMute: true
        ))
        XCTAssertEqual(consumption.disposition(for: captured(.volumeUp)), .consume)

        consumption.failOpenAfterTapDisabled()

        XCTAssertEqual(consumption.disposition(for: captured(.volumeDown)), .passThrough)
        XCTAssertEqual(
            consumption.disposition(for: captured(.volumeUp, phase: .up)),
            .passThrough
        )
    }

    func testAllVolumeTargetsMustCompleteBeforeArmingAndHUDDoesNotInventOneSharedValue() {
        let keys: Set<DDCWriteKey> = [
            DDCWriteKey(stableID: "A", command: .volume),
            DDCWriteKey(stableID: "B", command: .volume)
        ]
        let controller = MediaKeyVolumeTakeoverController(
            context: MediaKeyVolumeTakeoverController.Context(
                optIn: true, accessibilityTrusted: true, route: audioRoute(.hdmi),
                topologyTrusted: true, runtimeGeneration: 3, targetKeys: keys
            ),
            now: { 1 }
        )
        controller.recordFreshRead(MediaKeyFreshReadResult(
            request: MediaKeyFreshReadRequest(
                event: event(.volumeUp), linkAllDisplays: false,
                runtimeGeneration: 3, audioRouteGeneration: 7,
                targets: [freshTarget("A"), freshTarget("B")]
            ),
            targets: [target("A", value: 20), target("B", value: 45)],
            coalescedRepeatCount: 0
        ))
        let requests = controller.prepare(
            requests: [volumeWrite(value: 25), DDCWriteRequest(
                key: DDCWriteKey(stableID: "B", command: .volume),
                selector: "selector-B", value: 50
            )],
            event: event(.volumeUp)
        )
        XCTAssertEqual(controller.recordCompletion(requests[0], succeeded: true), .pending)
        XCTAssertFalse(controller.isArmed)
        guard case .succeeded(let hud) = controller.recordCompletion(
            requests[1], succeeded: true
        ) else { return XCTFail("expected all-target success") }
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(hud.detail, "已提交到 2 台显示器（25%–50%）")
    }

    func testAlreadyArmedBoundaryNoChangeConsumesFreshEvidenceAndShowsCurrentValue() {
        let controller = takeoverController()
        controller.recordFreshRead(volumeReadResult(value: 95))
        let writes = controller.prepare(
            requests: [volumeWrite(value: 100)], event: event(.volumeUp)
        )
        _ = controller.recordCompletion(writes[0], succeeded: true)
        XCTAssertTrue(controller.isArmed)

        controller.recordFreshRead(volumeReadResult(value: 100))
        let presentation = controller.noChangePresentation(for: event(.volumeUp))
        XCTAssertEqual(presentation?.detail, "当前读取 100 / 100（100%）")
        XCTAssertTrue(controller.isArmed)
    }

    func testSuccessfulVolumeWriteMakesMuteDownAndItsKeyUpConsumableForSafeRestore() {
        let controller = takeoverController()
        controller.recordFreshRead(volumeReadResult(value: 35, action: .mute))
        let writes = controller.prepare(
            requests: [volumeWrite(value: 0)], event: event(.mute)
        )
        _ = controller.recordCompletion(writes[0], succeeded: true)
        XCTAssertTrue(controller.consumptionSnapshot().canConsumeMute)

        let consumption = MediaKeyEventConsumptionController()
        consumption.update(controller.consumptionSnapshot())
        XCTAssertEqual(consumption.disposition(for: captured(.mute)), .consume)
        XCTAssertEqual(consumption.disposition(for: captured(.mute, phase: .up)), .consume)
    }

    func testTakeoverPresentationExplainsOptInPermissionAndFirstPassSafety() {
        let disabled = MediaKeyVolumeTakeoverPresentation.make(
            enabled: false, accessibilityTrusted: false, monitorState: .passive,
            route: .unavailable, armed: false
        )
        XCTAssertFalse(disabled.enabled)
        XCTAssertTrue(disabled.detail.contains("默认关闭"))
        XCTAssertTrue(disabled.detail.contains("HDMI/DisplayPort"))

        let permission = MediaKeyVolumeTakeoverPresentation.make(
            enabled: true, accessibilityTrusted: false, monitorState: .passive,
            route: audioRoute(.hdmi), armed: false
        )
        XCTAssertEqual(permission.actionTitle, "申请辅助功能权限")
        XCTAssertTrue(permission.detail.contains("不吞按键"))
        XCTAssertTrue(permission.detail.contains("仍额外执行 DDC"))

        let waiting = MediaKeyVolumeTakeoverPresentation.make(
            enabled: true, accessibilityTrusted: true, monitorState: .passive,
            route: audioRoute(.displayPort), armed: false
        )
        XCTAssertTrue(waiting.detail.contains("首次按键仍交给 macOS"))

        let systemManaged = MediaKeyVolumeTakeoverPresentation.make(
            enabled: true, accessibilityTrusted: true, monitorState: .passive,
            route: audioRoute(.other), armed: false
        )
        XCTAssertTrue(systemManaged.detail.contains("完全交给 macOS，不执行 DDC"))

        let armed = MediaKeyVolumeTakeoverPresentation.make(
            enabled: true, accessibilityTrusted: true, monitorState: .activeTakeover,
            route: audioRoute(.hdmi), armed: true
        )
        XCTAssertTrue(armed.detail.contains("每次写入前仍会重新读取显示器"))
    }

    func testHUDModelLabelsValuesAsSubmittedAndSupportsMultipleTargets() {
        let single = DDCVolumeHUDPresentation.submitted(value: 30, maximum: 60)
        XCTAssertEqual(single.detail, "已提交 30 / 60（50%）")
        XCTAssertFalse(single.isFailure)
        let multiple = DDCVolumeHUDPresentation.submitted(values: [
            (value: 20, maximum: 100), (value: 50, maximum: 100)
        ])
        XCTAssertEqual(multiple?.detail, "已提交到 2 台显示器（20%–50%）")
        XCTAssertTrue(DDCVolumeHUDPresentation.failed.isFailure)
    }

    private func event(_ action: MediaKeyAction, repeatEvent: Bool = false) -> NormalizedMediaKeyEvent {
        NormalizedMediaKeyEvent(action: action, isRepeat: repeatEvent)
    }

    private func data1(key: Int, repeatEvent: Bool = false) -> Int {
        (key << 16) | (MediaKeyEventNormalizer.keyDownState << 8) | (repeatEvent ? 1 : 0)
    }

    private func normalize(key: Int, repeatEvent: Bool = false) -> NormalizedMediaKeyEvent? {
        MediaKeyEventNormalizer.normalize(
            subtype: MediaKeyEventNormalizer.auxiliaryControlButtonsSubtype,
            data1: data1(key: key, repeatEvent: repeatEvent)
        )
    }

    private func captured(
        _ action: MediaKeyAction,
        phase: MediaKeyEventPhase = .down,
        repeatEvent: Bool = false
    ) -> CapturedMediaKeyEvent {
        CapturedMediaKeyEvent(action: action, phase: phase, isRepeat: repeatEvent)
    }

    private func audioRoute(
        _ transport: AudioOutputTransport,
        volumeSettable: Bool = false,
        muteSettable: Bool = false,
        generation: UInt64 = 7
    ) -> AudioOutputRouteSnapshot {
        AudioOutputRouteSnapshot(
            transport: transport, isAlive: true,
            systemVolumeSettable: volumeSettable,
            systemMuteSettable: muteSettable,
            isComplete: true, generation: generation
        )
    }

    private func takeoverContext(
        route: AudioOutputRouteSnapshot? = nil
    ) -> MediaKeyVolumeTakeoverController.Context {
        MediaKeyVolumeTakeoverController.Context(
            optIn: true, accessibilityTrusted: true,
            route: route ?? audioRoute(.hdmi), topologyTrusted: true,
            runtimeGeneration: 3,
            targetKeys: [DDCWriteKey(stableID: "A", command: .volume)]
        )
    }

    private func takeoverController(
        now: @escaping () -> TimeInterval = { 1 }
    ) -> MediaKeyVolumeTakeoverController {
        MediaKeyVolumeTakeoverController(context: takeoverContext(), now: now)
    }

    private func volumeReadResult(
        value: Int,
        audioGeneration: UInt64 = 7,
        action: MediaKeyAction = .volumeUp
    ) -> MediaKeyFreshReadResult {
        MediaKeyFreshReadResult(
            request: MediaKeyFreshReadRequest(
                event: event(action), linkAllDisplays: false,
                runtimeGeneration: 3, audioRouteGeneration: audioGeneration,
                targets: [freshTarget("A")]
            ),
            targets: [target("A", value: value)],
            coalescedRepeatCount: 0
        )
    }

    private func volumeWrite(value: Int) -> DDCWriteRequest {
        DDCWriteRequest(
            key: DDCWriteKey(stableID: "A", command: .volume),
            selector: "selector-A", value: value
        )
    }

    private func target(
        _ id: String,
        value: Int?,
        maximum: Int = 100,
        estimated: Bool = false
    ) -> MediaKeyDDCTarget {
        MediaKeyDDCTarget(
            stableID: id,
            selector: "selector-\(id)",
            sample: value.map {
                DDCControlValueSample(value: $0, maximum: maximum, estimated: estimated)
            }
        )
    }

    private func freshTarget(_ id: String) -> MediaKeyFreshReadTarget {
        MediaKeyFreshReadTarget(stableID: id, selector: "selector-\(id)")
    }

    private func freshSamples(_ value: Int) -> [String: DDCControlValueSample] {
        ["a": DDCControlValueSample(value: value, maximum: 100, estimated: false)]
    }

    private func freshRequest(
        _ action: MediaKeyAction,
        repeatEvent: Bool = false,
        linked: Bool = false,
        generation: UInt64 = 1,
        targets: [MediaKeyFreshReadTarget]? = nil
    ) -> MediaKeyFreshReadRequest {
        MediaKeyFreshReadRequest(
            event: event(action, repeatEvent: repeatEvent),
            linkAllDisplays: linked,
            runtimeGeneration: generation,
            targets: targets ?? [freshTarget("A")]
        )
    }
}

private final class ControlledMediaKeyWriteExecutor: DDCWriteExecuting {
    var pending: [(DDCWriteRequest, (Result<Int, Error>) -> Void)] = []
    var cancelCount = 0

    func execute(_ request: DDCWriteRequest, completion: @escaping (Result<Int, Error>) -> Void) {
        pending.append((request, completion))
    }

    func cancelAll() {
        cancelCount += 1
    }

    func completeFirst() {
        let item = pending.removeFirst()
        item.1(.success(item.0.value))
    }
}

private final class ControlledMediaKeyFreshReadExecutor: MediaKeyFreshReadExecuting {
    var pending: [(
        targets: [MediaKeyFreshReadTarget],
        command: DDCCommand,
        completion: ([String: DDCControlValueSample]) -> Void
    )] = []
    var cancelCount = 0

    func execute(
        targets: [MediaKeyFreshReadTarget],
        command: DDCCommand,
        completion: @escaping ([String: DDCControlValueSample]) -> Void
    ) {
        pending.append((targets, command, completion))
    }

    func cancelAll() {
        cancelCount += 1
    }

    func completeFirst(samples: [String: DDCControlValueSample]) {
        let item = pending.removeFirst()
        item.completion(samples)
    }
}
