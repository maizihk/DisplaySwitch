import XCTest

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

        let values = DisplayConfigurationStore.loadAll(defaults: defaults)

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[1].name, "Legacy Dell")
        XCTAssertEqual(values[1].selector, "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        XCTAssertEqual(values[1].macInput, 27)
        XCTAssertNotNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
    }

    func testFreshInstallDoesNotCreateHardwareSpecificDefaults() {
        let values = DisplayConfigurationStore.loadAll(defaults: defaults)

        XCTAssertTrue(values.isEmpty)
        XCTAssertNil(defaults.data(forKey: DisplayConfigurationStore.storageKey))
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

        DisplayConfigurationStore.saveAll(values, defaults: defaults)
        let loaded = DisplayConfigurationStore.loadAll(defaults: defaults)

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

        let merged = DisplayConfigurationStore.merge(
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

        let merged = DisplayConfigurationStore.merge(
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

        let merged = DisplayConfigurationStore.merge(
            detected: detected,
            existing: [existing],
            defaults: defaults
        )

        XCTAssertNil(merged[0].macInput)
        XCTAssertNil(merged[0].windowsInput)
        XCTAssertFalse(merged[0].readEnabled)
    }
}
