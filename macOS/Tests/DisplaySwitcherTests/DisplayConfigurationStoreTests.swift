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

    func testFreshV5DefaultsAreSafeAndPersistent() {
        let first = DisplayConfigurationStore.load(storage: storage)
        let second = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(first.safetyState, .ready)
        XCTAssertEqual(first.document.schemaVersion, 5)
        XCTAssertFalse(first.document.linkAllDisplays)
        XCTAssertEqual(first.document.usbSwitch, .disabled)
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

    func testDS029DetectionReconciliationPreservesOfflineSavedDisplays() {
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let firstSelector = UUID().uuidString
        let secondSelector = UUID().uuidString
        let existing = [
            DisplayConfiguration(
                id: firstID, index: 1, name: "First", selector: firstSelector,
                localInput: 17, targetInput: nil, readEnabled: true
            ),
            DisplayConfiguration(
                id: secondID, index: 2, name: "Second", selector: secondSelector,
                localInput: 18, targetInput: nil, readEnabled: false
            )
        ]

        let result = DisplayConfigurationStore.reconcileDetectedDisplays(
            detected: [DetectedDisplay(index: 1, name: "First", systemUUID: firstSelector)],
            existing: existing
        )

        XCTAssertEqual(result.onlineConfigurations.map(\.id), [firstID])
        XCTAssertEqual(result.persistedConfigurations.map(\.id), [firstID, secondID])
        XCTAssertEqual(result.persistedConfigurations[1].selector, secondSelector)
        XCTAssertEqual(result.persistedConfigurations[1].localInput, 18)
    }

    func testDS029NewDetectionDoesNotGuessOfflineDisplayIdentity() {
        let existing = DisplayConfiguration(
            id: UUID().uuidString, index: 1, name: "Same Name", selector: UUID().uuidString,
            localInput: 17, targetInput: nil, readEnabled: true
        )
        let newSelector = UUID().uuidString
        let result = DisplayConfigurationStore.reconcileDetectedDisplays(
            detected: [DetectedDisplay(index: 1, name: "Same Name", systemUUID: newSelector)],
            existing: [existing]
        )

        XCTAssertEqual(result.onlineConfigurations.count, 1)
        XCTAssertNotEqual(result.onlineConfigurations[0].id, existing.id)
        XCTAssertEqual(result.onlineConfigurations[0].selector, newSelector.uppercased())
        XCTAssertTrue(result.persistedConfigurations.contains { $0.id == existing.id })
    }

    func testDS029DeleteCascadesMappingsButKeepsValidPartialAutomationAndCollaboration() {
        var document = populatedDocument()
        let removed = document.displays[0]
        let remaining = DisplayConfigurationV4Display(
            id: UUID().uuidString, name: "Display 2", selector: UUID().uuidString,
            localInput: 19, readEnabled: false
        )
        document.displays.append(remaining)
        document.usbSwitch = USBSwitchConfiguration(
            enabled: true,
            triggerDevice: CollaborationTriggerDevice(
                kind: "usb", localReference: "local-usb-reference", displayName: "USB Device"
            ),
            displayInputs: [
                USBDisplayInputMapping(displayID: removed.id, targetInput: 17),
                USBDisplayInputMapping(displayID: remaining.id, targetInput: 18)
            ]
        )
        document.collaborationProfiles[0].displayInputs = [
            DisplayInputMapping(displayID: removed.id, peerInput: 17),
            DisplayInputMapping(displayID: remaining.id, peerInput: 18)
        ]

        let mutation = DisplayDeletionPlanner.removing(stableID: removed.id, from: document)

        XCTAssertEqual(mutation?.document.displays.map(\.id), [remaining.id])
        XCTAssertEqual(mutation?.document.usbSwitch.displayInputs.map(\.displayID), [remaining.id])
        XCTAssertTrue(mutation?.document.usbSwitch.enabled == true)
        XCTAssertEqual(
            mutation?.document.collaborationProfiles[0].displayInputs.map(\.displayID),
            [remaining.id]
        )
        XCTAssertTrue(mutation?.document.collaborationProfiles[0].coordinationEnabled == true)
    }

    func testDS029DeleteLastMappingSafelyDisablesAutomationAndCollaboration() {
        var document = populatedDocument()
        let removed = document.displays[0]
        document.usbSwitch = USBSwitchConfiguration(
            enabled: true,
            triggerDevice: CollaborationTriggerDevice(
                kind: "usb", localReference: "local-usb-reference", displayName: "USB Device"
            ),
            collaborationWakeEnabled: true,
            collaborationProfileID: document.collaborationProfiles[0].id,
            displayInputs: [USBDisplayInputMapping(displayID: removed.id, targetInput: 17)]
        )

        let mutation = DisplayDeletionPlanner.removing(stableID: removed.id, from: document)

        XCTAssertTrue(mutation?.document.displays.isEmpty == true)
        XCTAssertTrue(mutation?.document.usbSwitch.displayInputs.isEmpty == true)
        XCTAssertFalse(mutation?.document.usbSwitch.enabled == true)
        XCTAssertFalse(mutation?.document.usbSwitch.collaborationWakeEnabled == true)
        XCTAssertTrue(mutation?.document.collaborationProfiles[0].displayInputs.isEmpty == true)
        XCTAssertFalse(mutation?.document.collaborationProfiles[0].coordinationEnabled == true)
    }

    func testDS029CancellationDoesNotCreateDeletionMutation() {
        XCTAssertFalse(DisplayDeletionConfirmationPolicy.shouldProceed(userConfirmed: false))
        XCTAssertTrue(DisplayDeletionConfirmationPolicy.shouldProceed(userConfirmed: true))
    }

    func testDS029FailedAtomicSavePreservesOriginalDisplayAndMappings() throws {
        let original = populatedDocument()
        try DisplayConfigurationStore.saveDocument(original, storage: storage)
        let mutation = try XCTUnwrap(
            DisplayDeletionPlanner.removing(stableID: original.displays[0].id, from: original)
        )
        storage.failWrites = true

        XCTAssertThrowsError(
            try DisplayConfigurationStore.saveDocument(mutation.document, storage: storage)
        )
        let reloaded = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(reloaded.document.displays, original.displays)
        XCTAssertEqual(
            reloaded.document.collaborationProfiles[0].displayInputs,
            original.collaborationProfiles[0].displayInputs
        )
    }

    func testU016V3IsBackedUpButNeverMigrated() {
        let legacy = Data(#"{"schemaVersion":3,"private":"must-remain-local"}"#.utf8)
        storage.values[DisplayConfigurationStore.legacyV3StorageKey] = legacy
        storage.values["USBAutomation.Enabled"] = true
        let result = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.document.schemaVersion, 5)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyV3StorageKey), legacy)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyBackupStorageKey), legacy)
        XCTAssertTrue(result.document.displays.isEmpty)
        XCTAssertEqual(result.document.usbSwitch, .disabled)
        XCTAssertFalse(result.document.collaborationProfiles[0].coordinationEnabled)
    }

    func testV4MigratesAtomicallyPreservingNonUSBDataAndDisablingIndependentUSB() throws {
        let original = populatedDocument()
        var dictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        dictionary["schemaVersion"] = 4
        dictionary.removeValue(forKey: "usbSwitch")
        dictionary["usbAutomationEnabled"] = true
        dictionary["usbSwitchDisplaysOnArrival"] = true
        var profiles = try XCTUnwrap(dictionary["collaborationProfiles"] as? [[String: Any]])
        profiles[0]["triggerDevices"] = [[
            "kind": "usb", "localReference": "100:200", "displayName": "Legacy trigger"
        ]]
        dictionary["collaborationProfiles"] = profiles
        let v4Data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        storage.values[DisplayConfigurationStore.legacyV4StorageKey] = v4Data

        let result = DisplayConfigurationStore.load(storage: storage)

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.document.schemaVersion, 5)
        XCTAssertEqual(result.document.localEndpointID, original.localEndpointID)
        XCTAssertEqual(result.document.displays, original.displays)
        XCTAssertEqual(result.document.collaborationProfiles[0].triggerDevices.count, 1)
        XCTAssertEqual(result.document.usbSwitch, .disabled)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyV4StorageKey), v4Data)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyBackupStorageKey), v4Data)
        XCTAssertNotNil(storage.data(forKey: DisplayConfigurationStore.storageKey))
    }

    func testV4MigrationWriteFailurePreservesOriginalAndBlocksAllSideEffects() throws {
        let original = populatedDocument()
        var dictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        dictionary["schemaVersion"] = 4
        dictionary.removeValue(forKey: "usbSwitch")
        dictionary["usbAutomationEnabled"] = false
        dictionary["usbSwitchDisplaysOnArrival"] = false
        let v4Data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        storage.values[DisplayConfigurationStore.legacyV4StorageKey] = v4Data
        storage.failWrites = true

        let result = DisplayConfigurationStore.load(storage: storage)

        XCTAssertNotEqual(result.safetyState, .ready)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyV4StorageKey), v4Data)
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyBackupStorageKey), v4Data)
        XCTAssertNil(storage.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy {
            !ConfigurationSafetyGate(state: result.safetyState).allows($0)
        })
    }

    func testEarlierFormatsArePreservedAndProduceSafeV5Default() {
        for key in [DisplayConfigurationStore.legacyDocumentStorageKey,
                    DisplayConfigurationStore.legacyArrayStorageKey] {
            storage = MemoryConfigurationStorage()
            let legacy = Data("legacy-format".utf8)
            storage.values[key] = legacy
            let result = DisplayConfigurationStore.load(storage: storage)
            XCTAssertEqual(result.document.schemaVersion, 5)
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
        document.linkAllDisplays.toggle()
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

    func testLegacyBackendSelectionFieldIsIgnoredAndNeverSavedAgain() throws {
        let original = populatedDocument()
        var dictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        dictionary["controlChannel"] = "fallback"
        storage.values[DisplayConfigurationStore.storageKey] = try JSONSerialization.data(
            withJSONObject: dictionary, options: [.sortedKeys]
        )

        let loaded = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(loaded.safetyState, .ready)
        try DisplayConfigurationStore.saveDocument(loaded.document, storage: storage)
        let saved = try XCTUnwrap(storage.data(forKey: DisplayConfigurationStore.storageKey))
        let savedDictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        )
        XCTAssertNil(savedDictionary["controlChannel"])
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

    func testProfileValidationIssuesUseReadableLocalizedDescriptions() {
        let expected: [LocalProfileIssue: String] = [
            .missingName: "请填写配置名称。",
            .missingHost: "请填写对端地址。",
            .invalidPort: "通信端口必须在 1–65535 之间。",
            .invalidPairingCode: "配对码必须为 8–128 个 UTF-8 字节。",
            .missingDisplayMapping: "请至少为一台显示器填写 1–65535 的对端输入源。",
            .orphanedDisplayMapping: "存在不再对应当前显示器的旧输入源映射，请重新保存配置。"
        ]

        XCTAssertEqual(expected.count, 6)
        for (issue, description) in expected {
            XCTAssertEqual(issue.userFacingDescription, description)
            XCTAssertNotEqual(issue.userFacingDescription, issue.rawValue)
        }
    }

    func testIncompleteEnabledProfileIsExcludedFromMenu() {
        var document = populatedDocument()
        document.collaborationProfiles[0].peerHost = ""
        XCTAssertTrue(DisplayConfigurationStore.menuEligibleProfiles(in: document).isEmpty)
    }

    func testPartialEnabledProfileRemainsEnabledAndKeepsBlankDisplaysSkipped() {
        var document = populatedDocument()
        let secondDisplay = DisplayConfigurationV4Display(
            id: UUID().uuidString, name: "Display 2", selector: UUID().uuidString,
            localInput: nil, readEnabled: false
        )
        document.displays.append(secondDisplay)
        let original = document.collaborationProfiles[0]

        let decision = DisplayConfigurationStore.profileForSafeSave(original, displays: document.displays)

        XCTAssertFalse(decision.disabledBecauseIncomplete)
        XCTAssertTrue(decision.profile.coordinationEnabled)
        XCTAssertEqual(decision.profile.displayInputs, original.displayInputs)
        XCTAssertEqual(decision.profile.displayInputs.count, 1)
    }

    func testProfileAndUSBRequireAtLeastOneSafeMappedDisplay() {
        var document = populatedDocument()
        document.collaborationProfiles[0].displayInputs = []
        let profileDecision = DisplayConfigurationStore.profileForSafeSave(
            document.collaborationProfiles[0], displays: document.displays
        )
        XCTAssertTrue(profileDecision.disabledBecauseIncomplete)
        XCTAssertFalse(profileDecision.profile.coordinationEnabled)

        document.usbSwitch = USBSwitchConfiguration(
            enabled: false,
            triggerDevice: CollaborationTriggerDevice(
                kind: "usb", localReference: "local-usb-reference", displayName: "USB Device"
            ),
            displayInputs: []
        )
        XCTAssertFalse(DisplayConfigurationStore.isCompleteUSBConfiguration(
            document.usbSwitch, displays: document.displays
        ))
        document.usbSwitch.displayInputs = [
            USBDisplayInputMapping(displayID: document.displays[0].id, targetInput: 17)
        ]
        XCTAssertTrue(DisplayConfigurationStore.isCompleteUSBConfiguration(
            document.usbSwitch, displays: document.displays
        ))
    }

    func testLegacyZeroMappingsLoadAsBlankAndDisableUnsafeUSBAutomation() throws {
        var document = populatedDocument()
        document.displays[0].localInput = 0
        document.collaborationProfiles[0].displayInputs = [
            DisplayInputMapping(displayID: document.displays[0].id, peerInput: 0)
        ]
        document.usbSwitch = USBSwitchConfiguration(
            enabled: true,
            triggerDevice: CollaborationTriggerDevice(
                kind: "usb", localReference: "local-usb-reference", displayName: "USB Device"
            ),
            displayInputs: [
                USBDisplayInputMapping(displayID: document.displays[0].id, targetInput: 0)
            ]
        )
        storage.values[DisplayConfigurationStore.storageKey] = try JSONEncoder().encode(document)

        let result = DisplayConfigurationStore.load(storage: storage)

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertNil(result.document.displays[0].localInput)
        XCTAssertTrue(result.document.collaborationProfiles[0].displayInputs.isEmpty)
        XCTAssertTrue(result.document.usbSwitch.displayInputs.isEmpty)
        XCTAssertFalse(result.document.usbSwitch.enabled)
    }

    func testCompleteEnabledProfileRemainsEnabledWhenSaved() {
        let document = populatedDocument()
        let original = document.collaborationProfiles[0]

        let decision = DisplayConfigurationStore.profileForSafeSave(original, displays: document.displays)

        XCTAssertFalse(decision.disabledBecauseIncomplete)
        XCTAssertTrue(decision.profile.coordinationEnabled)
        XCTAssertEqual(decision.profile, original)
    }

    func testProfileNamesRemainUniqueAfterTrimmingAndCanonicalization() {
        var document = populatedDocument()
        var duplicate = document.collaborationProfiles[0]
        duplicate.id = UUID().uuidString
        duplicate.name += " "
        document.collaborationProfiles.append(duplicate)
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
    }

    func testDS029DeleteEligibilityRequiresTwoTrustedNonEmptyDetections() {
        let stableID = UUID().uuidString
        let selector = UUID().uuidString
        let saved = [deletionDisplay(id: stableID, selector: selector)]
        let online = DetectedDisplay(index: 1, name: "Online", systemUUID: UUID().uuidString)
        let tracker = DisplayDeletionAvailabilityTracker()

        tracker.beginDetection()
        XCTAssertEqual(tracker.availability.detectionState, .detecting)
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))

        tracker.recordSuccessfulDetection(
            detected: [online], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))
        tracker.recordSuccessfulDetection(
            detected: [online], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        XCTAssertTrue(tracker.availability.allowsDeletion(stableID: stableID))
    }

    func testDS029DetectingFailureEmptyAndDuplicateResultsNeverAllowDelete() {
        let stableID = UUID().uuidString
        let selector = UUID().uuidString
        let saved = [deletionDisplay(id: stableID, selector: selector)]
        let other = DetectedDisplay(index: 1, name: "Online", systemUUID: UUID().uuidString)
        let tracker = DisplayDeletionAvailabilityTracker()

        tracker.recordSuccessfulDetection(
            detected: [other], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        tracker.recordSuccessfulDetection(
            detected: [other], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        XCTAssertTrue(tracker.availability.allowsDeletion(stableID: stableID))

        tracker.beginDetection()
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))
        tracker.recordFailureOrUntrustedResult()
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))
        tracker.recordSuccessfulDetection(
            detected: [], physicalEvidence: .untrusted, savedDisplays: saved
        )
        XCTAssertEqual(tracker.availability.detectionState, .untrusted)
        tracker.recordSuccessfulDetection(
            detected: [other, other],
            physicalEvidence: trustedPhysicalEvidence(count: 2),
            savedDisplays: saved
        )
        XCTAssertEqual(tracker.availability.detectionState, .untrusted)
    }

    func testDS029OnlineDisplayNeverShowsDeleteAndRemovalClearsEligibility() {
        let stableID = UUID().uuidString
        let selector = UUID().uuidString
        let saved = [deletionDisplay(id: stableID, selector: selector)]
        let same = DetectedDisplay(index: 1, name: "Online", systemUUID: selector)
        let tracker = DisplayDeletionAvailabilityTracker()

        tracker.recordSuccessfulDetection(
            detected: [same], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        tracker.recordSuccessfulDetection(
            detected: [same], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))

        let other = DetectedDisplay(index: 1, name: "Other", systemUUID: UUID().uuidString)
        tracker.recordSuccessfulDetection(
            detected: [other], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        tracker.recordSuccessfulDetection(
            detected: [other], physicalEvidence: trustedPhysicalEvidence(), savedDisplays: saved
        )
        XCTAssertTrue(tracker.availability.allowsDeletion(stableID: stableID))
        tracker.remove(stableID: stableID)
        XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))
    }

    func testDS029VirtualOrIncompleteEnumerationsCannotAccumulateOfflineMisses() {
        let stableID = UUID().uuidString
        let selector = UUID().uuidString
        let saved = [deletionDisplay(id: stableID, selector: selector)]
        let other = DetectedDisplay(index: 1, name: "Other", systemUUID: UUID().uuidString)
        let untrustedEvidence = [
            // A CG identity without an IOAV transport is virtual or unresolved.
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 1,
                extractedIdentityCount: 1,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 0,
                matchedPhysicalTransportCount: 0
            ),
            // An extra physical service means CG omitted part of the local topology.
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 1,
                extractedIdentityCount: 1,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 2,
                matchedPhysicalTransportCount: 1
            ),
            // CoreDisplay failed to produce an identity for every online external display.
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 2,
                extractedIdentityCount: 1,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 1,
                matchedPhysicalTransportCount: 1
            )
        ]

        for evidence in untrustedEvidence {
            let tracker = DisplayDeletionAvailabilityTracker()
            tracker.recordSuccessfulDetection(
                detected: [other], physicalEvidence: evidence, savedDisplays: saved
            )
            tracker.recordSuccessfulDetection(
                detected: [other], physicalEvidence: evidence, savedDisplays: saved
            )
            XCTAssertEqual(tracker.availability.detectionState, .untrusted)
            XCTAssertFalse(tracker.availability.allowsDeletion(stableID: stableID))
        }
    }

    private func deletionDisplay(id: String, selector: String) -> DisplayConfigurationV4Display {
        DisplayConfigurationV4Display(
            id: id,
            name: "Saved",
            selector: selector,
            localInput: nil,
            readEnabled: false
        )
    }

    private func trustedPhysicalEvidence(count: Int = 1) -> DDCPhysicalEnumerationEvidence {
        DDCPhysicalEnumerationEvidence(
            cgEnumerationSucceeded: true,
            externalCGDisplayCount: count,
            extractedIdentityCount: count,
            registryEnumerationSucceeded: true,
            externalRegistryServiceCount: count,
            matchedPhysicalTransportCount: count
        )
    }

    private func populatedDocument() -> DisplayConfigurationStoreV5Document {
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
        return DisplayConfigurationStoreV5Document(
            schemaVersion: 5, localEndpointID: UUID().uuidString,
            localDeviceName: "Local", listenPort: 49731, linkAllDisplays: false,
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
