import XCTest

final class DiagnosticRecordingTests: XCTestCase {
    func testPreferenceDefaultsOffAndPersistsExplicitChoice() {
        let suiteName = "DiagnosticRecordingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preference = DetailedDiagnosticRecordingPreference(defaults: defaults)

        XCTAssertFalse(preference.isEnabled)
        preference.setEnabled(true)
        XCTAssertTrue(preference.isEnabled)
        XCTAssertTrue(DetailedDiagnosticRecordingPreference(defaults: defaults).isEnabled)
        preference.setEnabled(false)
        XCTAssertFalse(preference.isEnabled)
    }

    func testInputSourceStoreRecordsOnlyWhileEnabledAndClearRemovesSession() {
        var enabled = false
        let store = InputSourceDiagnosticStore(recordingEnabled: { enabled })

        var context = store.beginTarget(
            origin: .usb, stableID: "private-display", targetValue: 17, alternateValue: nil
        )
        store.record(.resolverStarted, context: context)
        XCTAssertTrue(store.exportText().contains("recording is disabled"))
        XCTAssertFalse(store.exportText().contains("private-display"))

        enabled = true
        context = store.beginTarget(
            origin: .usb, stableID: "private-display", targetValue: 17, alternateValue: nil
        )
        store.record(.resolverStarted, context: context)
        XCTAssertTrue(store.exportText().contains("stage=resolver-started"))

        store.clear()
        XCTAssertFalse(store.exportText().contains("stage=resolver-started"))
    }

    func testPeerStoreRecordsOnlyWhileEnabledAndClearRemovesSession() {
        var enabled = false
        let store = PeerInspectionDiagnosticStore(
            nowMs: { 1_000 }, recordingEnabled: { enabled }
        )

        var context = store.begin(eventID: "event-a", targetHost: "private-host", targetPort: 49_731)
        store.record(.sendStarted(listeningPort: 49_731), context: context)
        XCTAssertTrue(store.exportText().contains("recording is disabled"))
        XCTAssertFalse(store.exportText().contains("private-host"))

        enabled = true
        context = store.begin(eventID: "event-b", targetHost: "private-host", targetPort: 49_731)
        store.record(.sendStarted(listeningPort: 49_731), context: context)
        XCTAssertTrue(store.exportText().contains("stage=send-started"))

        store.clear()
        XCTAssertFalse(store.exportText().contains("stage=send-started"))
    }
}
