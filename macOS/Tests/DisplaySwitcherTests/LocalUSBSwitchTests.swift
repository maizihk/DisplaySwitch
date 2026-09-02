import Foundation
import XCTest

final class LocalUSBSwitchTests: XCTestCase {
    func testAllSixteenPublicUSBSwitchVectors() throws {
        let url = try XCTUnwrap(Bundle(for: LocalUSBSwitchTests.self).resourceURL)
            .appendingPathComponent("contracts/usb-switch-v1/usb-switch-vectors.json")
        let file = try JSONDecoder().decode(USBVectorFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.configSchemaVersion, 5)
        XCTAssertEqual(file.wakeCoalescingWindowMs, 2_000)
        XCTAssertEqual(file.vectors.count, 16)

        for vector in file.vectors {
            let clock = USBVectorClock()
            let sink = USBVectorSink(clock: clock, mappings: vector.initialState.displayMappings)
            let configuration = LocalUSBSwitchRuntimeConfiguration(
                enabled: vector.initialState.enabled,
                learning: vector.initialState.learning,
                safeState: vector.initialState.safeState,
                collaborationWakeEnabled: vector.initialState.collaborationWakeEnabled,
                collaborationProfileValid: vector.initialState.collaborationProfileValid,
                displays: vector.initialState.displayMappings.map {
                    LocalUSBSwitchDisplay(displayID: $0.displayID, targetInput: $0.targetInput, available: $0.available)
                }
            )
            let coordinator = LocalUSBSwitchCoordinator(
                configuration: configuration,
                baselinePresence: vector.initialState.baselinePresence,
                sink: sink,
                nowMs: { clock.nowMs }
            )

            for input in vector.inputs {
                clock.nowMs = Int64(input.atMs)
                switch input.kind {
                case "observeUSB":
                    if coordinator.observeUSB(present: try XCTUnwrap(input.present)) {
                        sink.actions.append(USBTimedAction(atMs: input.atMs, kind: "establishBaseline"))
                    }
                case "configurationChanged":
                    coordinator.configurationChanged()
                case "receiveWakeDisplay":
                    coordinator.receiveAuthenticatedWakeDisplay()
                default:
                    XCTFail("Unsupported USB vector input \(input.kind)")
                }
            }

            let expectedActions = vector.expectedActions.map(USBTimedAction.init(expected:))
            XCTAssertEqual(sink.actions, expectedActions,
                           "\(vector.id): \(vector.description)")
        }
    }

    func testBlankDisplayIsSkippedWhileOtherDisplaysStillSwitch() {
        let clock = USBVectorClock()
        let mappings = [
            USBVectorMapping(displayID: "display-a", targetInput: 17, available: true, switchSucceeds: true),
            USBVectorMapping(displayID: "display-b", targetInput: nil, available: true, switchSucceeds: true),
            USBVectorMapping(displayID: "display-c", targetInput: 18, available: true, switchSucceeds: true)
        ]
        let sink = USBVectorSink(clock: clock, mappings: mappings)
        let coordinator = LocalUSBSwitchCoordinator(
            configuration: LocalUSBSwitchRuntimeConfiguration(
                enabled: true, learning: false, safeState: false,
                collaborationWakeEnabled: false, collaborationProfileValid: false,
                displays: mappings.map {
                    LocalUSBSwitchDisplay(
                        displayID: $0.displayID, targetInput: $0.targetInput, available: $0.available
                    )
                }
            ),
            baselinePresence: true,
            sink: sink,
            nowMs: { 10 }
        )

        _ = coordinator.observeUSB(present: false)

        XCTAssertEqual(sink.actions.filter { $0.kind == "switchDisplay" }.map(\.displayID), [
            "display-a", "display-c"
        ])
        XCTAssertFalse(sink.actions.contains { $0.kind == "switchDisplay" && $0.displayID == "display-b" })
        XCTAssertTrue(sink.actions.contains {
            $0.kind == "report"
                && $0.displayID == "display-b"
                && $0.reason == LocalUSBSwitchReportReason.missingMapping.rawValue
        })
    }

    func testZeroMappingProducesNoWriteAndReportsSafeValidationFailure() {
        let clock = USBVectorClock()
        let mapping = USBVectorMapping(
            displayID: "display-a", targetInput: 0, available: true, switchSucceeds: true
        )
        let sink = USBVectorSink(clock: clock, mappings: [mapping])
        let coordinator = LocalUSBSwitchCoordinator(
            configuration: LocalUSBSwitchRuntimeConfiguration(
                enabled: true, learning: false, safeState: false,
                collaborationWakeEnabled: false, collaborationProfileValid: false,
                displays: [LocalUSBSwitchDisplay(
                    displayID: mapping.displayID, targetInput: mapping.targetInput, available: true
                )]
            ),
            baselinePresence: true,
            sink: sink,
            nowMs: { 10 }
        )

        _ = coordinator.observeUSB(present: false)

        XCTAssertFalse(sink.actions.contains { $0.kind == "switchDisplay" })
        XCTAssertEqual(sink.actions.map(\.reason), [LocalUSBSwitchReportReason.invalidMapping.rawValue])
    }

