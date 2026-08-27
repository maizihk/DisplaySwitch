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
        values[key] = corruptReadBack ? Data("bad-readback".utf8) : data
        if values[key] as? Data != data { throw DisplayConfigurationStoreError.writeFailed }
    }
}

final class DisplayConfigurationStoreTests: XCTestCase {
    private var storage: MemoryConfigurationStorage!

    override func setUp() {
        super.setUp()
        storage = MemoryConfigurationStorage()
    }

    func testC001FreshInstallPersistsRandomEndpointAndOneDisabledProfile() throws {
        let first = DisplayConfigurationStore.load(storage: storage)
        let persisted = try XCTUnwrap(storage.data(forKey: DisplayConfigurationStore.storageKey))
        let second = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(first.safetyState, .ready)
        XCTAssertEqual(first.document.schemaVersion, 3)
        XCTAssertNotNil(UUID(uuidString: first.document.localEndpointID))
        XCTAssertEqual(first.document.localEndpointID, second.document.localEndpointID)
        XCTAssertTrue(first.document.displays.isEmpty)
        XCTAssertEqual(first.collaborationProfiles.count, 1)
        XCTAssertEqual(first.collaborationProfiles[0].name, "配置 1")
        XCTAssertFalse(first.collaborationProfiles[0].coordinationEnabled)
        XCTAssertFalse(persisted.isEmpty)
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy(ConfigurationSafetyGate(state: first.safetyState).allows))
    }

    func testC002AddsProfilesWithStableDistinctIdentifiers() throws {
        var document = DisplayConfigurationStore.load(storage: storage).document
        let originalID = document.collaborationProfiles[0].id
        document.collaborationProfiles.append(profile(name: "游戏主机"))
        document.collaborationProfiles.append(profile(name: "工作电脑"))
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let loaded = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertEqual(loaded.collaborationProfiles.first?.id, originalID)
        XCTAssertEqual(Set(loaded.collaborationProfiles.map(\.id)).count, 3)
    }

    func testC003ProfileReorderKeepsMappingsBoundToStableDisplayIDs() throws {
        var document = populatedDocument()
        let mappedID = document.displays[1].id
        var second = profile(name: "第二台")
        second.displayInputs = [DisplayInputMapping(displayID: mappedID, peerInput: 27)]
        document.collaborationProfiles.append(second)
        document.collaborationProfiles.swapAt(0, 1)
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let loaded = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertEqual(loaded.collaborationProfiles[0].displayInputs.first?.displayID, mappedID)
        XCTAssertEqual(loaded.collaborationProfiles[0].displayInputs.first?.peerInput, 27)
    }

    func testC004InvalidAndDuplicateProfileNamesAreRejectedWithoutOverwriting() throws {
        var document = populatedDocument()
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let original = storage.data(forKey: DisplayConfigurationStore.storageKey)
        for invalidName in ["", "bad\nname"] {
            document.collaborationProfiles[0].name = invalidName
            XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
            XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.storageKey), original)
        }
        document = try JSONDecoder().decode(DisplayConfigurationStoreV3Document.self, from: XCTUnwrap(original))
        var duplicate = profile(name: document.collaborationProfiles[0].name.uppercased())
        duplicate.id = UUID().uuidString
        document.collaborationProfiles.append(duplicate)
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.storageKey), original)
    }

    func testC005OrphanedMappingIsRetainedAndReported() throws {
        var document = populatedDocument()
        let removedID = document.displays.removeLast().id
        document.collaborationProfiles[0].displayInputs.append(DisplayInputMapping(displayID: removedID, peerInput: 18))
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let loaded = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertEqual(loaded.collaborationProfiles[0].displayInputs.last?.displayID, removedID)
        let inspection = DisplayConfigurationStore.inspectProfile(loaded.collaborationProfiles[0], displays: loaded.displays,
                                                                   ddcAvailableDisplayIDs: Set(loaded.displays.map { $0.id.lowercased() }))
        XCTAssertTrue(inspection.issues.contains(.orphanedDisplayMapping))
    }

    func testC006MultipleProfilesMayBeEnabledWithoutImplicitSelection() throws {
        var document = populatedDocument()
        document.collaborationProfiles[0].coordinationEnabled = true
        var second = profile(name: "同时启用")
        second.coordinationEnabled = true
        document.collaborationProfiles.append(second)
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).collaborationProfiles.filter(\.coordinationEnabled).count, 2)
    }

    func testEnabledIncompleteProfileIsNotAMenuCandidate() {
        var document = populatedDocument()
        document.collaborationProfiles[0].coordinationEnabled = true
        XCTAssertTrue(DisplayConfigurationStore.menuEligibleProfiles(in: document).isEmpty)

        document.collaborationProfiles[0].displayInputs = document.displays.map {
            DisplayInputMapping(displayID: $0.id, peerInput: 18)
        }
        XCTAssertEqual(DisplayConfigurationStore.menuEligibleProfiles(in: document).map(\.id),
                       [document.collaborationProfiles[0].id])

        document.collaborationProfiles[0].displayInputs[0].peerInput = -1
        XCTAssertTrue(DisplayConfigurationStore.menuEligibleProfiles(in: document).isEmpty)
        document.collaborationProfiles[0].displayInputs[0].peerInput = 18
        document.collaborationProfiles[0].peerHost = ""
        XCTAssertTrue(DisplayConfigurationStore.menuEligibleProfiles(in: document).isEmpty)
    }

    func testUSBTriggerEditingIsIsolatedByProfile() {
        let first = profile(name: "A")
        let second = profile(name: "B")
        let firstTrigger = CollaborationTriggerDevice(kind: "usb", localReference: "1:2", displayName: "键盘 A")
        let secondTrigger = CollaborationTriggerDevice(kind: "usb", localReference: "3:4", displayName: "键盘 B")
        var profiles = DisplayConfigurationStore.replacingUSBTrigger(firstTrigger, profileID: first.id, in: [first, second])
        profiles = DisplayConfigurationStore.replacingUSBTrigger(secondTrigger, profileID: second.id, in: profiles)
        XCTAssertEqual(profiles[0].triggerDevices, [firstTrigger])
        XCTAssertEqual(profiles[1].triggerDevices, [secondTrigger])

        let replacement = CollaborationTriggerDevice(kind: "usb", localReference: "5:6", displayName: "键盘 A2")
        profiles = DisplayConfigurationStore.replacingUSBTrigger(replacement, profileID: first.id, in: profiles)
        XCTAssertEqual(profiles[0].triggerDevices, [replacement])
        XCTAssertEqual(profiles[1].triggerDevices, [secondTrigger])
    }

    func testUSBLearningStartedForAStillWritesOnlyATriggerAfterSelectionChangesToB() {
        let first = profile(name: "A")
        let second = profile(name: "B")
        var session = USBProfileLearningSession()
        let safetyGate = USBLearningSafetyGate()
        session.begin(profileID: first.id)
        safetyGate.begin()
        let currentlySelectedProfileID = second.id
        let trigger = CollaborationTriggerDevice(kind: "usb", localReference: "7:8", displayName: "A 的设备")

        XCTAssertEqual(USBProfileLearningSession.timeoutSeconds, 30)
        XCTAssertTrue(session.blocksAutomaticSideEffects)
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { !safetyGate.allows($0) })

        let profiles = session.apply(trigger, to: [first, second])
        safetyGate.end()

        XCTAssertEqual(currentlySelectedProfileID, second.id)
        XCTAssertEqual(profiles[0].triggerDevices, [trigger])
        XCTAssertTrue(profiles[1].triggerDevices.isEmpty)
        XCTAssertNil(session.pendingProfileID)
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { safetyGate.allows($0) })
    }

    func testLateUSBLearningResultIsDiscardedWhenTargetProfileWasDeleted() {
        let first = profile(name: "A")
        let second = profile(name: "B")
        var session = USBProfileLearningSession()
        session.begin(profileID: first.id)
        let trigger = CollaborationTriggerDevice(kind: "usb", localReference: "9:10", displayName: "迟到设备")

        let profiles = session.apply(trigger, to: [second])

        XCTAssertEqual(profiles, [second])
        XCTAssertTrue(profiles[0].triggerDevices.isEmpty)
        XCTAssertNil(session.pendingProfileID)

        var retained = first
        let original = CollaborationTriggerDevice(kind: "usb", localReference: "1:2", displayName: "原绑定")
        retained.triggerDevices = [original]
        session.begin(profileID: retained.id)
        session.cancel()
        let afterCancelledLateResult = session.apply(trigger, to: [retained, second])
        XCTAssertEqual(afterCancelledLateResult[0].triggerDevices, [original])
        XCTAssertTrue(afterCancelledLateResult[1].triggerDevices.isEmpty)
    }

    func testMultipleEnabledProfilesBlockLegacyV1AutomaticSideEffects() {
        var document = populatedDocument()
        document.collaborationProfiles[0].coordinationEnabled = true
        var second = profile(name: "B")
        second.coordinationEnabled = true
        document.collaborationProfiles.append(second)

        let selection = DisplayConfigurationStore.legacyV1RuntimeSelection(in: document)
        XCTAssertEqual(selection, .requiresProtocolV2)
        let sideEffects = Dictionary(uniqueKeysWithValues: ConfigurationSideEffect.allCases.map {
            ($0, selection.allowsAutomaticCoordination ? 1 : 0)
        })
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { sideEffects[$0] == 0 })
    }

    func testSingleMigratedEnabledProfileKeepsLegacyV1Compatibility() throws {
        let oldData = try JSONEncoder().encode([legacyDisplay(index: 1, local: 15, peer: 18)])
        storage.values[DisplayConfigurationStore.legacyArrayStorageKey] = oldData
        storage.values["Peer.Enabled"] = true
        storage.values["Peer.Host"] = "peer.example"
        storage.values["Peer.Port"] = 49731
        storage.values["Peer.PairingCode"] = ephemeralPairingCode()
        storage.values["USBAutomation.Device"] = try JSONSerialization.data(withJSONObject: [
            "vendorID": 1, "productID": 2, "name": "迁移设备"
        ])
        let document = DisplayConfigurationStore.load(storage: storage).document

        guard case .compatible(let selected) = DisplayConfigurationStore.legacyV1RuntimeSelection(in: document) else {
            return XCTFail("单个迁移配置应继续由 v1 运行时使用")
        }
        XCTAssertEqual(selected.id, document.collaborationProfiles[0].id)
        XCTAssertEqual(selected.peerHost, "peer.example")
    }

    func testOnlyEnabledIncompleteNonCurrentProfileCannotStartLegacyV1() {
        var document = populatedDocument()
        document.collaborationProfiles[0].coordinationEnabled = false
        var second = profile(name: "唯一开启但不完整")
        second.coordinationEnabled = true
        second.peerHost = "peer.example"
        second.pairingCode = ephemeralPairingCode()
        second.displayInputs = document.displays.map { DisplayInputMapping(displayID: $0.id, peerInput: 18) }
        document.collaborationProfiles.append(second)
        let currentSettingsProfileID = document.collaborationProfiles[0].id

        let selection = DisplayConfigurationStore.legacyV1RuntimeSelection(in: document)

        XCTAssertEqual(currentSettingsProfileID, document.collaborationProfiles[0].id)
        XCTAssertEqual(selection, .requiresCompleteConfiguration)
        XCTAssertTrue(selection.blocksAutomaticSideEffects)
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { _ in !selection.allowsAutomaticCoordination })
    }

    func testLegacyV1CompatibilityRequiresEveryAutomaticCoordinationField() {
        let display = display(name: "Only")
        var complete = profile(name: "Windows")
        complete.coordinationEnabled = true
        complete.peerHost = "peer.example"
        complete.peerPort = 49731
        complete.pairingCode = ephemeralPairingCode()
        complete.displayInputs = [DisplayInputMapping(displayID: display.id, peerInput: 18)]
        complete.triggerDevices = [CollaborationTriggerDevice(kind: "usb", localReference: "1:2", displayName: "USB")]
        let makeDocument: (CollaborationProfile) -> DisplayConfigurationStoreV3Document = { profile in
            DisplayConfigurationStoreV3Document(schemaVersion: 3, localEndpointID: UUID().uuidString,
                localDeviceName: "Mac", listenPort: 49731, displays: [display], collaborationProfiles: [profile])
        }
        XCTAssertTrue(DisplayConfigurationStore.legacyV1RuntimeSelection(in: makeDocument(complete)).allowsAutomaticCoordination)

        var invalidProfiles: [CollaborationProfile] = []
        var missingHost = complete
        missingHost.peerHost = ""
        invalidProfiles.append(missingHost)
        var invalidPort = complete
        invalidPort.peerPort = 0
        invalidProfiles.append(invalidPort)
        var shortPairing = complete
        shortPairing.pairingCode = "short"
        invalidProfiles.append(shortPairing)
        var missingMapping = complete
        missingMapping.displayInputs = []
        invalidProfiles.append(missingMapping)
        var missingUSB = complete
        missingUSB.triggerDevices = []
        invalidProfiles.append(missingUSB)
        var emptyUSBReference = complete
        emptyUSBReference.triggerDevices[0].localReference = " "
        invalidProfiles.append(emptyUSBReference)

        for profile in invalidProfiles {
            let selection = DisplayConfigurationStore.legacyV1RuntimeSelection(in: makeDocument(profile))
            XCTAssertEqual(selection, .requiresCompleteConfiguration)
            XCTAssertTrue(selection.blocksAutomaticSideEffects)
        }
    }

    func testC007InspectionAndPeerIdentityChangesArePureAndRequireConfirmation() {
        let document = populatedDocument()
        let profile = document.collaborationProfiles[0]
        let sideEffects = Dictionary(uniqueKeysWithValues: ConfigurationSideEffect.allCases.map { ($0, 0) })
        let inspection = DisplayConfigurationStore.inspectProfile(profile, displays: document.displays,
            ddcAvailableDisplayIDs: Set(document.displays.map { $0.id.lowercased() }))
        XCTAssertFalse(inspection.isComplete)
        XCTAssertEqual(sideEffects[.usb], 0)
        XCTAssertEqual(sideEffects[.ddc], 0)
        XCTAssertEqual(sideEffects[.wake], 0)
        XCTAssertEqual(sideEffects[.network], 0)
        let candidate = UUID().uuidString
        XCTAssertEqual(DisplayConfigurationStore.checkPeerIdentity(profile, endpointID: candidate, protocolVersion: 2),
                       .firstConfirmationRequired(endpointID: UUID(uuidString: candidate)!.uuidString, protocolVersion: 2))
        var confirmed = profile
        confirmed.peerEndpointID = UUID().uuidString
        confirmed.peerProtocolVersion = 2
        XCTAssertEqual(DisplayConfigurationStore.checkPeerIdentity(confirmed, endpointID: candidate, protocolVersion: 2),
                       .changeConfirmationRequired(previousEndpointID: UUID(uuidString: confirmed.peerEndpointID!)!.uuidString,
                                                   endpointID: UUID(uuidString: candidate)!.uuidString, protocolVersion: 2))
    }

    func testC008V2MigrationSeparatesLocalAndPeerInputsAndPreservesOriginal() throws {
        let legacy = [legacyDisplay(index: 1, local: 15, peer: 18), legacyDisplay(index: 2, local: 17, peer: 27)]
        let old = DisplayConfigurationDocument(schemaVersion: 2, displays: legacy)
        let oldData = try JSONEncoder().encode(old)
        storage.values[DisplayConfigurationStore.legacyDocumentStorageKey] = oldData
        storage.values["Peer.Host"] = "172.16.10.20"
        storage.values["Peer.PairingCode"] = ephemeralPairingCode()
        let result = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.document.displays.map(\.localInput), [15, 17])
        XCTAssertEqual(result.collaborationProfiles[0].displayInputs.map(\.peerInput), [18, 27])
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyDocumentStorageKey), oldData)
        XCTAssertNotNil(storage.data(forKey: DisplayConfigurationStore.storageKey))
    }

    func testC010MigrationWriteAndReadbackFailurePreserveSourceAndPersistBlock() throws {
        let oldData = try JSONEncoder().encode([legacyDisplay(index: 1, local: 15, peer: 18)])
        storage.values[DisplayConfigurationStore.legacyArrayStorageKey] = oldData
        storage.failWrites = true
        let failed = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(failed.safetyState, .requiresUserReview(.writeFailed))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey), oldData)
        XCTAssertTrue(storage.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { !ConfigurationSafetyGate(state: failed.safetyState).allows($0) })
        storage.failWrites = false
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState,
                       .requiresUserReview(.previousFailureRequiresReview))
    }

    func testC010EncodingAndReadbackFailuresRemainSafe() throws {
        let oldData = try JSONEncoder().encode([legacyDisplay(index: 1, local: 15, peer: 18)])
        storage.values[DisplayConfigurationStore.legacyArrayStorageKey] = oldData
        let encodedFailure = DisplayConfigurationStore.load(storage: storage, encodeDocument: { _ in
            throw DisplayConfigurationStoreError.encodingFailed
        })
        XCTAssertEqual(encodedFailure.safetyState, .requiresUserReview(.encodingFailed))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey), oldData)
        storage.removeObject(forKey: DisplayConfigurationStore.requiresReviewKey)
        storage.corruptReadBack = true
        let readbackFailure = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(readbackFailure.safetyState, .requiresUserReview(.writeFailed))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey), oldData)
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { !ConfigurationSafetyGate(state: readbackFailure.safetyState).allows($0) })
    }

    func testFreshInstallFailureStaysBlockedAcrossRestartUntilReviewedSave() throws {
        storage.failWrites = true
        let first = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(first.safetyState, .requiresUserReview(.writeFailed))
        XCTAssertTrue(storage.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        storage.failWrites = false
        let restarted = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(restarted.safetyState, .requiresUserReview(.previousFailureRequiresReview))
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy { !ConfigurationSafetyGate(state: restarted.safetyState).allows($0) })
        try DisplayConfigurationStore.saveDocument(restarted.document, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .ready)
    }

    func testC011UnknownV3FieldsAreIgnored() throws {
        let original = populatedDocument()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["futureField"] = ["value": true]
        storage.values[DisplayConfigurationStore.storageKey] = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).document, original)
    }

    func testC012UnknownVersionAndDuplicateUUIDAreRejected() throws {
        storage.values[DisplayConfigurationStore.storageKey] = Data(#"{"schemaVersion":99}"#.utf8)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .requiresUserReview(.unsupportedSchemaVersion(99)))
        storage = MemoryConfigurationStorage()
        var document = populatedDocument()
        document.displays.append(document.displays[0])
        storage.values[DisplayConfigurationStore.storageKey] = try JSONEncoder().encode(document)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .requiresUserReview(.invalidConfiguration))
    }

    func testC013RenameDoesNotChangeMapping() throws {
        var document = populatedDocument()
        let before = document.collaborationProfiles[0].displayInputs
        document.collaborationProfiles[0].name = "新名称"
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        let loaded = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertEqual(loaded.collaborationProfiles[0].name, "新名称")
        XCTAssertEqual(loaded.collaborationProfiles[0].displayInputs, before)
    }

    func testC014EachProfileReadsOnlyItsOwnMapping() {
        let displayID = UUID().uuidString
        var first = profile(name: "A")
        var second = profile(name: "B")
        first.displayInputs = [DisplayInputMapping(displayID: displayID, peerInput: 18)]
        second.displayInputs = [DisplayInputMapping(displayID: displayID, peerInput: 27)]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: first.displayInputs.map { ($0.displayID, $0.peerInput) })[displayID], 18)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: second.displayInputs.map { ($0.displayID, $0.peerInput) })[displayID], 27)
    }

    func testC015MissingMappingLeavesOtherDisplaysUsable() {
        var document = populatedDocument()
        document.collaborationProfiles[0].displayInputs = [DisplayInputMapping(displayID: document.displays[0].id, peerInput: 18)]
        let mappings = Dictionary(uniqueKeysWithValues: document.collaborationProfiles[0].displayInputs.map { ($0.displayID, $0.peerInput) })
        XCTAssertEqual(mappings[document.displays[0].id], 18)
        XCTAssertNil(mappings[document.displays[1].id])
        XCTAssertTrue(DisplayConfigurationStore.inspectProfile(document.collaborationProfiles[0], displays: document.displays,
            ddcAvailableDisplayIDs: Set(document.displays.map { $0.id.lowercased() })).issues.contains(.missingDisplayMapping))
    }

    func testNFCByteLengthPortInputAndDuplicateMappingValidation() throws {
        var document = populatedDocument()
        document.collaborationProfiles[0].pairingCode = String(repeating: "é", count: 4).decomposedStringWithCanonicalMapping
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).collaborationProfiles[0].pairingCode.utf8.count, 8)
        let original = storage.data(forKey: DisplayConfigurationStore.storageKey)
        document.collaborationProfiles[0].peerPort = 0
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
        XCTAssertEqual(storage.data(forKey: DisplayConfigurationStore.storageKey), original)
        document = populatedDocument()
        let duplicate = document.collaborationProfiles[0].displayInputs[0]
        document.collaborationProfiles[0].displayInputs.append(duplicate)
        XCTAssertThrowsError(try DisplayConfigurationStore.saveDocument(document, storage: storage))
    }

    func testZeroOneAndManyDisplaysAndMergeDoNotGuessInputs() throws {
        var document = DisplayConfigurationStore.load(storage: storage).document
        XCTAssertTrue(document.displays.isEmpty)
        document.displays = [display(name: "One")]
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        document.displays.append(display(name: "Two"))
        document.displays.append(display(name: "Three"))
        try DisplayConfigurationStore.saveDocument(document, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).document.displays.count, 3)
        let suite = "DisplaySwitcher.Merge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let merged = try DisplayConfigurationStore.merge(detected: [DetectedDisplay(index: 1, name: "New", systemUUID: UUID().uuidString)], existing: [], defaults: defaults)
        XCTAssertNil(merged[0].macInput)
        XCTAssertNil(merged[0].windowsInput)
    }

    func testSuccessfulReviewedSaveClearsPersistentSafetyState() throws {
        storage.values[DisplayConfigurationStore.storageKey] = Data("bad".utf8)
        XCTAssertNotEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .ready)
        let recovery = populatedDocument()
        try DisplayConfigurationStore.saveDocument(recovery, storage: storage)
        XCTAssertFalse(storage.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .ready)
    }

    private func populatedDocument() -> DisplayConfigurationStoreV3Document {
        let displays = [display(name: "Left"), display(name: "Right")]
        var profile = profile(name: "Windows")
        profile.peerHost = "172.16.10.20"
        profile.pairingCode = ephemeralPairingCode()
        profile.displayInputs = [DisplayInputMapping(displayID: displays[0].id, peerInput: 18)]
        return DisplayConfigurationStoreV3Document(schemaVersion: 3, localEndpointID: UUID().uuidString,
            localDeviceName: "Mac", listenPort: 49731, displays: displays, collaborationProfiles: [profile])
    }

    private func profile(name: String) -> CollaborationProfile {
        CollaborationProfile(id: UUID().uuidString, name: name, peerHost: "", peerPort: 49731,
            pairingCode: "", peerEndpointID: nil, peerProtocolVersion: nil, coordinationEnabled: false,
            displayInputs: [], triggerDevices: [])
    }

    private func display(name: String) -> DisplayConfigurationV3Display {
        DisplayConfigurationV3Display(id: UUID().uuidString, name: name, selector: UUID().uuidString,
            localInput: nil, readEnabled: false, brightnessEnabled: true, contrastEnabled: true, volumeEnabled: true)
    }

    private func legacyDisplay(index: Int, local: Int, peer: Int) -> DisplayConfiguration {
        DisplayConfiguration(index: index, name: "Display \(index)", selector: UUID().uuidString,
            macInput: local, windowsInput: peer, readEnabled: true)
    }

    private func ephemeralPairingCode() -> String {
        UUID().uuidString
    }
}
