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
        let service = makeService(backend: backend, cache: cache)

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
        let service = makeService(backend: backend, cache: cache)

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
        let service = makeService(backend: backend, cache: cache)

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
        let service = makeService(backend: backend, cache: cache)

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
        let service = makeService(backend: backend, cache: MockDDCCache())
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
        let service = makeService(backend: backend, cache: MockDDCCache())

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
        let service = makeService(backend: backend, cache: cache)

        let result = service.read([target(id: "simulated-display")])

        XCTAssertEqual(result["simulated-display"]?[.luminance]?.reading.current, 63)
        XCTAssertTrue(result["simulated-display"]?[.luminance]?.estimated == true)
        XCTAssertNil(result["simulated-display"]?[.contrast])
        XCTAssertEqual(cache.writeCount, 0)
    }

    func testSingleNativeBackendSuccessAndFailuresRemainExplicit() throws {
        let native = MockDDCBackend(identifier: "apple-silicon-native")
        native.readings = ["display-a": [.luminance: DDCReading(current: 30, maximum: 100)]]
        let token = DDCCancellationToken()
        let router = DDCBackendRouter(backend: native)

        let nativeRead = try router.read(stableID: "display-a", selector: "selector-a",
                                         command: .luminance, token: token)
        XCTAssertEqual(nativeRead.current, 30)

        native.readFailures = ["display-a": [.luminance]]
        XCTAssertThrowsError(try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token))

        native.availabilityValue = .unavailable("unsupported architecture")
        XCTAssertThrowsError(try router.read(
            stableID: "display-a", selector: "selector-a", command: .luminance, token: token))
        XCTAssertEqual(native.readCalls.count, 2)

        native.availabilityValue = .available
        native.writeFailures = ["display-a": [.contrast]]
        XCTAssertThrowsError(try router.write(stableID: "display-a", selector: "selector-a",
                                              command: .contrast, value: 55, token: token))
        native.writeFailures = [:]
        try router.write(stableID: "display-a", selector: "selector-a", command: .volume,
                         value: 8, token: token)

        native.availabilityValue = .unavailable("unsupported architecture")
        XCTAssertThrowsError(try router.enumerateDisplays(token: token))
        XCTAssertEqual(native.enumerateCount, 0)
    }

    func testPlatformNeutralCommandNamesPreserveExistingCacheKeys() {
        let suite = "DisplaySwitcher.DDC.Cache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(73, forKey: "LastValue.stable.display-a.luminance")
        let cache = UserDefaultsDDCValueCache(defaults: defaults)

        XCTAssertEqual(cache.value(stableID: "DISPLAY-A", command: .luminance), 73)
        cache.setValue(44, stableID: "DISPLAY-A", command: .contrast)
        XCTAssertEqual(defaults.integer(forKey: "LastValue.stable.display-a.contrast"), 44)
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

    func testChecksumCompatibilityRejectsSingleBadReply() {
        let reply = badChecksumReply(current: 42, maximum: 100)
        XCTAssertEqual(
            NativeDDCChecksumCompatibilityValidator.reading(
                from: [reply], command: .luminance
            ),
            .rejected(
                .insufficientReplies,
                evidence: NativeDDCChecksumCompatibilityEvidence(replies: [reply])
            )
        )
    }

    func testChecksumCompatibilityAcceptsOnlyTwoConsistentIndependentReplies() {
        let reply = badChecksumReply(current: 42, maximum: 100)
        var buffersWereFresh: [Bool] = []
        var calls = 0
        let result = NativeDDCChecksumCompatibilityRunner.run(command: .luminance) { response in
            buffersWereFresh.append(response.allSatisfy { $0 == 0 })
            calls += 1
            response = reply
            return .success(())
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(buffersWereFresh, [true, true])
        XCTAssertEqual(
            result,
            .accepted(DDCReading(current: 42, maximum: 100, estimated: true))
        )
    }

    func testChecksumCompatibilityRejectsTwoDifferentReplies() {
        let comparison = NativeDDCChecksumPayloadComparison(
            commandMatches: true,
            currentMatches: false,
            maximumMatches: true,
            payloadLengths: [8, 8]
        )
        XCTAssertEqual(
            NativeDDCChecksumCompatibilityValidator.reading(
                from: [
                    badChecksumReply(current: 42, maximum: 100),
                    badChecksumReply(current: 43, maximum: 100)
                ],
                command: .luminance
            ),
            .rejected(
                .inconsistentPayload(comparison),
                evidence: NativeDDCChecksumCompatibilityEvidence(replies: [
                    badChecksumReply(current: 42, maximum: 100),
                    badChecksumReply(current: 43, maximum: 100)
                ])
            )
        )
    }

    func testChecksumCompatibilityRejectsInvalidFieldsAndRanges() {
        var wrongSource = badChecksumReply(current: 42, maximum: 100)
        wrongSource[0] = 0x00
        var wrongOpcode = badChecksumReply(current: 42, maximum: 100)
        wrongOpcode[2] = 0x03
        var wrongCommand = badChecksumReply(current: 42, maximum: 100)
        wrongCommand[4] = DDCCommand.contrast.rawValue
        let invalidCases: [([UInt8], NativeDDCChecksumCompatibilityRejection)] = [
            (Array(badChecksumReply(current: 42, maximum: 100).dropLast()),
             .invalidField(.wrongLength)),
            (wrongSource, .invalidField(.wrongSource)),
            (wrongOpcode, .invalidField(.wrongOpcode)),
            (wrongCommand, .invalidField(.wrongCommand)),
            (badChecksumReply(current: 1, maximum: 0), .invalidRange(current: 1, maximum: 0)),
            (badChecksumReply(current: 101, maximum: 100), .invalidRange(current: 101, maximum: 100))
        ]

        for (reply, expected) in invalidCases {
            XCTAssertEqual(
                NativeDDCChecksumCompatibilityValidator.reading(
                    from: [reply, reply], command: .luminance
                ),
                .rejected(
                    expected,
                    evidence: NativeDDCChecksumCompatibilityEvidence(replies: [reply, reply])
                )
            )
        }
    }

    func testEstimatedNativeReadingIsCachedAndProjectedAsEstimated() {
        let backend = MockDDCBackend()
        backend.readings = [
            "display-a": [
                .luminance: DDCReading(current: 42, maximum: 100, estimated: true)
            ]
        ]
        let cache = MockDDCCache()
        let service = makeService(backend: backend, cache: cache)

        let result = service.read([target(id: "display-a", commands: [.luminance])])

        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 42)
        XCTAssertTrue(result["display-a"]?[.luminance]?.estimated == true)
        XCTAssertEqual(cache.values["display-a"]?[.luminance], 42)
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

    func testNativeTransportAddressingSeparatesEndpointPathFromConverterChip() {
        XCTAssertEqual(
            NativeDDCTransportAddressing.resolve(
                endpointToken: "dispextE", epicProviderClass: nil,
                transportDescription: nil
            ),
            NativeDDCTransportAddressing(transportPath: .builtinHDMIConverter,
                                         chipAddress: 0x37)
        )
        XCTAssertEqual(
            NativeDDCTransportAddressing.resolve(
                endpointToken: "dispext1", epicProviderClass: "AppleDCPMCDP29XX",
                transportDescription: "HDMI"
            ),
            NativeDDCTransportAddressing(transportPath: .builtinHDMIConverter,
                                         chipAddress: 0xB7)
        )
        XCTAssertEqual(
            NativeDDCTransportAddressing.resolve(
                endpointToken: "dispext1", epicProviderClass: nil,
                transportDescription: "DisplayPort"
            ),
            NativeDDCTransportAddressing(transportPath: .typeCDPAlt,
                                         chipAddress: 0x37)
        )
    }

    func testTypeCReadFallsBackFromBadChecksumUsingFreshBoundedBuffers() {
        var addresses: [UInt8] = []
        var buffersWereFresh: [Bool] = []

        let outcome = NativeDDCReadStrategyRunner.run(
            primaryDataAddress: 0x51,
            alternateDataAddress: 0,
            attemptsPerStrategy: 5
        ) { address, response in
            addresses.append(address)
            buffersWereFresh.append(response.allSatisfy { $0 == 0 })
            response[0] = 0xFF
            if address == 0 {
                return .success(DDCReading(current: 42, maximum: 100))
            }
            return .failure(.badChecksum)
        }

        XCTAssertEqual(addresses, [0x51, 0x51, 0x51, 0x51, 0x51, 0])
        XCTAssertTrue(buffersWereFresh.allSatisfy { $0 })
        XCTAssertEqual(
            outcome,
            .success(DDCReading(current: 42, maximum: 100), dataAddress: 0, attempts: 6)
        )
    }

    func testTypeCReadStopsAfterBothBoundedStrategiesFail() {
        var addresses: [UInt8] = []
        let outcome = NativeDDCReadStrategyRunner.run(
            primaryDataAddress: 0x51,
            alternateDataAddress: 0,
            attemptsPerStrategy: 5
        ) { address, _ in
            addresses.append(address)
            return .failure(address == 0x51 ? .responseTimeout : .wrongCommand)
        }

        XCTAssertEqual(addresses.count, 10)
        XCTAssertEqual(Array(addresses.prefix(5)), Array(repeating: 0x51, count: 5))
        XCTAssertEqual(Array(addresses.suffix(5)), Array(repeating: 0, count: 5))
        XCTAssertEqual(
            outcome,
            .failure(
                .wrongCommand,
                dataAddress: 0,
                attempts: 10,
                onlyObservedIssueWasBadChecksum: false,
                checksumCompatibilityRejection: nil
            )
        )
    }

    func testRequestWriteFailureDoesNotProbeAlternateReadOffset() {
        var addresses: [UInt8] = []
        let outcome = NativeDDCReadStrategyRunner.run(
            primaryDataAddress: 0x51,
            alternateDataAddress: 0,
            attemptsPerStrategy: 5
        ) { address, _ in
            addresses.append(address)
            return .failure(.requestWriteFailed)
        }

        XCTAssertEqual(addresses, Array(repeating: 0x51, count: 5))
        XCTAssertEqual(
            outcome,
            .failure(
                .requestWriteFailed,
                dataAddress: 0x51,
                attempts: 5,
                onlyObservedIssueWasBadChecksum: false,
                checksumCompatibilityRejection: nil
            )
        )
    }

    func testReadOffsetPreferenceIsPerDisplayAndInvalidatedWithService() {
        var cache = NativeDDCReadPreferenceCache()
        cache.remember(address: 0, selector: "selector-a")

        XCTAssertEqual(cache.preferredAddress(selector: "SELECTOR-A", default: 0x51), 0)
        XCTAssertEqual(cache.preferredAddress(selector: "selector-b", default: 0x51), 0x51)

        cache.invalidate(selector: "selector-a")
        XCTAssertEqual(cache.preferredAddress(selector: "selector-a", default: 0x51), 0x51)
    }

    func testNativeDiagnosticsExposeOnlySanitizedTransportState() {
        let snapshot = NativeDDCDiagnosticSnapshot(
            transportPath: .builtinHDMIConverter,
            serviceMatched: true,
            operationCategory: .readResponseTimeout,
            rebuildCount: 1,
            replyIssue: .responseTimeout,
            chipAddress: 0x37,
            readDataAddress: 0,
            readAttemptCount: 5
        )

        XCTAssertEqual(
            snapshot.userFacingDescription,
            "builtin-hdmi-converter · service matched · read-response-timeout · chip 0x37 · offset 0 · attempts 5 · rebuild 1"
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
                chipAddress: 0x37,
                readDataAddress: 0x51,
                readAttemptCount: 5
            )
            XCTAssertTrue(snapshot.userFacingDescription.contains("read-reply-rejected/\(code)"))
            XCTAssertTrue(snapshot.userFacingDescription.contains("offset 0x51"))
            XCTAssertTrue(snapshot.userFacingDescription.contains("attempts 5"))
            XCTAssertTrue(snapshot.userFacingDescription.contains("chip 0x37"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("UUID"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("IOService"))
        }
    }

    func testChecksumCompatibilityRejectionsHaveSanitizedDiagnostics() {
        let cases: [(NativeDDCChecksumCompatibilityRejection, String)] = [
            (.insufficientReplies, "insufficient-replies"),
            (.inconsistentPayload(NativeDDCChecksumPayloadComparison(
                commandMatches: true, currentMatches: false, maximumMatches: true,
                payloadLengths: [8, 8]
            )), "inconsistent-payload/command-match=true/current-same=false/max-same=true/payload-length=8,8"),
            (.invalidField(.wrongCommand), "invalid-field/wrong-command"),
            (.invalidRange(current: 101, maximum: 100), "invalid-range/current=101/max=100"),
            (.transportError(.responseTimeout), "transport-error/response-timeout")
        ]

        for (rejection, expected) in cases {
            let snapshot = NativeDDCDiagnosticSnapshot(
                transportPath: .builtinHDMIConverter,
                serviceMatched: true,
                operationCategory: .readReplyRejected,
                rebuildCount: 1,
                replyIssue: .badChecksum,
                chipAddress: 0x37,
                readDataAddress: 0,
                readAttemptCount: 7,
                checksumCompatibilityRejection: rejection
            )
            XCTAssertTrue(snapshot.userFacingDescription.contains("compatibility \(expected)"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("IOService"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("UUID"))
            XCTAssertFalse(snapshot.userFacingDescription.contains("[0x"))
        }
    }

    func testChecksumCompatibilityRunnerClassifiesTransportFailure() {
        XCTAssertEqual(
            NativeDDCChecksumCompatibilityRunner.run(command: .luminance) { _ in
                .failure(.responseTimeout)
            },
            .rejected(
                .transportError(.responseTimeout),
                evidence: NativeDDCChecksumCompatibilityEvidence(replies: [])
            )
        )
    }

    func testCompatibilityEvidenceShowsBothRepliesAndPublicSemanticFieldsOnly() {
        var first = badChecksumReply(current: 42, maximum: 100)
        first[0] = 0x6F
        var second = badChecksumReply(current: 43, maximum: 100)
        second[0] = 0x02

        guard case .rejected(.invalidField(.wrongSource), let evidence) =
                NativeDDCChecksumCompatibilityValidator.reading(
                    from: [first, second], command: .luminance
                ) else {
            return XCTFail("Expected wrong-source evidence")
        }
        let description = evidence.diagnosticDescription

        XCTAssertTrue(description.contains(
            "reply1{source=0x6F(alternate-source),payload-length=0x88,opcode=0x02," +
                "result=0x00,command=0x10,current=42,max=100}"
        ))
        XCTAssertTrue(description.contains(
            "reply2{source=0x02(suspected-frame-shift/opcode-at-source),payload-length=0x88," +
                "opcode=0x02,result=0x00,command=0x10,current=43,max=100}"
        ))
        XCTAssertTrue(description.contains("semantic-fields-consistent=false"))
        XCTAssertFalse(description.contains("["))
        XCTAssertFalse(description.contains("UUID"))
        XCTAssertFalse(description.contains("IORegistry"))
        XCTAssertFalse(description.contains("selector"))

        let snapshot = NativeDDCDiagnosticSnapshot(
            transportPath: .builtinHDMIConverter,
            serviceMatched: true,
            operationCategory: .readReplyRejected,
            rebuildCount: 1,
            replyIssue: .badChecksum,
            chipAddress: 0x37,
            readDataAddress: 0,
            readAttemptCount: 7,
            checksumCompatibilityRejection: .invalidField(.wrongSource),
            checksumCompatibilityEvidence: evidence
        )
        XCTAssertTrue(snapshot.userFacingDescription.contains("reply1{source=0x6F"))
        XCTAssertTrue(snapshot.userFacingDescription.contains("reply2{source=0x02"))
        XCTAssertTrue(snapshot.userFacingDescription.contains("semantic-fields-consistent=false"))
    }

    func testCompatibilitySourceClassificationDistinguishesZeroAndOtherValues() {
        let cases: [(UInt8, String)] = [
            (0x6F, "source=0x6F(alternate-source)"),
            (0x02, "source=0x02(suspected-frame-shift/opcode-at-source)"),
            (0x00, "source=0x00(suspected-frame-shift/zero-at-source)"),
            (0x55, "source=0x55(unexpected-source)")
        ]

        for (source, expected) in cases {
            var reply = badChecksumReply(current: 42, maximum: 100)
            reply[0] = source
            XCTAssertTrue(
                NativeDDCReplySemanticFields(reply: reply).diagnosticDescription.contains(expected)
            )
        }
    }

    func testCancellationAndLateReadCannotCommitCacheOrResult() {
        let backend = MockDDCBackend()
        backend.readings = ["display-a": [.luminance: DDCReading(current: 88, maximum: 100)]]
        let cache = MockDDCCache(values: ["display-a": [.luminance: 22]])
        let service = makeService(backend: backend, cache: cache)
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
        let service = makeService(backend: backend, cache: MockDDCCache())

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
            let service = makeService(backend: backend, cache: MockDDCCache())
            service.setOperationsAllowed(false)
            XCTAssertTrue(service.read([target(id: "display-a")]).isEmpty)
            XCTAssertNotNil(service.write(command: .luminance, value: 50,
                                          targets: [target(id: "display-a")])["display-a"])
            XCTAssertEqual(backend.readCalls.count, 0)
            XCTAssertEqual(backend.writeCalls.count, 0)
        }
    }

    private func makeService(backend: DDCBackend, cache: MockDDCCache) -> DDCControlService {
        DDCControlService(router: DDCBackendRouter(backend: backend), cache: cache)
    }

    private func target(id: String, selector: String? = nil,
                        commands: Set<DDCCommand> = DDCCommand.userControls) -> DDCDisplayTarget {
        DDCDisplayTarget(stableID: id, selector: selector ?? "selector-\(id)",
                         enabledCommands: commands)
    }

    private func badChecksumReply(current: Int, maximum: Int) -> [UInt8] {
        var reply: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, DDCCommand.luminance.rawValue, 0x00,
            UInt8((maximum >> 8) & 0xFF), UInt8(maximum & 0xFF),
            UInt8((current >> 8) & 0xFF), UInt8(current & 0xFF), 0
        ]
        reply[10] = reply.dropLast().reduce(UInt8(0x50), ^) ^ 0xFF
        return reply
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
