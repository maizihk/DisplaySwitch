import XCTest

private final class MemoryConfigurationStorage: DisplayConfigurationStorage {
    var values: [String: Any] = [:]
    var failWrites = false
    var corruptReadBack = false
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func writeDocument(_ data: Data, forKey key: String) throws {
        if failWrites { throw DisplayConfigurationStoreError.writeFailed }
        values[key] = corruptReadBack ? Data("corrupt".utf8) : data
        if values[key] as? Data != data { throw DisplayConfigurationStoreError.writeFailed }
    }
}

final class DisplayConfigurationStoreTests: XCTestCase {
    private var storage: MemoryConfigurationStorage!

    override func setUp() {
        super.setUp()
        storage = MemoryConfigurationStorage()
    }

    func testFreshV4DefaultsAreSafeAndPersistent() {
        let first = DisplayConfigurationStore.load(storage: storage)
        let second = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(first.safetyState, .ready)
        XCTAssertEqual(first.document.schemaVersion, 4)
        XCTAssertEqual(first.document.controlChannel, .automatic)
        XCTAssertFalse(first.document.linkAllDisplays)
        XCTAssertFalse(first.document.usbAutomationEnabled)
        XCTAssertFalse(first.document.usbSwitchDisplaysOnArrival)
        XCTAssertEqual(first.document.localEndpointID, second.document.localEndpointID)
        XCTAssertTrue(first.document.displays.isEmpty)
        XCTAssertEqual(first.document.collaborationProfiles.count, 1)
        XCTAssertFalse(first.document.collaborationProfiles[0].coordinationEnabled)
    }

