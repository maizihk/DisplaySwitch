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