    func testStoredUSBReferenceMatchesOnlyTheExplicitlyLearnedDevice() throws {
        let selected = USBDevice(vendorID: 1_111, productID: 2_222,
                                 name: "Selected device", serialNumber: "local-serial-a")
        let sameModel = USBDevice(vendorID: 1_111, productID: 2_222,
                                  name: "Selected device", serialNumber: "local-serial-b")
        let reference = try XCTUnwrap(USBDeviceReference(localReference: selected.localReference))

        XCTAssertTrue(reference.matches(selected))
        XCTAssertFalse(reference.matches(sameModel))
    }

    func testUSBDisplayNameDoesNotExposeRawIdentifiers() {
        let device = USBDevice(vendorID: 1_111, productID: 2_222,
                               name: "Selected device", serialNumber: "local-serial")

        XCTAssertEqual(device.displayName, "Selected device")
        XCTAssertFalse(device.displayName.contains("1111"))
        XCTAssertFalse(device.displayName.contains("2222"))
        XCTAssertFalse(device.displayName.contains("local-serial"))
    }

    func testUSBDepartureEntersDifferentDisplayWritesBeforeEitherCompletes() {
        let firstStarted = expectation(description: "first display write entered")
        let secondStarted = expectation(description: "second display write entered")
        let completed = expectation(description: "USB departure batch completed")
        let releaseWrites = DispatchSemaphore(value: 0)
        let resolver = USBEntryResolver { selector in
            USBEntryTransport(succeeds: selector != "selector-a") {
                (selector == "selector-a" ? firstStarted : secondStarted).fulfill()
                releaseWrites.wait()
            }
        }
        let sink = USBEntryBatchSink(resolver: resolver) { outcomes in
            XCTAssertEqual(outcomes, [
                LocalUSBDisplaySwitchOutcome(displayID: "selector-a", succeeded: false),
                LocalUSBDisplaySwitchOutcome(displayID: "selector-b", succeeded: true)
            ])
            completed.fulfill()
        }
        let coordinator = makeDepartureCoordinator(
            displayIDs: ["selector-a", "selector-b"], sink: sink
        )

        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.observeUSB(present: false)
        }

        wait(for: [firstStarted, secondStarted], timeout: 1)
        releaseWrites.signal()
        releaseWrites.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(Set(resolver.resolvedSelectors), Set(["selector-a", "selector-b"]))
        XCTAssertEqual(sink.reportedFailures, ["selector-a"])
    }

    func testUSBDepartureDeduplicatesSameDisplayInsideOneBatch() {
        let resolver = USBEntryResolver { _ in USBEntryTransport(succeeds: true) {} }
        let completed = expectation(description: "duplicate USB batch completed")
        let sink = USBEntryBatchSink(resolver: resolver) { outcomes in
            XCTAssertEqual(outcomes.count, 2)
            XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
            completed.fulfill()
        }
        let coordinator = makeDepartureCoordinator(
            displayIDs: ["selector-a", "SELECTOR-A"], sink: sink
        )

        _ = coordinator.observeUSB(present: false)

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(resolver.resolvedSelectors, ["selector-a"])
    }

    private func makeDepartureCoordinator(
        displayIDs: [String],
        sink: LocalUSBSwitchActionSink
    ) -> LocalUSBSwitchCoordinator {
        LocalUSBSwitchCoordinator(
            configuration: LocalUSBSwitchRuntimeConfiguration(
                enabled: true,
                learning: false,
                safeState: false,
                collaborationWakeEnabled: false,
                collaborationProfileValid: false,
                displays: displayIDs.map {
                    LocalUSBSwitchDisplay(displayID: $0, targetInput: 17, available: true)
                }
            ),
            baselinePresence: true,
            sink: sink,
            nowMs: { 0 }
        )
    }
}

private struct USBVectorFile: Decodable {
    let configSchemaVersion: Int
    let wakeCoalescingWindowMs: Int
    let vectors: [USBVector]
}

private struct USBVector: Decodable {
    let id: String
    let description: String
    let initialState: USBVectorInitialState
    let inputs: [USBVectorInput]
    let expectedActions: [USBExpectedAction]
}

private struct USBVectorInitialState: Decodable {
    let enabled: Bool
    let learning: Bool
    let safeState: Bool
    let baselinePresence: Bool?
    let collaborationWakeEnabled: Bool
    let collaborationProfileValid: Bool
    let displayMappings: [USBVectorMapping]
}

private struct USBVectorMapping: Decodable {
    let displayID: String
    let targetInput: Int?
    let available: Bool
    let switchSucceeds: Bool
}

private struct USBVectorInput: Decodable {
    let atMs: Int
    let kind: String
    let present: Bool?
}

private struct USBExpectedAction: Decodable {
    let atMs: Int
    let kind: String
    let displayID: String?
    let targetInput: Int?
    let succeeded: Bool?
    let reason: String?
}

