import XCTest

final class DDCBackendTests: XCTestCase {
    func testC016ThreeControlsReadNormallyAndCommitByStableID() {
        let backend = MockDDCBackend()
        backend.readings = [
            "display-a": [.luminance: DDCReading(current: 41, maximum: 100),
                          .contrast: DDCReading(current: 52, maximum: 100),
                          .volume: DDCReading(current: 7, maximum: 20)]
        ]
        let cache = MockDDCCache()
        let service = makeService(backends: [backend], cache: cache)

        let result = service.read([target(id: "display-a")])

        XCTAssertEqual(result["display-a"]?[.luminance], DDCResolvedReading(
            reading: DDCReading(current: 41, maximum: 100), estimated: false))
        XCTAssertEqual(result["display-a"]?[.contrast]?.reading.current, 52)
        XCTAssertEqual(result["display-a"]?[.volume]?.reading.current, 7)
        XCTAssertEqual(cache.values["display-a"]?[.luminance], 41)
        XCTAssertEqual(backend.readCalls.count, 3)
    }

    func testC017ThreeSuccessfulZerosAreUntrustedAndDoNotOverwriteCache() {
        let backend = MockDDCBackend()
        backend.readings = ["display-a": Dictionary(uniqueKeysWithValues:
            DDCCommand.userControls.map { ($0, DDCReading(current: 0, maximum: 100)) })]
        let cache = MockDDCCache(values: ["display-a": [.luminance: 35, .contrast: 46, .volume: 8]])
        let service = makeService(backends: [backend], cache: cache)

        let result = service.read([target(id: "display-a")])

        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 35)
        XCTAssertTrue(result["display-a"]?[.luminance]?.estimated == true)
        XCTAssertEqual(cache.values["display-a"]?[.contrast], 46)
        XCTAssertEqual(cache.writeCount, 0)
    }

    func testC018SingleZeroIsValidWhenOtherControlsAreNonzero() {
        let backend = MockDDCBackend()
        backend.readings = ["display-a": [
            .luminance: DDCReading(current: 0, maximum: 100),
            .contrast: DDCReading(current: 50, maximum: 100),
            .volume: DDCReading(current: 9, maximum: 20)
        ]]
        let cache = MockDDCCache()
        let service = makeService(backends: [backend], cache: cache)

        let result = service.read([target(id: "display-a")])

        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 0)
        XCTAssertFalse(result["display-a"]?[.luminance]?.estimated ?? true)
        XCTAssertEqual(cache.values["display-a"]?[.luminance], 0)
    }

    func testC019DisplayAndControlFailuresRemainIsolated() {
        let backend = MockDDCBackend()
        backend.readings = [
            "display-a": [.luminance: DDCReading(current: 25, maximum: 100)],
            "display-b": [.luminance: DDCReading(current: 75, maximum: 100)]
        ]
        backend.readFailures = ["display-a": [.contrast]]
        backend.writeFailures = ["display-a": [.luminance]]
        let cache = MockDDCCache(values: ["display-a": [.contrast: 44]])
        let service = makeService(backends: [backend], cache: cache)

        let readings = service.read([
            target(id: "display-b", commands: [.luminance]),
            target(id: "display-a", commands: [.luminance, .contrast])
        ])
        let failures = service.write(command: .luminance, value: 60, targets: [
            target(id: "display-a"), target(id: "display-b")
        ])

        XCTAssertEqual(readings["display-a"]?[.contrast]?.reading.current, 44)
        XCTAssertTrue(readings["display-a"]?[.contrast]?.estimated == true)
        XCTAssertEqual(readings["display-b"]?[.luminance]?.reading.current, 75)
        XCTAssertNotNil(failures["display-a"])
        XCTAssertNil(failures["display-b"])
        XCTAssertEqual(cache.values["display-b"]?[.luminance], 60)
        XCTAssertNotEqual(cache.values["display-a"]?[.luminance], 60)
    }

    func testC020DisabledControlsPerformNoReadOrWrite() {
        let backend = MockDDCBackend()
        let service = makeService(backends: [backend], cache: MockDDCCache())
        let disabled = target(id: "display-a", readEnabled: false, commands: [])

        XCTAssertTrue(service.read([disabled]).isEmpty)
        XCTAssertTrue(service.write(command: .luminance, value: 50, targets: [disabled]).isEmpty)
        XCTAssertEqual(backend.readCalls.count, 0)
        XCTAssertEqual(backend.writeCalls.count, 0)
    }

    func testC024DellAllZeroSimulationRemainsEstimatedAndPreservesCache() {
        let backend = MockDDCBackend()
        backend.readings = ["display-dell": Dictionary(uniqueKeysWithValues:
            DDCCommand.userControls.map { ($0, DDCReading(current: 0, maximum: 0)) })]
        let cache = MockDDCCache(values: ["display-dell": [.luminance: 63]])
        let service = makeService(backends: [backend], cache: cache)

        let result = service.read([target(id: "display-dell")])

        XCTAssertEqual(result["display-dell"]?[.luminance]?.reading.current, 63)
        XCTAssertTrue(result["display-dell"]?[.luminance]?.estimated == true)
        XCTAssertNil(result["display-dell"]?[.contrast])
        XCTAssertEqual(cache.writeCount, 0)
    }

    func testNativeAvailableUnavailableAndFailureUseFallback() throws {
        let native = MockDDCBackend(identifier: "native")
        let fallback = MockDDCBackend(identifier: "m1ddc")
        native.readings = ["display-a": [.luminance: DDCReading(current: 30, maximum: 100)]]
        fallback.readings = ["display-a": [.luminance: DDCReading(current: 70, maximum: 100)]]
        let token = DDCCancellationToken()
        let router = DDCBackendRouter(backends: [native, fallback])

        let nativeRead = try router.read(stableID: "display-a", selector: "selector-a",
                                         command: .luminance, token: token)
        XCTAssertEqual(nativeRead.current, 30)
        XCTAssertEqual(fallback.readCalls.count, 0)

        native.readFailures = ["display-a": [.luminance]]
        let failedRead = try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token)
        XCTAssertEqual(failedRead.current, 70)

        native.availabilityValue = .unavailable("unsupported architecture")
        let unavailableRead = try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token)
        XCTAssertEqual(unavailableRead.current, 70)
        XCTAssertEqual(native.readCalls.count, 2)
        XCTAssertEqual(fallback.readCalls.count, 2)

        native.availabilityValue = .available
        native.writeFailures = ["display-a": [.contrast]]
        try router.write(stableID: "display-a", selector: "selector-a", command: .contrast,
                         value: 55, token: token)
        XCTAssertEqual(fallback.writeCalls.count, 1)
        native.writeFailures = [:]
        try router.write(stableID: "display-a", selector: "selector-a", command: .volume,
                         value: 8, token: token)
        XCTAssertEqual(fallback.writeCalls.count, 1)

        fallback.displays = [DDCBackendDisplay(stableID: "display-a", name: "A", selector: "selector-a")]
        native.availabilityValue = .unavailable("unsupported architecture")
        XCTAssertEqual(try router.enumerateDisplays(token: token), fallback.displays)
    }

    func testCancellationAndLateReadCannotCommitCacheOrResult() {
        let backend = MockDDCBackend()
        backend.readings = ["display-a": [.luminance: DDCReading(current: 88, maximum: 100)]]
        let cache = MockDDCCache(values: ["display-a": [.luminance: 22]])
        let service = makeService(backends: [backend], cache: cache)
        backend.onRead = { service.setOperationsAllowed(false) }

        let result = service.read([target(id: "display-a", commands: [.luminance])])

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(cache.values["display-a"]?[.luminance], 22)
        XCTAssertEqual(cache.writeCount, 0)
        XCTAssertEqual(backend.cancelCount, 1)

        service.setOperationsAllowed(true)
        backend.onRead = nil
        backend.onWrite = { service.setOperationsAllowed(false) }
        let failures = service.write(command: .luminance, value: 77,
                                     targets: [target(id: "display-a")])
        XCTAssertNotNil(failures["display-a"])
        XCTAssertEqual(cache.values["display-a"]?[.luminance], 22)
        XCTAssertEqual(cache.writeCount, 0)
        XCTAssertEqual(backend.cancelCount, 2)
    }

    func testEnumerationReorderDoesNotChangeStableIDAssociation() throws {
        let backend = MockDDCBackend()
        backend.displays = [
            DDCBackendDisplay(stableID: "display-b", name: "B", selector: "selector-b"),
            DDCBackendDisplay(stableID: "display-a", name: "A", selector: "selector-a")
        ]
        backend.readings = [
            "display-a": [.luminance: DDCReading(current: 10, maximum: 100)],
            "display-b": [.luminance: DDCReading(current: 90, maximum: 100)]
        ]
        let service = makeService(backends: [backend], cache: MockDDCCache())

        XCTAssertEqual(try service.enumerateDisplays().map(\.stableID), ["display-b", "display-a"])
        let result = service.read([
            target(id: "display-b", selector: "selector-b", commands: [.luminance]),
            target(id: "display-a", selector: "selector-a", commands: [.luminance])
        ])
        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 10)
        XCTAssertEqual(result["display-b"]?[.luminance]?.reading.current, 90)
    }

    func testConfigurationAndUSBLearningSafetyStatesIssueNoDDCCalls() {
        for _ in 0..<2 {
            let backend = MockDDCBackend()
            let service = makeService(backends: [backend], cache: MockDDCCache())
            service.setOperationsAllowed(false)
            XCTAssertTrue(service.read([target(id: "display-a")]).isEmpty)
            XCTAssertNotNil(service.write(command: .luminance, value: 50,
                                          targets: [target(id: "display-a")])["display-a"])
            XCTAssertEqual(backend.readCalls.count, 0)
            XCTAssertEqual(backend.writeCalls.count, 0)
        }
    }

    private func makeService(backends: [DDCBackend], cache: MockDDCCache) -> DDCControlService {
        DDCControlService(router: DDCBackendRouter(backends: backends), cache: cache)
    }

    private func target(id: String, selector: String? = nil, readEnabled: Bool = true,
                        commands: Set<DDCCommand> = DDCCommand.userControls) -> DDCDisplayTarget {
        DDCDisplayTarget(stableID: id, selector: selector ?? "selector-\(id)",
                         readEnabled: readEnabled, enabledCommands: commands)
    }
}

