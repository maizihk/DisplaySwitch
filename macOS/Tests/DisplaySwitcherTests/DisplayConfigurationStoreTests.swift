import XCTest

private final class TestDisplayConfigurationStorage: DisplayConfigurationStorage {
    let defaults: UserDefaults
    var failDocumentWrites = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }

    func writeDocument(_ data: Data, forKey key: String) throws {
        if failDocumentWrites {
            throw DisplayConfigurationStoreError.writeFailed
        }
        defaults.set(data, forKey: key)
    }
}

final class DisplayConfigurationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DisplaySwitcherTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesLegacyTwoDisplayConfiguration() {
        defaults.set("Legacy Dell", forKey: "Display.2.Name")
        defaults.set("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", forKey: "Display.2.Selector")
        defaults.set(27, forKey: "Display.2.MacInput")

        let result = DisplayConfigurationStore.load(defaults: defaults)
        let values = result.configurations

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[1].name, "Legacy Dell")
        XCTAssertEqual(values[1].selector, "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        XCTAssertEqual(values[1].macInput, 27)
        XCTAssertNotNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertEqual(defaults.string(forKey: "Display.2.Name"), "Legacy Dell")
    }

    func testFreshInstallDoesNotCreateHardwareSpecificDefaults() {
        let result = DisplayConfigurationStore.load(defaults: defaults)
        let values = result.configurations

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertTrue(values.isEmpty)
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey))
    }

    func testPersistsArbitraryDisplayCountAndNormalizesOrder() {
        let values = (1...3).map {
            DisplayConfiguration(
                index: 10 - $0,
                name: "Display \($0)",
                selector: "selector-\($0)",
                macInput: 10 + $0,
                windowsInput: 20 + $0,
                readEnabled: true
            )
        }

        XCTAssertNoThrow(try DisplayConfigurationStore.saveAll(values, defaults: defaults))
        let result = DisplayConfigurationStore.load(defaults: defaults)
        let loaded = result.configurations

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.index), [1, 2, 3])
        XCTAssertEqual(loaded.map(\.selector), ["selector-1", "selector-2", "selector-3"])
    }

    func testMergeMatchesUUIDInsteadOfDetectionPosition() {
        let first = DisplayConfiguration(
            index: 1,
            name: "First",
            selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            macInput: 11,
            windowsInput: 21,
            readEnabled: true
        )
        let second = DisplayConfiguration(
            index: 2,
            name: "Second",
            selector: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            macInput: 12,
            windowsInput: 22,
            readEnabled: false
        )
        let detected = [
            DetectedDisplay(index: 1, name: "Second", systemUUID: second.selector),
            DetectedDisplay(index: 2, name: "First", systemUUID: first.selector)
        ]

        let merged = try! DisplayConfigurationStore.merge(
            detected: detected,
            existing: [first, second],
            defaults: defaults
        )

        XCTAssertEqual(merged.map(\.selector), [second.selector, first.selector])
        XCTAssertEqual(merged.map(\.windowsInput), [22, 21])
        XCTAssertEqual(merged.map(\.readEnabled), [false, true])
    }

    func testNewlyDetectedDisplayDoesNotGuessInputSources() {
        let detected = [
            DetectedDisplay(
                index: 1,
                name: "Unknown Monitor",
                systemUUID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )
        ]

        let merged = try! DisplayConfigurationStore.merge(
            detected: detected,
            existing: [],
            defaults: defaults
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertNil(merged[0].macInput)
        XCTAssertNil(merged[0].windowsInput)
        XCTAssertFalse(merged[0].readEnabled)
    }

    func testReplacementDisplayDoesNotInheritStableUUIDConfigurationByPosition() {
        let existing = DisplayConfiguration(
            index: 1,
            name: "Previous Monitor",
            selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            macInput: 11,
            windowsInput: 21,
            readEnabled: true
        )
        let detected = [
            DetectedDisplay(
                index: 1,
                name: "Replacement Monitor",
                systemUUID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )
        ]

        let merged = try! DisplayConfigurationStore.merge(
            detected: detected,
            existing: [existing],
            defaults: defaults
        )

        XCTAssertNil(merged[0].macInput)
        XCTAssertNil(merged[0].windowsInput)
        XCTAssertFalse(merged[0].readEnabled)
    }

    func testMigratesV1ArrayWithoutOverwritingOriginalData() throws {
        let original = [configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")]
        let originalData = try JSONEncoder().encode(original)
        defaults.set(originalData, forKey: DisplayConfigurationStore.legacyArrayStorageKey)

        let result = DisplayConfigurationStore.load(defaults: defaults)

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.configurations, original)
        XCTAssertEqual(
            defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey),
            originalData
        )
        let documentData = try XCTUnwrap(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        let document = try JSONDecoder().decode(DisplayConfigurationDocument.self, from: documentData)
        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.displays, original)
    }

    func testSchemaVersion2RoundTrip() throws {
        let values = [
            configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            configuration(index: 2, selector: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        ]

        try DisplayConfigurationStore.saveAll(values, defaults: defaults)
        let result = DisplayConfigurationStore.load(defaults: defaults)

        XCTAssertEqual(result.safetyState, .ready)
        XCTAssertEqual(result.configurations, values)
        let data = try XCTUnwrap(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(DisplayConfigurationDocument.self, from: data).schemaVersion, 2)
    }

    func testUnknownSchemaVersionIsRejectedWithoutOverwritingData() throws {
        let original = Data(#"{"schemaVersion":99,"displays":[]}"#.utf8)
        defaults.set(original, forKey: DisplayConfigurationStore.storageKey)

        let result = DisplayConfigurationStore.load(defaults: defaults)

        XCTAssertEqual(result.safetyState, .requiresUserReview(.unsupportedSchemaVersion(99)))
        XCTAssertTrue(result.configurations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: DisplayConfigurationStore.storageKey), original)
    }

    func testCorruptedDataFailsSafeWithoutOverwritingData() {
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: DisplayConfigurationStore.storageKey)

        let result = DisplayConfigurationStore.load(defaults: defaults)

        XCTAssertEqual(result.safetyState, .requiresUserReview(.corruptedData))
        XCTAssertTrue(result.configurations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: DisplayConfigurationStore.storageKey), original)
    }

    func testMigrationWriteFailurePreservesV1Data() throws {
        let original = [configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")]
        let originalData = try JSONEncoder().encode(original)
        defaults.set(originalData, forKey: DisplayConfigurationStore.legacyArrayStorageKey)
        let storage = TestDisplayConfigurationStorage(defaults: defaults)
        storage.failDocumentWrites = true

        let result = DisplayConfigurationStore.load(storage: storage)

        XCTAssertEqual(result.safetyState, .requiresUserReview(.writeFailed))
        XCTAssertEqual(result.configurations, original)
        XCTAssertEqual(
            defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey),
            originalData
        )
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertTrue(defaults.bool(forKey: DisplayConfigurationStore.requiresReviewKey))

        storage.failDocumentWrites = false
        let automaticRetry = DisplayConfigurationStore.load(storage: storage)
        XCTAssertEqual(
            automaticRetry.safetyState,
            .requiresUserReview(.previousFailureRequiresReview)
        )

        try DisplayConfigurationStore.saveAll(automaticRetry.configurations, storage: storage)
        XCTAssertEqual(DisplayConfigurationStore.load(storage: storage).safetyState, .ready)
    }

    func testMigrationEncodingFailurePreservesV1Data() throws {
        let original = [configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")]
        let originalData = try JSONEncoder().encode(original)
        defaults.set(originalData, forKey: DisplayConfigurationStore.legacyArrayStorageKey)
        let storage = TestDisplayConfigurationStorage(defaults: defaults)

        let result = DisplayConfigurationStore.load(storage: storage) { _ in
            throw DisplayConfigurationStoreError.encodingFailed
        }

        XCTAssertEqual(result.safetyState, .requiresUserReview(.encodingFailed))
        XCTAssertEqual(result.configurations, original)
        XCTAssertEqual(
            defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey),
            originalData
        )
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
    }

    func testFailureStateBlocksAllHardwareAndNetworkSideEffects() {
        let gate = ConfigurationSafetyGate(
            state: .requiresUserReview(.corruptedData)
        )
        var usb = 0
        var ddc = 0
        var wake = 0
        var network = 0

        if gate.allows(.usb) { usb += 1 }
        if gate.allows(.ddc) { ddc += 1 }
        if gate.allows(.wake) { wake += 1 }
        if gate.allows(.network) { network += 1 }

        XCTAssertEqual(usb, 0)
        XCTAssertEqual(ddc, 0)
        XCTAssertEqual(wake, 0)
        XCTAssertEqual(network, 0)
    }

    func testFreshInstallEncodingFailureRemainsBlockedAfterRestartUntilReviewedSave() throws {
        try assertFreshInstallFailurePersistsAcrossRestart { storage, values in
            XCTAssertThrowsError(
                try DisplayConfigurationStore.saveAll(
                    values,
                    storage: storage,
                    encodeDocument: { _ in
                        throw DisplayConfigurationStoreError.encodingFailed
                    }
                )
            ) { error in
                XCTAssertEqual(error as? DisplayConfigurationStoreError, .encodingFailed)
            }
        }
    }

    func testFreshInstallWriteFailureRemainsBlockedAfterRestartUntilReviewedSave() throws {
        try assertFreshInstallFailurePersistsAcrossRestart { storage, values in
            storage.failDocumentWrites = true
            XCTAssertThrowsError(
                try DisplayConfigurationStore.saveAll(values, storage: storage)
            ) { error in
                XCTAssertEqual(error as? DisplayConfigurationStoreError, .writeFailed)
            }
        }
    }

    func testSuccessfulReviewedSaveCanExitSafetyState() throws {
        defaults.set(Data("not-json".utf8), forKey: DisplayConfigurationStore.storageKey)
        let failedResult = DisplayConfigurationStore.load(defaults: defaults)
        let gate = ConfigurationSafetyGate(state: failedResult.safetyState)
        let values = [configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")]

        XCTAssertTrue(defaults.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        try DisplayConfigurationStore.saveAll(values, defaults: defaults)
        let result = DisplayConfigurationStore.load(defaults: defaults)
        gate.apply(result)

        XCTAssertEqual(gate.state, .ready)
        XCTAssertFalse(defaults.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        XCTAssertTrue(ConfigurationSideEffect.allCases.allSatisfy(gate.allows))
    }

    private func configuration(
        index: Int = 1,
        selector: String
    ) -> DisplayConfiguration {
        DisplayConfiguration(
            index: index,
            name: "Display \(index)",
            selector: selector,
            macInput: 11 + index,
            windowsInput: 21 + index,
            readEnabled: true
        )
    }

    private func assertFreshInstallFailurePersistsAcrossRestart(
        firstSave: (TestDisplayConfigurationStorage, [DisplayConfiguration]) throws -> Void
    ) throws {
        XCTAssertEqual(DisplayConfigurationStore.load(defaults: defaults).safetyState, .ready)
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey))

        let values = [configuration(selector: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")]
        let firstStorage = TestDisplayConfigurationStorage(defaults: defaults)
        try firstSave(firstStorage, values)

        XCTAssertTrue(defaults.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.legacyArrayStorageKey))

        let restartedStorage = TestDisplayConfigurationStorage(defaults: defaults)
        let restartedResult = DisplayConfigurationStore.load(storage: restartedStorage)
        XCTAssertEqual(
            restartedResult.safetyState,
            .requiresUserReview(.previousFailureRequiresReview)
        )
        XCTAssertTrue(restartedResult.configurations.isEmpty)

        let restartedGate = ConfigurationSafetyGate(state: restartedResult.safetyState)
        var sideEffectCounts = Dictionary(
            uniqueKeysWithValues: ConfigurationSideEffect.allCases.map { ($0, 0) }
        )
        for sideEffect in ConfigurationSideEffect.allCases where restartedGate.allows(sideEffect) {
            sideEffectCounts[sideEffect, default: 0] += 1
        }
        XCTAssertEqual(sideEffectCounts[.usb], 0)
        XCTAssertEqual(sideEffectCounts[.ddc], 0)
        XCTAssertEqual(sideEffectCounts[.wake], 0)
        XCTAssertEqual(sideEffectCounts[.network], 0)

        restartedStorage.failDocumentWrites = false
        try DisplayConfigurationStore.saveAll(values, storage: restartedStorage)
        XCTAssertFalse(defaults.bool(forKey: DisplayConfigurationStore.requiresReviewKey))
        XCTAssertEqual(DisplayConfigurationStore.load(storage: restartedStorage).safetyState, .ready)
    }
}