private struct USBTimedAction: Equatable {
    let atMs: Int
    let kind: String
    var displayID: String? = nil
    var targetInput: Int? = nil
    var succeeded: Bool? = nil
    var reason: String? = nil

    init(atMs: Int, kind: String) {
        self.atMs = atMs
        self.kind = kind
    }

    init(atMs: Int, kind: String, displayID: String?, targetInput: Int?, succeeded: Bool?, reason: String?) {
        self.atMs = atMs
        self.kind = kind
        self.displayID = displayID
        self.targetInput = targetInput
        self.succeeded = succeeded
        self.reason = reason
    }

    init(expected: USBExpectedAction) {
        atMs = expected.atMs
        kind = expected.kind
        displayID = expected.displayID
        targetInput = expected.targetInput
        succeeded = expected.succeeded
        reason = expected.reason
    }
}

private final class USBVectorClock { var nowMs: Int64 = 0 }

private final class USBVectorSink: LocalUSBSwitchActionSink {
    let clock: USBVectorClock
    let mappings: [String: USBVectorMapping]
    var actions: [USBTimedAction] = []

    init(clock: USBVectorClock, mappings: [USBVectorMapping]) {
        self.clock = clock
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.displayID, $0) })
    }

    func switchUSBDisplays(
        _ requests: [LocalUSBDisplaySwitchRequest],
        completion: @escaping (LocalUSBDisplaySwitchOutcome) -> Void
    ) {
        for request in requests {
            let success = mappings[request.displayID]?.switchSucceeds ?? false
            actions.append(USBTimedAction(atMs: Int(clock.nowMs), kind: "switchDisplay",
                                          displayID: request.displayID, targetInput: request.targetInput,
                                          succeeded: success, reason: nil))
            completion(LocalUSBDisplaySwitchOutcome(displayID: request.displayID, succeeded: success))
        }
    }

    func wakeUSBDisplay() {
        actions.append(USBTimedAction(atMs: Int(clock.nowMs), kind: "wakeDisplay"))
    }

    func sendCollaborationWakeDisplay() -> Bool {
        actions.append(USBTimedAction(atMs: Int(clock.nowMs), kind: "sendWakeDisplay"))
        return true
    }

    func reportUSBSwitch(displayID: String?, reason: LocalUSBSwitchReportReason) {
        actions.append(USBTimedAction(atMs: Int(clock.nowMs), kind: "report",
                                      displayID: displayID, targetInput: nil,
                                      succeeded: nil, reason: reason.rawValue))
    }
}

private final class USBEntryTransport: InputSourceTransport {
    private let succeeds: Bool
    private let beforeWrite: () -> Void

    init(succeeds: Bool, beforeWrite: @escaping () -> Void) {
        self.succeeds = succeeds
        self.beforeWrite = beforeWrite
    }

    func writeInput(_ value: UInt16, context: InputSourceDiagnosticContext) -> Bool {
        beforeWrite()
        return succeeds
    }
}

private final class USBEntryResolver: InputSourceTransportResolving {
    private let lock = NSLock()
    private let makeTransport: (String) -> InputSourceTransport
    private(set) var resolvedSelectors: [String] = []

    init(makeTransport: @escaping (String) -> InputSourceTransport) {
        self.makeTransport = makeTransport
    }

    func resolve(selector: String, context: InputSourceDiagnosticContext) throws -> InputSourceTransport {
        lock.lock()
        resolvedSelectors.append(selector)
        lock.unlock()
        return makeTransport(selector)
    }
}

private final class USBEntryBatchSink: LocalUSBSwitchActionSink {
    private let service: InputSourceSwitchService
    private let completionObserver: ([LocalUSBDisplaySwitchOutcome]) -> Void
    private(set) var reportedFailures: [String] = []

    init(
        resolver: InputSourceTransportResolving,
        completionObserver: @escaping ([LocalUSBDisplaySwitchOutcome]) -> Void
    ) {
        service = InputSourceSwitchService(
            resolver: resolver,
            hardwareArbiter: NativeI2CHardwareArbiter()
        )
        self.completionObserver = completionObserver
    }

    func switchUSBDisplays(
        _ requests: [LocalUSBDisplaySwitchRequest],
        completion: @escaping (LocalUSBDisplaySwitchOutcome) -> Void
    ) {
        let result = service.switchInputs(requests.map {
            InputSourceSwitchTarget(
                stableID: $0.displayID,
                selector: $0.displayID,
                targetInput: $0.targetInput
            )
        }, origin: .usb)
        let outcomes = zip(requests, result.outcomes).map {
            LocalUSBDisplaySwitchOutcome(displayID: $0.0.displayID, succeeded: $0.1.succeeded)
        }
        outcomes.forEach(completion)
        completionObserver(outcomes)
    }

    func wakeUSBDisplay() {}
    func sendCollaborationWakeDisplay() -> Bool { true }

    func reportUSBSwitch(displayID: String?, reason: LocalUSBSwitchReportReason) {
        if reason == .ddcFailed, let displayID {
            reportedFailures.append(displayID)
        }
    }
}