private final class MockDDCCache: DDCValueCache {
    var values: [String: [DDCCommand: Int]]
    private(set) var writeCount = 0

    init(values: [String: [DDCCommand: Int]] = [:]) {
        self.values = values
    }

    func value(stableID: String, command: DDCCommand) -> Int? {
        values[stableID]?[command]
    }

    func setValue(_ value: Int, stableID: String, command: DDCCommand) {
        values[stableID, default: [:]][command] = value
        writeCount += 1
    }
}

private final class MockDDCBackend: DDCBackend {
    let identifier: String
    var availabilityValue: DDCBackendAvailability = .available
    var availability: DDCBackendAvailability { availabilityValue }
    let capabilities = DDCBackendCapabilities(canEnumerate: true, canReadVCP: true, canWriteVCP: true)
    var displays: [DDCBackendDisplay] = []
    var readings: [String: [DDCCommand: DDCReading]] = [:]
    var readFailures: [String: Set<DDCCommand>] = [:]
    var writeFailures: [String: Set<DDCCommand>] = [:]
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?
    private(set) var readCalls: [(String, DDCCommand)] = []
    private(set) var writeCalls: [(String, DDCCommand, Int)] = []
    private(set) var cancelCount = 0

    init(identifier: String = "mock") {
        self.identifier = identifier
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        try token.throwIfCancelled()
        return displays
    }

    func read(stableID: String, selector: String, command: DDCCommand,
              token: DDCCancellationToken) throws -> DDCReading {
        try token.throwIfCancelled()
        readCalls.append((stableID, command))
        onRead?()
        if readFailures[stableID]?.contains(command) == true {
            throw DDCBackendError.readFailed(stableID: stableID, command: command)
        }
        guard let value = readings[stableID]?[command] else {
            throw DDCBackendError.readFailed(stableID: stableID, command: command)
        }
        return value
    }

    func write(stableID: String, selector: String, command: DDCCommand, value: Int,
               token: DDCCancellationToken) throws {
        try token.throwIfCancelled()
        writeCalls.append((stableID, command, value))
        onWrite?()
        if writeFailures[stableID]?.contains(command) == true {
            throw DDCBackendError.writeFailed(stableID: stableID, command: command)
        }
    }

    func cancelAll() {
        cancelCount += 1
    }
}
