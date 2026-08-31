import XCTest

private final class InputSourceSwitchRecorder {
    private let lock = NSLock()
    private(set) var resolvedSelectors: [String] = []
    private(set) var writes: [(selector: String, value: UInt16)] = []
    private var activeWrites = 0
    private(set) var maximumConcurrentWrites = 0
    var failedSelectors = Set<String>()
    var unavailableSelectors = Set<String>()
    var readCount = 0
    var onWriteStarted: ((String) -> Void)?
    var waitBeforeWriteReturns: ((String) -> Void)?

    var resolvedSelectorsSnapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return resolvedSelectors
    }

    var writesSnapshot: [(selector: String, value: UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func recordResolve(_ selector: String) {
        lock.lock()
        resolvedSelectors.append(selector)
        lock.unlock()
    }

    func write(selector: String, value: UInt16) -> Bool {
        lock.lock()
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        writes.append((selector, value))
        let shouldFail = failedSelectors.contains(selector)
        lock.unlock()
        onWriteStarted?(selector)
        if let waitBeforeWriteReturns {
            waitBeforeWriteReturns(selector)
        } else {
            Thread.sleep(forTimeInterval: 0.001)
        }
        lock.lock()
        activeWrites -= 1
        lock.unlock()
        return !shouldFail
    }
}

private final class RecordingInputSourceTransport: InputSourceTransport {
    let selector: String
    let recorder: InputSourceSwitchRecorder

    init(selector: String, recorder: InputSourceSwitchRecorder) {
        self.selector = selector
        self.recorder = recorder
    }

    func writeInput(_ value: UInt16, context: InputSourceDiagnosticContext) -> Bool {
        recorder.write(selector: selector, value: value)
    }
}

private final class RecordingInputSourceResolver: InputSourceTransportResolving {
    let recorder: InputSourceSwitchRecorder
    weak var lastResolvedTransport: RecordingInputSourceTransport?
    private let lock = NSLock()
    private var resolvedTransportIDStorage: [ObjectIdentifier] = []

    var resolvedTransportIDs: [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return resolvedTransportIDStorage
    }

    init(recorder: InputSourceSwitchRecorder) {
        self.recorder = recorder
    }

    func resolve(selector: String, context: InputSourceDiagnosticContext) throws -> InputSourceTransport {
        recorder.recordResolve(selector)
        if recorder.unavailableSelectors.contains(selector) {
            throw InputSourceSwitchFailure.displayUnavailable(stableID: selector)
        }
        let transport = RecordingInputSourceTransport(selector: selector, recorder: recorder)
        lastResolvedTransport = transport
        lock.lock()
        resolvedTransportIDStorage.append(ObjectIdentifier(transport))
        lock.unlock()
        return transport
    }
}

private final class ManualInputSourceLeaseScheduler: InputSourceLeaseScheduling {
    private(set) var delays: [TimeInterval] = []
    private var operations: [() -> Void] = []

    func schedule(after delay: TimeInterval, _ operation: @escaping () -> Void) {
        delays.append(delay)
        operations.append(operation)
    }

    func runAll() {
        let pending = operations
        operations.removeAll()
        pending.forEach { $0() }
    }
}

final class InputSourceSwitchingTests: XCTestCase {
    func testEveryEventResolvesFreshTransportAndLeaseReleasesAfterOneSecond() {
        let recorder = InputSourceSwitchRecorder()
        let resolver = RecordingInputSourceResolver(recorder: recorder)
        let scheduler = ManualInputSourceLeaseScheduler()
        let retainer = InputSourceTransportLeaseRetainer(scheduler: scheduler)
        let service = InputSourceSwitchService(
            resolver: resolver,
            hardwareArbiter: NativeI2CHardwareArbiter(),
            leaseRetainer: retainer
        )
        let target = InputSourceSwitchTarget(
            stableID: "display-a", selector: "selector-a", targetInput: 17
        )

        XCTAssertTrue(service.switchInputs([target]).allSucceeded)
        XCTAssertNotNil(resolver.lastResolvedTransport)
        XCTAssertEqual(retainer.activeLeaseCount, 1)
        XCTAssertEqual(scheduler.delays, [1])
        XCTAssertTrue(service.switchInputs([target]).allSucceeded)
        XCTAssertNotEqual(resolver.resolvedTransportIDs[0], resolver.resolvedTransportIDs[1])
        XCTAssertEqual(retainer.activeLeaseCount, 2)
        XCTAssertEqual(recorder.resolvedSelectors, ["selector-a", "selector-a"])
        XCTAssertEqual(recorder.writes.map(\.value), [17, 17])
        XCTAssertEqual(recorder.readCount, 0)

        scheduler.runAll()
        XCTAssertNil(resolver.lastResolvedTransport)
        XCTAssertEqual(retainer.activeLeaseCount, 0)
    }

    func testRapidSwitchesKeepLeaseCountBounded() {
        let recorder = InputSourceSwitchRecorder()
        let scheduler = ManualInputSourceLeaseScheduler()
        let retainer = InputSourceTransportLeaseRetainer(
            scheduler: scheduler, leaseDuration: 1, maximumLeaseCount: 4
        )
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter(),
            leaseRetainer: retainer
        )
        let target = InputSourceSwitchTarget(
            stableID: "display-a", selector: "selector-a", targetInput: 17
        )

        for _ in 0..<100 {
            XCTAssertTrue(service.switchInputs([target]).allSucceeded)
            XCTAssertLessThanOrEqual(retainer.activeLeaseCount, 4)
        }

        XCTAssertEqual(recorder.resolvedSelectors.count, 100)
        XCTAssertEqual(recorder.writes.count, 100)
        XCTAssertEqual(retainer.activeLeaseCount, 4)
        scheduler.runAll()
        XCTAssertEqual(retainer.activeLeaseCount, 0)
    }

    func testDifferentDisplaysStartConcurrentlyAndFailureDoesNotCancelOtherTargets() {
        let recorder = InputSourceSwitchRecorder()
        recorder.failedSelectors = ["selector-b"]
        let bothStarted = expectation(description: "both displays started")
        bothStarted.expectedFulfillmentCount = 2
        let releases: [String: DispatchSemaphore] = [
            "selector-a": DispatchSemaphore(value: 0),
            "selector-b": DispatchSemaphore(value: 0)
        ]
        recorder.onWriteStarted = { _ in bothStarted.fulfill() }
        recorder.waitBeforeWriteReturns = { selector in releases[selector]?.wait() }
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter()
        )
        let targets = [
            InputSourceSwitchTarget(stableID: "display-a", selector: "selector-a", targetInput: 17),
            InputSourceSwitchTarget(stableID: "display-b", selector: "selector-b", targetInput: 18)
        ]

        let completed = expectation(description: "batch completed")
        let resultLock = NSLock()
        var capturedResult: InputSourceSwitchBatchResult?
        DispatchQueue.global().async {
            let result = service.switchInputs(targets)
            resultLock.lock()
            capturedResult = result
            resultLock.unlock()
            completed.fulfill()
        }
        wait(for: [bothStarted], timeout: 1)
        XCTAssertEqual(recorder.maximumConcurrentWrites, 2)
        releases.values.forEach { $0.signal() }
        wait(for: [completed], timeout: 1)
        resultLock.lock()
        let result = capturedResult
        resultLock.unlock()

        XCTAssertFalse(result?.allSucceeded ?? true)
        XCTAssertEqual(Set(recorder.resolvedSelectors), Set(["selector-a", "selector-b"]))
        XCTAssertEqual(Set(recorder.writes.map(\.selector)), Set(["selector-a", "selector-b"]))
        XCTAssertEqual(result?.outcomes, [
            InputSourceSwitchOutcome(stableID: "display-a", failure: nil),
            InputSourceSwitchOutcome(stableID: "display-b", failure: .writeFailed(stableID: "display-b"))
        ])
    }

    func testSameDisplayNeverWritesConcurrently() {
        let recorder = InputSourceSwitchRecorder()
        let firstStarted = expectation(description: "first write started")
        let secondStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let countLock = NSLock()
        var startedCount = 0
        recorder.onWriteStarted = { _ in
            countLock.lock()
            startedCount += 1
            let count = startedCount
            countLock.unlock()
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.signal() }
        }
        recorder.waitBeforeWriteReturns = { _ in release.wait() }
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter()
        )
        let completed = expectation(description: "same display operations completed")
        completed.expectedFulfillmentCount = 2
        let target = InputSourceSwitchTarget(
            stableID: "display-a", selector: "selector-a", targetInput: 17
        )
        DispatchQueue.global().async {
            _ = service.switchInputs([target])
            completed.fulfill()
        }
        DispatchQueue.global().async {
            _ = service.switchInputs([target])
            completed.fulfill()
        }

        wait(for: [firstStarted], timeout: 1)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        release.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(recorder.maximumConcurrentWrites, 1)
    }

    func testDuplicateDisplayInOneBatchWritesOnceAndPreservesOutcomes() {
        let recorder = InputSourceSwitchRecorder()
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter()
        )

        let result = service.switchInputs([
            InputSourceSwitchTarget(
                stableID: "display-a", selector: "selector-a", targetInput: 17
            ),
            InputSourceSwitchTarget(
                stableID: "display-a-copy", selector: "SELECTOR-A", targetInput: 17
            )
        ])

        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(result.outcomes, [
            InputSourceSwitchOutcome(stableID: "display-a", failure: nil),
            InputSourceSwitchOutcome(stableID: "display-a-copy", failure: nil)
        ])
    }

    func testResolverFailureIsAttributedToStableIDAndDoesNotSkipNextTarget() {
        let recorder = InputSourceSwitchRecorder()
        recorder.unavailableSelectors = ["selector-a"]
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter()
        )

        let result = service.switchInputs([
            InputSourceSwitchTarget(stableID: "display-a", selector: "selector-a", targetInput: 17),
            InputSourceSwitchTarget(stableID: "display-b", selector: "selector-b", targetInput: 18)
        ])

        XCTAssertEqual(result.outcomes, [
            InputSourceSwitchOutcome(
                stableID: "display-a", failure: .displayUnavailable(stableID: "display-a")
            ),
            InputSourceSwitchOutcome(stableID: "display-b", failure: nil)
        ])
        // Different displays resolve concurrently; resolver call order is intentionally not a contract.
        let resolvedSelectors = recorder.resolvedSelectorsSnapshot
        XCTAssertEqual(resolvedSelectors.count, 2)
        XCTAssertEqual(Set(resolvedSelectors), Set(["selector-a", "selector-b"]))
        XCTAssertEqual(recorder.writesSnapshot.map(\.selector), ["selector-b"])
    }

    func testOrdinaryFailureAndValueCacheRemainIndependentFromInputSwitch() throws {
        let suiteName = "InputSourceSwitchingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsDDCValueCache(defaults: defaults)
        cache.setValue(42, stableID: "display-a", command: .luminance)
        let arbiter = NativeI2CHardwareArbiter()
        XCTAssertThrowsError(try arbiter.withControlOperation {
            throw DDCBackendError.readFailed(stableID: "display-a", command: .luminance)
        })
        let recorder = InputSourceSwitchRecorder()
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: arbiter
        )

        let result = service.switchInputs([
            InputSourceSwitchTarget(stableID: "display-a", selector: "selector-a", targetInput: 17)
        ])

        XCTAssertTrue(result.allSucceeded)
        XCTAssertEqual(cache.value(stableID: "display-a", command: .luminance), 42)
        XCTAssertNil(cache.value(stableID: "display-a", command: .input))
        XCTAssertEqual(recorder.readCount, 0)
    }

    func testWaitingInputSwitchRunsBeforeQueuedControlOperation() {
        let arbiter = NativeI2CHardwareArbiter()
        let queue = DispatchQueue(label: "InputSourceSwitchingTests.arbiter", attributes: .concurrent)
        let firstControlEntered = expectation(description: "first control entered")
        let releaseFirstControl = DispatchSemaphore(value: 0)
        let finished = expectation(description: "all operations finished")
        finished.expectedFulfillmentCount = 3
        let orderLock = NSLock()
        var order: [String] = []

        queue.async {
            arbiter.withControlOperation(displayKey: "selector-a") {
                firstControlEntered.fulfill()
                releaseFirstControl.wait()
                orderLock.lock(); order.append("control-1"); orderLock.unlock()
            }
            finished.fulfill()
        }
        wait(for: [firstControlEntered], timeout: 1)

        queue.async {
            arbiter.withInputSwitch(displayKey: "selector-a") {
                orderLock.lock(); order.append("input"); orderLock.unlock()
            }
            finished.fulfill()
        }
        let deadline = Date().addingTimeInterval(1)
        while arbiter.waitingInputSwitchCount == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(arbiter.waitingInputSwitchCount, 1)

        queue.async {
            arbiter.withControlOperation(displayKey: "selector-a") {
                orderLock.lock(); order.append("control-2"); orderLock.unlock()
            }
            finished.fulfill()
        }
        releaseFirstControl.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(order, ["control-1", "input", "control-2"])
    }

    func testControlOnOneDisplayDoesNotBlockInputSwitchOnAnotherDisplay() {
        let arbiter = NativeI2CHardwareArbiter()
        let queue = DispatchQueue(label: "InputSourceSwitchingTests.display-lanes", attributes: .concurrent)
        let controlEntered = expectation(description: "display A control entered")
        let inputEntered = expectation(description: "display B input entered")
        let releaseControl = DispatchSemaphore(value: 0)

        queue.async {
            arbiter.withControlOperation(displayKey: "selector-a") {
                controlEntered.fulfill()
                releaseControl.wait()
            }
        }
        wait(for: [controlEntered], timeout: 1)
        queue.async {
            arbiter.withInputSwitch(displayKey: "selector-b") {
                inputEntered.fulfill()
            }
        }

        wait(for: [inputEntered], timeout: 1)
        releaseControl.signal()
    }

    func testBlockedMissingAndInvalidTargetsPerformNoResolveOrWrite() {
        let recorder = InputSourceSwitchRecorder()
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter()
        )
        let invalidResult = service.switchInputs([
            InputSourceSwitchTarget(stableID: "missing", selector: "selector-b", targetInput: nil),
            InputSourceSwitchTarget(stableID: "invalid", selector: "selector-c", targetInput: -1)
        ])
        let blockedResult = service.switchInputs([
            InputSourceSwitchTarget(stableID: "blocked", selector: "selector-a", targetInput: 17)
        ]) { false }

        XCTAssertEqual(invalidResult.outcomes.map(\.failure), [
            .missingInput(stableID: "missing"),
            .invalidInput(stableID: "invalid", value: -1)
        ])
        XCTAssertEqual(blockedResult.firstFailure, .blocked(stableID: "blocked"))
        XCTAssertTrue(recorder.resolvedSelectors.isEmpty)
        XCTAssertTrue(recorder.writes.isEmpty)
    }

    func testDiagnosticChainReachesWriteAdapterAndSeparatesTransportFromDeviceFeedback() {
        let recorder = InputSourceSwitchRecorder()
        let diagnostics = InputSourceDiagnosticStore()
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter(),
            diagnostics: diagnostics
        )

        let result = service.switchInputs([
            InputSourceSwitchTarget(
                stableID: "private-display-id",
                selector: "selector-a",
                targetInput: 17,
                alternateInput: 15
            )
        ], origin: .usb)

        XCTAssertTrue(result.allSucceeded)
        XCTAssertEqual(recorder.writes.map(\.value), [17])
        let text = diagnostics.exportText()
        XCTAssertTrue(text.contains("stage=target-queued origin=usb vcp=0x60 value=17"))
        XCTAssertTrue(text.contains("op=O1 display=D1"))
        XCTAssertTrue(text.contains("stage=resolver-started"))
        XCTAssertTrue(text.contains("stage=write-adapter-reached vcp=0x60"))
        XCTAssertTrue(text.contains("kern-success-observed=true device-executed=unknown"))
        XCTAssertFalse(text.contains("private-display-id"))
        XCTAssertNil(text.range(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            options: .regularExpression
        ))
    }

    func testCandidateEvidenceRecordsSelectionWithoutPrivateIdentity() {
        let identity = NativeDisplayIdentity(
            stableID: "private-uuid",
            ioDisplayLocation: "private-registry-location",
            productName: "private-product-name",
            serialNumber: 987_654,
            edidSearchKeys: [NativeEDIDSearchKey(value: "ABCD", offset: 0)]
        )
        let candidates = [
            NativeTransportCandidate(
                serviceLocation: 11,
                ioDisplayLocation: "private-registry-location",
                productName: "private-product-name",
                serialNumber: 987_654,
                edidUUID: "ABCD0000",
                transportPath: .typeCDPAlt
            ),
            NativeTransportCandidate(
                serviceLocation: 12,
                ioDisplayLocation: "other-private-location",
                productName: "other-private-name",
                serialNumber: 123_456,
                edidUUID: "FFFF0000",
                transportPath: .unknownExternal
            )
        ]

        let evidence = NativeInputCandidateDiagnosticProjection.evidence(
            identity: identity,
            candidates: candidates,
            selectedServiceLocation: 11,
            anonymousServiceID: { location in location == 11 ? "S1" : "S2" }
        )

        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence.map(\.anonymousID), ["S1", "S2"])
        XCTAssertEqual(evidence.filter(\.selected).map(\.anonymousID), ["S1"])
        XCTAssertGreaterThan(evidence[0].score, evidence[1].score)
        let description = evidence.map(\.safeDescription).joined(separator: " ")
        for secret in [
            "private-uuid", "private-registry-location", "private-product-name",
            "987654", "other-private-location", "other-private-name"
        ] {
            XCTAssertFalse(description.contains(secret))
        }
    }

    func testServiceAnonymousIDsRemainStableWhenCandidateEnumerationReorders() {
        let diagnostics = InputSourceDiagnosticStore()
        XCTAssertEqual(diagnostics.anonymousServiceID(for: 91), "S1")
        XCTAssertEqual(diagnostics.anonymousServiceID(for: 42), "S2")
        XCTAssertEqual(diagnostics.anonymousServiceID(for: 42), "S2")
        XCTAssertEqual(diagnostics.anonymousServiceID(for: 91), "S1")
    }

    func testMultipleCandidateDiagnosticsDoNotCauseWritesToAlternateCandidates() {
        let recorder = InputSourceSwitchRecorder()
        let diagnostics = InputSourceDiagnosticStore()
        let service = InputSourceSwitchService(
            resolver: RecordingInputSourceResolver(recorder: recorder),
            hardwareArbiter: NativeI2CHardwareArbiter(),
            diagnostics: diagnostics
        )
        let context = diagnostics.beginTarget(
            origin: .manualOrCollaboration,
            stableID: "display-a",
            targetValue: 17,
            alternateValue: nil
        )
        diagnostics.record(.candidates([
            InputSourceCandidateEvidence(
                anonymousID: "S1", transportType: "typec-dp-alt",
                locationMatched: true, productNameMatched: true, serialMatched: false,
                edidMatchCount: 1, score: 12, selected: true
            ),
            InputSourceCandidateEvidence(
                anonymousID: "S2", transportType: "unknown-external",
                locationMatched: false, productNameMatched: true, serialMatched: false,
                edidMatchCount: 1, score: 2, selected: false
            )
        ]), context: context)

        XCTAssertTrue(service.switchInputs([
            InputSourceSwitchTarget(stableID: "display-a", selector: "selector-a", targetInput: 17)
        ]).allSucceeded)
        XCTAssertEqual(recorder.resolvedSelectors, ["selector-a"])
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertTrue(diagnostics.exportText().contains("stage=candidates count=2"))
    }

    func testDiagnosticWriteCallAndFeedbackRemainDistinctAndSanitized() {
        let diagnostics = InputSourceDiagnosticStore()
        let context = diagnostics.beginTarget(
            origin: .manualOrCollaboration,
            stableID: "private-display-uuid",
            targetValue: 17,
            alternateValue: 15
        )
        let started = Date(timeIntervalSince1970: 1)
        diagnostics.record(.writeCall(
            attempt: 1,
            cycle: 2,
            frameHex: "84 03 60 00 11 AA",
            chip: 0x37,
            address: 0x51,
            offset: 0x51,
            startedAt: started,
            endedAt: started.addingTimeInterval(0.001),
            returnCode: 0,
            durationMicroseconds: 1_000
        ), context: context)
        diagnostics.record(.writeTransportResult(acceptedByTransport: true), context: context)
        diagnostics.record(.deviceFeedback(.alternateValue(
            value: 15, maximum: 255, estimated: false
        )), context: context)

        let text = diagnostics.exportText()
        XCTAssertTrue(text.contains("stage=write-i2c attempt=1 cycle=2 vcp=0x60"))
        XCTAssertTrue(text.contains("frame=84 03 60 00 11 AA chip=0x37"))
        XCTAssertTrue(text.contains("kern-success-observed=true device-executed=unknown"))
        XCTAssertTrue(text.contains("stage=device-feedback alternate-value current=15"))
        XCTAssertFalse(text.contains("private-display-uuid"))
    }
}
