import XCTest
#if SWIFT_PACKAGE
@testable import DisplaySwitcher
#endif

final class PeerProtocolTests: XCTestCase {
    private let now: TimeInterval = 1_788_000_000
    private let pairingCode = String(UUID().uuidString.prefix(12))

    private func message(
        type: PeerMessageType = .handoverRequest,
        eventID: String = UUID().uuidString,
        source: String = "windows",
        target: String = "mac",
        timestamp: TimeInterval? = nil,
        pairingCode: String? = nil,
        version: Int = 1
    ) -> PeerMessage {
        PeerMessage(
            version: version,
            type: type,
            eventID: eventID,
            source: source,
            target: target,
            timestamp: timestamp ?? now,
            pairingCode: pairingCode ?? self.pairingCode
        )
    }

    func testAcceptsValidMessage() {
        XCTAssertTrue(PeerMessageValidation.accepts(
            message(),
            pairingCode: pairingCode,
            expectedSource: "windows",
            expectedTarget: "mac",
            now: now
        ))
    }

    func testRejectsMissingOrWrongPairingCode() {
        XCTAssertFalse(PeerMessageValidation.accepts(
            message(pairingCode: ""),
            pairingCode: "",
            expectedSource: "windows",
            expectedTarget: "mac",
            now: now
        ))
        XCTAssertFalse(PeerMessageValidation.accepts(
            message(pairingCode: String(UUID().uuidString.prefix(12))),
            pairingCode: pairingCode,
            expectedSource: "windows",
            expectedTarget: "mac",
            now: now
        ))
    }

    func testRejectsExpiredWrongTargetAndMalformedEventID() {
        let variants = [
            message(timestamp: now - 10.01),
            message(source: "mac"),
            message(target: "windows"),
            message(eventID: "not-a-uuid"),
            message(version: 2)
        ]
        for value in variants {
            XCTAssertFalse(PeerMessageValidation.accepts(
                value,
                pairingCode: pairingCode,
                expectedSource: "windows",
                expectedTarget: "mac",
                now: now
            ))
        }
    }

    func testDuplicateEventDoesNotBecomeNewAction() {
        let value = message()
        var guardState = PeerReplayGuard()
        XCTAssertEqual(guardState.classify(value), .new)
        XCTAssertEqual(guardState.classify(value), .duplicate)
    }

    func testOlderHandoverIsRejectedButLaterCommittedIsIndependent() {
        let eventID = UUID().uuidString
        var guardState = PeerReplayGuard()
        XCTAssertEqual(guardState.classify(message(eventID: eventID, timestamp: now)), .new)
        XCTAssertEqual(guardState.classify(message(timestamp: now - 0.5)), .outOfOrder)
        XCTAssertEqual(guardState.classify(message(type: .committed, eventID: eventID)), .new)
    }

    func testStatusProbeCanReuseEventIDForStatusResponseType() {
        let eventID = UUID().uuidString
        var guardState = PeerReplayGuard()
        XCTAssertEqual(guardState.classify(message(type: .statusProbe, eventID: eventID)), .new)
        XCTAssertEqual(guardState.classify(message(type: .statusResponse, eventID: eventID)), .new)
    }

    func testJSONRoundTripPreservesStatusEventID() throws {
        let eventID = UUID().uuidString
        let original = message(type: .statusResponse, eventID: eventID)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PeerMessage.self, from: data)
        XCTAssertEqual(decoded.type, .statusResponse)
        XCTAssertEqual(decoded.eventID, eventID)
        XCTAssertEqual(decoded.source, "windows")
        XCTAssertEqual(decoded.target, "mac")
    }
}