    func testU005NewDisplayHasSixDDCSwitchesOffAndNoGuessedInputs() throws {
        let suite = "DisplaySwitcher.V4.Merge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let merged = try DisplayConfigurationStore.merge(
            detected: [DetectedDisplay(index: 1, name: "Simulated Display", systemUUID: UUID().uuidString)],
            existing: [], defaults: defaults
        )
        XCTAssertNil(merged[0].localInput)
        XCTAssertNil(merged[0].targetInput)
        let display = DisplayConfigurationStore.load(defaults: defaults).document.displays[0]
        XCTAssertFalse(display.brightnessEnabled)
        XCTAssertFalse(display.contrastEnabled)
        XCTAssertFalse(display.volumeEnabled)
        XCTAssertFalse(display.brightnessShowInTray)
        XCTAssertFalse(display.contrastShowInTray)
        XCTAssertFalse(display.volumeShowInTray)
        XCTAssertTrue(DisplaySettingsSemantics.trayCommands(for: display).isEmpty)
    }

    func testU016V3IsBackedUpButNeverMigrated() {
        let legacy = Data(#"{"schemaVersion":3,"private":"must-remain-local"}"#.utf8)
        storage.values[DisplayConfigurationStore.legacyV3StorageKey] = legacy
        storage.values["USBAutomation.Enabled"] = true
        let result = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.document.schemaVersion, 4)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyV3StorageKey), legacy)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyBackupStorageKey), legacy)
        XCTAssertTrue(result.document.displays.isEmpty)
        XCTAssertFalse(result.document.usbAutomationEnabled)
        XCTAssertFalse(result.document.collaborationProfiles[0].coordinationEnabled)
    }

    func testEarlierFormatsArePreservedAndProduceSafeV4Default() {
        for key in [DisplayConfigurationStore.legacyDocumentStorageKey,
                    DisplayConfigurationStore.legacyArrayStorageKey] {
            storage = MemoryConfigurationStorage()
            let legacy = Data("legacy-format".utf8)
            storage.values[key] = legacy
            let result = DisplayConfigurationStore.load(storage: storage)
            XCTAssertEqual(result.document.schemaVersion, 4)
            XCTAssertEqual(storage.data(forKey: key), legacy)
            XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyBackupStorageKey), legacy)
            XCTAssertTrue(result.document.displays.isEmpty)
        }
    }

    func testU017AtomicFailureRestoresLastValidDocumentAndBlocksSideEffects() throws {
        var document = DisplayConfigurationStore.load(storage: storage).document
        let original = try XCTUnwrap(storage.data(forKey: DisplayConfigurationStore.storageKey))
        document.linkAllDisplays = true
        storage.failWrites = true
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.storageKey), original)
        XCTAssertTrue(storage.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        storage.failWrites = false
        let restarted = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(restarted.safetyState, .requiresUserReview(.previousFailureRequiresReview))
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy {
            !ConfigurationSafetyGate(state: restarted.safetyState).allows($0)
        })
    }

    func testStagingReadbackFailureNeverReplacesLastValidValue() throws {
        var document = DisplayConfigurationStore.load(storage: storage).document
        let original = storage.data(forKey: DisplayConfigurationStore.storageKey)
        document.controlChannel = .fallback
        storage.corruptReadBack = true
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.storageKey), original)
        XCTAssertNil(storage.data(forKey: "\(DisplayConfigurationStore.storageKey).staging"))
    }

    func testReviewedValidSaveClearsSafetyMarker() throws {
        _ = DisplayConfigurationStore.load(storage: storage)
        storage.values[DisplayConfigurationStore.requiresReviewKey] = true
        let blocked = DisplayConfigurationStore.load(storage: storage)
        XCTAssertNotEqual(blocked.safetyState, .ready)
        try DisplayConfigurationStore.saveDocument(blocked.document, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .ready)
    }

    func testUnknownCurrentSchemaAndCorruptDataAreSafelyRejected() {
        storage.values[DisplayConfigurationStore.storageKey] = Data(#"{"schemaVersion":99}"#.utf8)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState,
                       .requiresUserReview(.unsupportedSchemaVersion(99)))
        storage = MemoryConfigurationStorage()
        storage.values[DisplayConfigurationStore.storageKey] = Data("not-json".utf8)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState,
                       .requiresUserReview(.corruptedData))
    }

    func testProfileValidationUsesNFCBytesAndCompleteMappings() throws {
        var document = populatedDocument()
        document.collaborationProfiles[0].pairingCode = String(repeating: "é", count: 4)
            .decomposedStringWithCanonicalMapping
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let loaded = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertEqual(loaded.collaborationProfiles[0].pairingCode.utf8.count, 8)
        let known = Set(loaded.displays.map { $0.id.lowercased() })
        XCTAssertTrue(DisplayConfigurationStore.inspectProfile(
            loaded.collaborationProfiles[0], displays: loaded.displays,
            ddcAvailableDisplayIDs: known
        ).isComplete)
    }

    func testIncompleteEnabledProfileIsExcludedFromMenu() {
        var document = populatedDocument()
        document.collaborationProfiles[0].peerHost = ""
        XCTAssertTrue(DisplayConfigurationStore.menuEligibleProfiles(in: document).isEmpty)
    }

    func testProfileNamesRemainUniqueAfterTrimmingAndCanonicalization() {
        var document = populatedDocument()
        var duplicate = document.collaborationProfiles[0]
        duplicate.id = UUID().uuidString
        duplicate.name += " "
        document.collaborationProfiles.append(duplicate)
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
    }

    func testProfileUSBBindingsRemainIsolatedDuringLearning() {
        var first = profile(name: "A")
        let second = profile(name: "B")
        first.triggerDevices = [CollaborationTriggerDevice(kind: "usb", localReference: "1:2", displayName: "A device")]
        var session = USBProfileLearningSession()
        session.begin(profileID: first.id)
        _ = session.receiveCandidates(
            [CollaborationTriggerDevice(kind: "usb", localReference: "3:4", displayName: "new")],
            availableProfileIDs: [first.id, second.id]
        )
        let updated = session.applyCandidate(at: 0, to: [first, second])
        XCTAssertEqual(updated[0].triggerDevices[0].localReference, "3:4")
        XCTAssertTrue(updated[1].triggerDevices.isEmpty)
    }

    private func populatedDocument() -> DisplayConfigurationStoreV4Document {
        let display = DisplayConfigurationV4Display(
            id: UUID().uuidString, name: "Display 1", selector: UUID().uuidString,
            localInput: nil, readEnabled: false
        )
        var peer = profile(name: "Peer")
        peer.peerHost = "peer.example"
        peer.pairingCode = UUID().uuidString
        peer.peerEndpointID = UUID().uuidString
        peer.peerProtocolVersion = 2
        peer.coordinationEnabled = true
        peer.displayInputs = [DisplayInputMapping(displayID: display.id, peerInput: 18)]
        return DisplayConfigurationStoreV4Document(
            schemaVersion: 4, localEndpointID: UUID().uuidString,
            localDeviceName: "Local", listenPort: 49731,
            controlChannel: .automatic, linkAllDisplays: false,
            displays: [display], collaborationProfiles: [peer]
        )
    }

    private func profile(name: String) -> CollaborationProfile {
        CollaborationProfile(
            id: UUID().uuidString, name: name, peerHost: "", peerPort: 49731,
            pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil,
            coordinationEnabled: false, displayInputs: [], triggerDevices: []
        )
    }
}
