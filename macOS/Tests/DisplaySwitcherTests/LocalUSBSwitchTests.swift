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

            XCTAssertEqual(sink.actions, vector.expectedActions.map(USBTimedAction.init(expected:)),
                           "\(vector.id): \(vector.description)")
        }
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

    func switchUSBDisplay(displayID: String, targetInput: Int, completion: @escaping (Bool) -> Void) {
        let success = mappings[displayID]?.switchSucceeds ?? false
        actions.append(USBTimedAction(atMs: Int(clock.nowMs), kind: "switchDisplay",
                                      displayID: displayID, targetInput: targetInput,
                                      succeeded: success, reason: nil))
        completion(success)
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
