import XCTest

final class DDCBackendTests: XCTestCase {
    func testNativeWriteKeepsEarlierAcceptedCycleWhenTypeCPathDrops() {
        var results = [true, false]
        var calls = 0

        let accepted = NativeDDCWriteCyclePolicy.perform(cycles: 2) {
            calls += 1
            return results.removeFirst()
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(calls, 2)
    }

    func testNativeWriteAcceptsLaterDuplicateCycle() {
        var results = [false, true]
        XCTAssertTrue(NativeDDCWriteCyclePolicy.perform(cycles: 2) {
            results.removeFirst()
        })
    }

    func testNativeWriteRejectsOnlyWhenEveryCycleFails() {
        var calls = 0
        XCTAssertFalse(NativeDDCWriteCyclePolicy.perform(cycles: 2) {
            calls += 1
            return false
        })
        XCTAssertEqual(calls, 2)
    }

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
        let disabled = target(id: "display-a", commands: [])

        let result = service.read([disabled])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.skipped["display-a"], .noEnabledCommands)
        XCTAssertEqual(result.skipped["display-a"]?.userFacingDescription,
                       "未开启可读取的 DDC 功能")
        XCTAssertTrue(service.write(command: .luminance, value: 50, targets: [disabled]).isEmpty)
        XCTAssertEqual(backend.readCalls.count, 0)
        XCTAssertEqual(backend.writeCalls.count, 0)
    }

    func testLegacyReadDisabledDoesNotBlockEnabledLuminance() {
        let stored = DisplayConfigurationV4Display(
            id: "display-a", name: "模拟显示器", selector: "selector-a",
            localInput: nil, readEnabled: false, brightnessEnabled: true,
            contrastEnabled: false, volumeEnabled: false
        )
        let commands = DisplaySettingsSemantics.enabledCommands(for: stored)
        let backend = MockDDCBackend()
        backend.readings = ["display-a": [.luminance: DDCReading(current: 42, maximum: 100)]]
        let service = makeService(backends: [backend], cache: MockDDCCache())

        let result = service.read([target(id: "display-a", commands: commands)])

        XCTAssertEqual(commands, [.luminance])
        XCTAssertEqual(backend.readCalls.map(\.1), [.luminance])
        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 42)
    }

    func testC024SimulatedDisplayAllZeroRemainsEstimatedAndPreservesCache() {
        let backend = MockDDCBackend()
        backend.readings = ["simulated-display": Dictionary(uniqueKeysWithValues:
            DDCCommand.userControls.map { ($0, DDCReading(current: 0, maximum: 0)) })]
        let cache = MockDDCCache(values: ["simulated-display": [.luminance: 63]])
        let service = makeService(backends: [backend], cache: cache)

        let result = service.read([target(id: "simulated-display")])

        XCTAssertEqual(result["simulated-display"]?[.luminance]?.reading.current, 63)
        XCTAssertTrue(result["simulated-display"]?[.luminance]?.estimated == true)
        XCTAssertNil(result["simulated-display"]?[.contrast])
        XCTAssertEqual(cache.writeCount, 0)
    }

    func testNativeSuccessAndEveryNativeFailureNeverUseM1DDC() throws {
        let native = MockDDCBackend(identifier: "apple-silicon-native")
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
        XCTAssertThrowsError(try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token))

        native.availabilityValue = .unavailable("unsupported architecture")
        XCTAssertThrowsError(try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token))
        XCTAssertEqual(native.readCalls.count, 2)
        XCTAssertEqual(fallback.readCalls.count, 0)

        native.availabilityValue = .available
        native.writeFailures = ["display-a": [.contrast]]
        XCTAssertThrowsError(try router.write(stableID: "display-a", selector: "selector-a",
                                              command: .contrast, value: 55, token: token))
        XCTAssertEqual(fallback.writeCalls.count, 0)
        native.writeFailures = [:]
        try router.write(stableID: "display-a", selector: "selector-a", command: .volume,
                         value: 8, token: token)
        XCTAssertEqual(fallback.writeCalls.count, 0)

        fallback.displays = [DDCBackendDisplay(stableID: "display-a", name: "A", selector: "selector-a")]
        native.availabilityValue = .unavailable("unsupported architecture")
        XCTAssertThrowsError(try router.enumerateDisplays(token: token))
        XCTAssertEqual(fallback.enumerateCount, 0)
    }

    func testPersistedControlChannelCannotReenableM1DDC() throws {
        let native = MockDDCBackend(identifier: "apple-silicon-native")
        let fallback = MockDDCBackend(identifier: "m1ddc")
        native.readings = ["display-a": [.luminance: DDCReading(current: 31, maximum: 100)]]
        fallback.readings = ["display-a": [.luminance: DDCReading(current: 72, maximum: 100)]]
        let router = DDCBackendRouter(backends: [native, fallback])
        let token = DDCCancellationToken()

        router.setControlChannel(.native)
        XCTAssertEqual(try router.read(stableID: "display-a", selector: "selector-a",
                                       command: .luminance, token: token).current, 31)
        XCTAssertEqual(fallback.readCalls.count, 0)

        for channel in DDCControlChannel.allCases {
            router.setControlChannel(channel)
            XCTAssertEqual(try router.read(stableID: "display-a", selector: "selector-a",
                                           command: .luminance, token: token).current, 31)
        }
        XCTAssertEqual(fallback.readCalls.count, 0)
    }

    func testProductNamesAndSameModelStableLocalOrdinalsSurviveEnumerationReorder() {
        let known = [
            DDCKnownDisplay(stableID: "stable-b", name: "显示器 1", selector: "selector-b"),
            DDCKnownDisplay(stableID: "stable-a", name: "Studio Panel", selector: "selector-a"),
            DDCKnownDisplay(stableID: "stable-c", name: "显示器 3", selector: "selector-c")
        ]
        let displays = [
            DDCBackendDisplay(stableID: "stable-a", name: "Generic Panel", selector: "selector-a"),
            DDCBackendDisplay(stableID: "stable-c", name: "Generic Panel", selector: "selector-c"),
            DDCBackendDisplay(stableID: "stable-b", name: "Generic Panel", selector: "selector-b")
        ]

        let first = DisplayPresentationNameResolver.names(for: displays, knownDisplays: known)
        let reordered = DisplayPresentationNameResolver.names(
            for: [displays[2], displays[0], displays[1]], knownDisplays: known
        )

        XCTAssertEqual(first["stable-a"], "Studio Panel")
        XCTAssertEqual(first["stable-b"], "Generic Panel（1）")
        XCTAssertEqual(first["stable-c"], "Generic Panel（2）")
        XCTAssertEqual(first, reordered)
        XCTAssertFalse(first.values.contains { $0.contains("selector") || $0.contains("stable-") })
    }

    func testTwoDifferentModelsKeepSystemProductNames() {
        let displays = [
            DDCBackendDisplay(stableID: "a", name: "Office Panel", selector: "one"),
            DDCBackendDisplay(stableID: "b", name: "Creator Panel", selector: "two")
        ]
        let names = DisplayPresentationNameResolver.names(for: displays, knownDisplays: [])
        XCTAssertEqual(names["a"], "Office Panel")
        XCTAssertEqual(names["b"], "Creator Panel")
    }

    func testNativeServiceMatchingUsesLocationAndNeverReusesAService() {
        let identities = [
            NativeDisplayIdentity(stableID: "display-a", ioDisplayLocation: "location-a",
                                  productName: "Same Model", serialNumber: 101, edidSearchKeys: []),
            NativeDisplayIdentity(stableID: "display-b", ioDisplayLocation: "location-b",
                                  productName: "Same Model", serialNumber: 202, edidSearchKeys: []),
            NativeDisplayIdentity(stableID: "display-unbound", ioDisplayLocation: "location-c",
                                  productName: "Unknown", serialNumber: 0, edidSearchKeys: [])
        ]
        let candidates = [
            NativeTransportCandidate(serviceLocation: 2, ioDisplayLocation: "location-b",
                                     productName: "Same Model", serialNumber: 202, edidUUID: ""),
            NativeTransportCandidate(serviceLocation: 1, ioDisplayLocation: "location-a",
                                     productName: "Same Model", serialNumber: 101, edidUUID: "")
        ]

        let matches = NativeDisplayMatcher.matches(identities: identities, candidates: candidates)

        XCTAssertEqual(matches["display-a"], 1)
        XCTAssertEqual(matches["display-b"], 2)
        XCTAssertNil(matches["display-unbound"])
        XCTAssertEqual(Set(matches.values).count, matches.count)
    }

    func testNativeGetVCPReplyValidationRejectsWrongOrLateFrames() throws {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, DDCCommand.luminance.rawValue,
                              0x00, 0x00, 0x64, 0x00, 0x2A, 0x00]
        reply[10] = reply.dropLast().reduce(UInt8(0x50), ^)
        XCTAssertEqual(
            try NativeDDCReplyValidator.reading(from: reply, command: .luminance).get(),
            DDCReading(current: 42, maximum: 100)
        )

        var wrongCommand = reply
        wrongCommand[4] = DDCCommand.contrast.rawValue
        wrongCommand[10] = wrongCommand.dropLast().reduce(UInt8(0x50), ^)
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: wrongCommand, command: .luminance),
            .failure(.wrongCommand)
        )

        var rejected = reply
        rejected[3] = 1
        rejected[10] = rejected.dropLast().reduce(UInt8(0x50), ^)
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: rejected, command: .luminance),
            .failure(.monitorRejected)
        )

        var badChecksum = reply
        badChecksum[10] ^= 0xFF
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: badChecksum, command: .luminance),
            .failure(.badChecksum)
        )
    }

    func testNativeReadTransportParametersAreExplicitAndTestable() {
        let parameters = NativeDDCTransportParameters.appleSiliconDDCCompatible
        XCTAssertEqual(parameters.writeDataAddress, 0x51)
        XCTAssertEqual(parameters.readDataAddress(for: .typeCDPAlt), 0x51)
        XCTAssertEqual(parameters.readDataAddress(for: .builtinHDMIConverter), 0x00)
        XCTAssertEqual(parameters.readSleepMicroseconds(for: .typeCDPAlt), 50_000)
        XCTAssertEqual(parameters.readSleepMicroseconds(for: .builtinHDMIConverter), 50_000)
        XCTAssertEqual(parameters.readAttempts(for: .typeCDPAlt), 5)
        XCTAssertEqual(parameters.readAttempts(for: .builtinHDMIConverter), 5)
        XCTAssertEqual(parameters.writeCycles, 2)
        XCTAssertEqual(parameters.writeAttempts, 5)
    }

    func testNativeTransportPathClassificationIsDeterministicAndSanitized() {
        XCTAssertEqual(
            NativeDisplayEndpointToken.extract(from: ["synthetic/dispextE:/proxy"]),
            "dispextE"
        )
        XCTAssertEqual(
            NativeTransportPathClassifier.classify(
                endpointToken: "dispextE", epicProviderClass: nil, transportDescription: nil
            ),
            .builtinHDMIConverter
        )
        for endpoint in ["dispext0", "dispext1"] {
            XCTAssertEqual(
                NativeDisplayEndpointToken.extract(from: ["synthetic/\(endpoint):/proxy"]),
                endpoint
            )
            XCTAssertEqual(
                NativeTransportPathClassifier.classify(
                    endpointToken: endpoint, epicProviderClass: nil, transportDescription: nil
                ),
                .typeCDPAlt
            )
        }
        XCTAssertEqual(
            NativeTransportPathClassifier.classify(
                epicProviderClass: "AppleDCPMCDP29XX", transportDescription: nil
            ),
            .builtinHDMIConverter
        )
        XCTAssertEqual(
            NativeTransportPathClassifier.classify(
                epicProviderClass: nil, transportDescription: "DisplayPort over USB-C"
            ),
            .typeCDPAlt
        )
        XCTAssertEqual(
            NativeTransportPathClassifier.classify(
                endpointToken: "future-endpoint",
                epicProviderClass: "FutureProvider", transportDescription: nil
            ),
            .unknownExternal
        )

        let parameters = NativeDDCTransportParameters.appleSiliconDDCCompatible
        XCTAssertEqual(parameters.readDataAddress(for: .builtinHDMIConverter), 0)
        XCTAssertEqual(parameters.readDataAddress(for: .typeCDPAlt), 0x51)
    }

    func testNativeDiagnosticsExposeOnlySanitizedTransportState() {
        let snapshot = NativeDDCDiagnosticSnapshot(
            transportPath: .builtinHDMIConverter,
            serviceMatched: true,
            operationCategory: .readResponseTimeout,
            rebuildCount: 1,
            replyIssue: .responseTimeout,
            readDataAddress: 0,
            readAttemptCount: 5
        )

        XCTAssertEqual(
            snapshot.userFacingDescription,
            "builtin-hdmi-converter · service matched · read-response-timeout · offset 0 · attempts 5 · rebuild 1"
        )
        XCTAssertFalse(snapshot.userFacingDescription.contains("IOService"))
        XCTAssertFalse(snapshot.userFacingDescription.contains("/"))
    }

    func testEveryRejectedReplyReasonHasSanitizedDiagnosticProjection() {
        let issues: [(NativeDDCReplyIssue, String)] = [
            (.badChecksum, "bad-checksum"),
            (.wrongSource, "wrong-source"),
            (.wrongLength, "wrong-length"),
            (.wrongPayloadLength, "wrong-payload-length"),
            (.wrongOpcode, "wrong-opcode"),
            (.monitorRejected, "monitor-rejected"),
            (.wrongCommand, "wrong-command")
        ]

        for (issue, code) in issues {
            let snapshot = NativeDDCDiagnosticSnapshot(
                transportPath: .typeCDPAlt,
                serviceMatched: true,
                operationCategory: .readReplyRejected,
                rebuildCount: 1,
                replyIssue: issue,
                readDataAddress: 0x51,
                readAttemptCount: 5
            )
            XCTAssertTrue(snapshot.userFacingDescription.contains("read-reply-rejected/\(code)"))
            XCTAssertTrue(snapshot.userFacingDescription.contains("offset 0x51"))
            XCTAssertTrue(snapshot.userFacingDescription.contains("attempts 5"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("UUID"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("IOService"))
        }
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

    private func target(id: String, selector: String? = nil,
                        commands: Set<DDCCommand> = DDCCommand.userControls) -> DDCDisplayTarget {
        DDCDisplayTarget(stableID: id, selector: selector ?? "selector-\(id)",
                         enabledCommands: commands)
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
    private(set) var enumerateCount = 0

    init(identifier: String = "apple-silicon-native") {
        self.identifier = identifier
    }

    func enumerateDisplays(token: DDCCancellationToken) throws -> [DDCBackendDisplay] {
        try token.throwIfCancelled()
        enumerateCount += 1
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
