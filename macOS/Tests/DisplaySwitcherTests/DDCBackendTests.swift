import XCTest

final class DDCBackendTests: XCTestCase {
    func testDiscoveryKeepsLastOperationWhenServiceBindingIsUnchanged() {
        var state = NativeDDCDiagnosticDiscoveryState()
        let binding = NativeDDCDiagnosticBinding(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            serviceIdentity: 101
        )
        let initial = state.replacementSnapshot(
            selector: "display-a", binding: binding, current: nil
        )
        XCTAssertEqual(initial?.operationCategory, .idle)

        let succeeded = NativeDDCDiagnosticSnapshot(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            operationCategory: .readSucceeded,
            rebuildCount: 2,
            chipAddress: 0x37,
            readDataAddress: 0x51,
            readAttemptCount: 1,
            requestChecksumMode: .legacy
        )

        XCTAssertNil(state.replacementSnapshot(
            selector: "DISPLAY-A", binding: binding, current: succeeded
        ))
    }

    func testDiscoveryResetsLastOperationWhenServiceIdentityChanges() {
        var state = NativeDDCDiagnosticDiscoveryState()
        let original = NativeDDCDiagnosticBinding(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            serviceIdentity: 101
        )
        _ = state.replacementSnapshot(selector: "display-a", binding: original, current: nil)
        let succeeded = NativeDDCDiagnosticSnapshot(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            operationCategory: .readSucceeded,
            rebuildCount: 2
        )
        let changed = NativeDDCDiagnosticBinding(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            serviceIdentity: 202
        )

        let replacement = state.replacementSnapshot(
            selector: "display-a", binding: changed, current: succeeded
        )

        XCTAssertEqual(replacement?.transportPath, .typeCDPAlt)
        XCTAssertEqual(replacement?.operationCategory, .idle)
        XCTAssertEqual(replacement?.rebuildCount, 2)
        XCTAssertNil(replacement?.chipAddress)
    }

    func testDiscoveryResetsLastOperationWhenTransportChanges() {
        var state = NativeDDCDiagnosticDiscoveryState()
        let original = NativeDDCDiagnosticBinding(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            serviceIdentity: 101
        )
        _ = state.replacementSnapshot(selector: "display-a", binding: original, current: nil)
        let succeeded = NativeDDCDiagnosticSnapshot(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            operationCategory: .readSucceeded,
            rebuildCount: 0
        )
        let changed = NativeDDCDiagnosticBinding(
            transportPath: .builtinHDMIConverter,
            serviceMatched: true,
            serviceIdentity: 101
        )

        let replacement = state.replacementSnapshot(
            selector: "display-a", binding: changed, current: succeeded
        )

        XCTAssertEqual(replacement?.transportPath, .builtinHDMIConverter)
        XCTAssertEqual(replacement?.operationCategory, .idle)
    }

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

    func testInputZeroIsRejectedBeforeBackendWhileControlZeroRemainsValid() {
        let backend = MockDDCBackend()
        let service = makeService(backend: backend, cache: MockDDCCache())
        let inputTarget = target(id: "display-a", commands: [.input, .luminance])

        let inputFailures = service.write(command: .input, value: 0, targets: [inputTarget])
        let controlFailures = service.write(command: .luminance, value: 0, targets: [inputTarget])

        XCTAssertNotNil(inputFailures["display-a"])
        XCTAssertTrue(controlFailures.isEmpty)
        XCTAssertEqual(backend.writeCalls.map { $0.1 }, [.luminance])
        XCTAssertEqual(backend.writeCalls.map { $0.2 }, [0])
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

    func testUnsupportedReliableReadPreservesLastTrustedCache() {
        let backend = MockDDCBackend()
        backend.readFailures = ["display-a": [.luminance]]
        let cache = MockDDCCache(values: ["display-a": [.luminance: 64]])
        let service = makeService(backend: backend, cache: cache)

        let result = service.read([target(id: "display-a", commands: [.luminance])])

        XCTAssertEqual(result["display-a"]?[.luminance]?.reading.current, 64)
        XCTAssertTrue(result["display-a"]?[.luminance]?.estimated == true)
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

    func testDS029DisplayCacheRemovalIsScopedToStableIDAndSelector() {
        let suite = "DisplaySwitcher.DDC.Delete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsDDCValueCache(defaults: defaults)
        cache.setValue(31, stableID: "display-a", command: .luminance)
        cache.setValue(47, stableID: "display-b", command: .luminance)

        let selectorA = DDCLocalCacheKeys.selectorLegacyValue(
            selector: "selector-a", command: .contrast
        )
        let selectorB = DDCLocalCacheKeys.selectorLegacyValue(
            selector: "selector-b", command: .contrast
        )
        let indexLegacy = "LastValue.display1.contrast"
        defaults.set(52, forKey: selectorA)
        defaults.set(63, forKey: selectorB)
        defaults.set(74, forKey: indexLegacy)

        cache.removeValues(stableID: "display-a")
        for key in DDCLocalCacheKeys.removableKeys(
            stableID: "display-a", selector: "selector-a"
        ).filter({ $0.hasPrefix("LastValue.device.") }) {
            defaults.removeObject(forKey: key)
        }

        XCTAssertNil(cache.value(stableID: "display-a", command: .luminance))
        XCTAssertEqual(cache.value(stableID: "display-b", command: .luminance), 47)
        XCTAssertNil(defaults.object(forKey: selectorA))
        XCTAssertEqual(defaults.integer(forKey: selectorB), 63)
        XCTAssertEqual(defaults.integer(forKey: indexLegacy), 74)
        XCTAssertFalse(DDCLocalCacheKeys.removableKeys(
            stableID: "display-a", selector: "selector-a"
        ).contains(indexLegacy))
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

    func testDS029PhysicalEnumerationTrustRequiresOneToOneCompleteTopology() {
        let trusted = DDCPhysicalEnumerationEvidence(
            cgEnumerationSucceeded: true,
            externalCGDisplayCount: 3,
            extractedIdentityCount: 3,
            registryEnumerationSucceeded: true,
            externalRegistryServiceCount: 3,
            matchedPhysicalTransportCount: 3
        )
        XCTAssertTrue(trusted.isCompletePhysicalSnapshot)

        let variants = [
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 3,
                extractedIdentityCount: 3,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 2,
                matchedPhysicalTransportCount: 2
            ),
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 3,
                extractedIdentityCount: 3,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 4,
                matchedPhysicalTransportCount: 3
            ),
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 3,
                extractedIdentityCount: 2,
                registryEnumerationSucceeded: true,
                externalRegistryServiceCount: 3,
                matchedPhysicalTransportCount: 2
            ),
            DDCPhysicalEnumerationEvidence(
                cgEnumerationSucceeded: true,
                externalCGDisplayCount: 3,
                extractedIdentityCount: 3,
                registryEnumerationSucceeded: false,
                externalRegistryServiceCount: 3,
                matchedPhysicalTransportCount: 3
            )
        ]
        XCTAssertTrue(variants.allSatisfy { !$0.isCompletePhysicalSnapshot })
    }

    func testNativeServiceMatchingRejectsTiedSameModelCandidates() {
        let identities = [
            NativeDisplayIdentity(
                stableID: "display-a", ioDisplayLocation: "",
                productName: "Same Model", serialNumber: 0,
                edidSearchKeys: [
                    NativeEDIDSearchKey(value: "AAAA", offset: 0),
                    NativeEDIDSearchKey(value: "BBBB", offset: 4)
                ]
            ),
            NativeDisplayIdentity(
                stableID: "display-b", ioDisplayLocation: "",
                productName: "Same Model", serialNumber: 0,
                edidSearchKeys: [
                    NativeEDIDSearchKey(value: "AAAA", offset: 0),
                    NativeEDIDSearchKey(value: "BBBB", offset: 4)
                ]
            )
        ]
        let candidates = [
            NativeTransportCandidate(
                serviceLocation: 1, ioDisplayLocation: "candidate-a",
                productName: "Same Model", serialNumber: 0, edidUUID: "AAAABBBB"
            ),
            NativeTransportCandidate(
                serviceLocation: 2, ioDisplayLocation: "candidate-b",
                productName: "Same Model", serialNumber: 0, edidUUID: "AAAABBBB"
            )
        ]

        XCTAssertTrue(
            NativeDisplayMatcher.matches(identities: identities, candidates: candidates).isEmpty
        )
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
        XCTAssertEqual(parameters.readSleepMicroseconds(for: .builtinHDMIConverter), 10_000)
        XCTAssertEqual(parameters.builtinHDMIReadRetrySleepMicroseconds, 5_000)
        XCTAssertEqual(parameters.readAttempts(for: .typeCDPAlt), 5)
        XCTAssertEqual(parameters.readAttempts(for: .builtinHDMIConverter), 8)
        XCTAssertEqual(parameters.writeCycles, 2)
        XCTAssertEqual(parameters.builtinHDMIReadRequestWriteCycles, 1)
        XCTAssertEqual(parameters.writeAttempts, 5)
    }

    func testNativeTransportPathClassificationIsDeterministicAndSanitized() {
        XCTAssertEqual(
            NativeDisplayEndpointToken.extractFramebuffer(
                from: ["synthetic/disp0@8000000/IOMobileFramebufferShim"]
            ),
            "disp0"
        )
        XCTAssertEqual(
            NativeDisplayEndpointToken.extractFramebuffer(
                from: ["synthetic/dispext1@88000000/IOMobileFramebufferShim"]
            ),
            "dispext1"
        )
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

    func testNativeServiceTopologyMatchesM4HDMIAndExternalEndpointsIndependentOfOrder() {
        let framebuffers = [
            NativeFramebufferTopologyNode(location: 1, endpointToken: "disp0"),
            NativeFramebufferTopologyNode(location: 2, endpointToken: "dispext0"),
            NativeFramebufferTopologyNode(location: 3, endpointToken: "dispext1")
        ]
        let services = [
            NativeServiceTopologyNode(location: 30, endpointToken: "dispext1"),
            NativeServiceTopologyNode(location: 10, endpointToken: "dispextE"),
            NativeServiceTopologyNode(location: 20, endpointToken: "dispext0")
        ]

        let expected = [1: 10, 2: 20, 3: 30]
        XCTAssertEqual(
            NativeServiceTopologyMatcher.matches(
                framebuffers: framebuffers, services: services
            ),
            expected
        )
        XCTAssertEqual(
            NativeServiceTopologyMatcher.matches(
                framebuffers: Array(framebuffers.reversed()),
                services: Array(services.reversed())
            ),
            expected
        )
    }

    func testNativeServiceTopologyRejectsAmbiguityAndUnknownEndpoints() {
        XCTAssertTrue(
            NativeServiceTopologyMatcher.matches(
                framebuffers: [
                    NativeFramebufferTopologyNode(location: 1, endpointToken: "dispext0"),
                    NativeFramebufferTopologyNode(location: 2, endpointToken: "dispext0"),
                    NativeFramebufferTopologyNode(location: 3, endpointToken: nil),
                    NativeFramebufferTopologyNode(location: 4, endpointToken: "disp1")
                ],
                services: [
                    NativeServiceTopologyNode(location: 10, endpointToken: "dispext0"),
                    NativeServiceTopologyNode(location: 11, endpointToken: nil)
                ]
            ).isEmpty
        )
        XCTAssertTrue(
            NativeServiceTopologyMatcher.matches(
                framebuffers: [
                    NativeFramebufferTopologyNode(location: 1, endpointToken: "disp0")
                ],
                services: [
                    NativeServiceTopologyNode(location: 10, endpointToken: "dispextE"),
                    NativeServiceTopologyNode(location: 11, endpointToken: "dispextE")
                ]
            ).isEmpty
        )
    }

    func testNativeServiceTopologyRebindsAfterInterfaceChangeWithoutHistoricalGuessing() {
        let services = [
            NativeServiceTopologyNode(location: 10, endpointToken: "dispextE"),
            NativeServiceTopologyNode(location: 20, endpointToken: "dispext2")
        ]
        XCTAssertEqual(
            NativeServiceTopologyMatcher.matches(
                framebuffers: [
                    NativeFramebufferTopologyNode(location: 1, endpointToken: "disp0")
                ],
                services: services
            ),
            [1: 10]
        )
        XCTAssertEqual(
            NativeServiceTopologyMatcher.matches(
                framebuffers: [
                    NativeFramebufferTopologyNode(location: 1, endpointToken: "dispext2")
                ],
                services: services
            ),
            [1: 20]
        )
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

    func testHDMIDiagnosticFallsBackFromOffsetZeroAndRequiresTwoStrictOffset51Replies() {
        var addresses: [UInt8] = []
        let valid = DDCReading(current: 42, maximum: 100)

        let result = NativeDDCHDMIReadDiagnosticRunner.run(
            primaryDataAddress: 0,
            alternateDataAddress: 0x51,
            attemptsPerStrategy: 5
        ) { address, attempt in
            addresses.append(address)
            return readAttempt(
                address: address,
                attempt: attempt,
                reply: address == 0 ? badChecksumReply(current: 42, maximum: 100)
                    : strictReply(current: 42, maximum: 100),
                validation: address == 0 ? .rejected(.badChecksum) : .valid(valid)
            )
        }

        XCTAssertEqual(addresses, [0, 0, 0, 0, 0, 0x51, 0x51])
        XCTAssertEqual(
            result.outcome,
            .success(valid, dataAddress: 0x51, attempts: 7)
        )
        XCTAssertEqual(result.attempts.count, 7)
        XCTAssertTrue(result.attempts.allSatisfy { $0.reply.count == 11 })
    }

    func testBuiltinHDMIFormalReadRetriesCompleteTransactionsWithoutAlternateProbe() {
        var addresses: [UInt8] = []
        var retryCount = 0
        var buffersWereFresh: [Bool] = []
        let outcome = NativeDDCBuiltinHDMIReadPolicy.run(
            readDataAddress: 0,
            attempts: 8,
            retry: { retryCount += 1 }
        ) { address, response in
            addresses.append(address)
            buffersWereFresh.append(response.allSatisfy { $0 == 0 })
            response = self.badChecksumReply(current: 42, maximum: 100)
            return .failure(.badChecksum)
        }

        XCTAssertEqual(addresses, Array(repeating: 0, count: 8))
        XCTAssertEqual(retryCount, 7)
        XCTAssertTrue(buffersWereFresh.allSatisfy { $0 })
        XCTAssertEqual(
            outcome,
            .failure(
                .badChecksum,
                dataAddress: 0,
                attempts: 8,
                onlyObservedIssueWasBadChecksum: true
            )
        )
    }

    func testBuiltinHDMIFormalReadAcceptsOnlyStrictValidReply() {
        let expected = DDCReading(current: 42, maximum: 100)
        var calls = 0
        var retryCount = 0
        let outcome = NativeDDCBuiltinHDMIReadPolicy.run(
            readDataAddress: 0,
            attempts: 8,
            retry: { retryCount += 1 }
        ) { _, response in
            calls += 1
            response = self.strictReply(current: 42, maximum: 100)
            return NativeDDCReplyValidator.reading(from: response, command: .luminance)
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(outcome, .success(expected, dataAddress: 0, attempts: 1))
    }

    func testReliableReadUnsupportedDiagnosticHidesTransportInternals() {
        let rejectedReply = badChecksumReply(current: 42, maximum: 100)
        let edidLikeAttempt = NativeDDCReadAttemptDiagnostic(
            dataAddress: 0,
            strategyAttempt: 1,
            delayMicroseconds: 50_000,
            writeIOReturns: [0],
            readIOReturn: 0,
            reply: rejectedReply,
            validation: .rejected(.badChecksum),
            edidReferences: [rejectedReply]
        )
        XCTAssertEqual(edidLikeAttempt.dataSource, .edidLike)
        let snapshot = NativeDDCDiagnosticSnapshot(
            transportPath: .builtinHDMIConverter,
            serviceMatched: true,
            operationCategory: .reliableReadUnsupported,
            rebuildCount: 2,
            replyIssue: .badChecksum,
            chipAddress: 0x37,
            readDataAddress: 0x51,
            readAttemptCount: 10,
            hdmiReadDiagnostics: [edidLikeAttempt]
        )

        XCTAssertEqual(snapshot.userFacingDescription, "当前连接不支持可靠读取")
        XCTAssertFalse(snapshot.userFacingDescription.contains("chip"))
        XCTAssertFalse(snapshot.userFacingDescription.contains("offset"))
        XCTAssertFalse(snapshot.userFacingDescription.contains("attempt"))
    }

    func testReliableReadUnsupportedSkipsRecoveryRetry() {
        var operationCount = 0
        var recoveryCount = 0

        XCTAssertThrowsError(try DDCSingleRetry.perform(operation: {
            operationCount += 1
            throw DDCBackendError.reliableReadUnsupported(command: .luminance)
        }, recover: {
            recoveryCount += 1
        }, shouldRetry: { error in
            if case DDCBackendError.reliableReadUnsupported = error { return false }
            return true
        }))
        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(recoveryCount, 0)
    }

    func testHDMIDiagnosticRequestWriteFailureNeverProbesOffset51() {
        var addresses: [UInt8] = []
        let result = NativeDDCHDMIReadDiagnosticRunner.run(
            primaryDataAddress: 0,
            alternateDataAddress: 0x51,
            attemptsPerStrategy: 5
        ) { address, attempt in
            addresses.append(address)
            return readAttempt(
                address: address,
                attempt: attempt,
                reply: [UInt8](repeating: 0, count: 11),
                validation: .rejected(.requestWriteFailed),
                readIOReturn: nil
            )
        }

        XCTAssertEqual(addresses, Array(repeating: 0, count: 5))
        XCTAssertEqual(
            result.outcome,
            .failure(
                .requestWriteFailed,
                dataAddress: 0,
                attempts: 5,
                onlyObservedIssueWasBadChecksum: false
            )
        )
    }

    func testConfirmedHDMIOffset51StillRequiresTwoStrictReplies() {
        var calls = 0
        let valid = DDCReading(current: 42, maximum: 100)
        let result = NativeDDCHDMIReadDiagnosticRunner.run(
            primaryDataAddress: 0x51,
            alternateDataAddress: nil,
            attemptsPerStrategy: 5
        ) { address, attempt in
            calls += 1
            return readAttempt(
                address: address,
                attempt: attempt,
                reply: strictReply(current: 42, maximum: 100),
                validation: .valid(valid)
            )
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.outcome, .success(valid, dataAddress: 0x51, attempts: 2))
    }

    func testHDMIDiagnosticStrictlyRejectsShiftedBadChecksumNullAndInconsistentReplies() {
        var shifted = strictReply(current: 42, maximum: 100)
        shifted[0] = 0
        shifted[10] = shifted.dropLast().reduce(UInt8(0x50), ^)
        let badChecksum = badChecksumReply(current: 42, maximum: 100)
        let nullReply: [UInt8] = [0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: shifted, command: .luminance),
            .failure(.wrongSource)
        )
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: badChecksum, command: .luminance),
            .failure(.badChecksum)
        )
        XCTAssertEqual(
            NativeDDCReplyValidator.reading(from: nullReply, command: .luminance),
            .failure(.nullReply)
        )

        for (reply, issue) in [
            (shifted, NativeDDCReplyIssue.wrongSource),
            (badChecksum, .badChecksum),
            (nullReply, .nullReply)
        ] {
            let rejection = NativeDDCHDMIReadDiagnosticRunner.run(
                primaryDataAddress: 0,
                alternateDataAddress: 0x51,
                attemptsPerStrategy: 1
            ) { address, attempt in
                readAttempt(
                    address: address, attempt: attempt, reply: reply,
                    validation: .rejected(issue)
                )
            }
            guard case .failure = rejection.outcome else {
                return XCTFail("Strictly rejected reply must never become a reading")
            }
        }

        var alternateValues = [
            DDCReading(current: 41, maximum: 100),
            DDCReading(current: 42, maximum: 100)
        ]
        let result = NativeDDCHDMIReadDiagnosticRunner.run(
            primaryDataAddress: 0,
            alternateDataAddress: 0x51,
            attemptsPerStrategy: 2
        ) { address, attempt in
            if address == 0 {
                return readAttempt(
                    address: address, attempt: attempt, reply: nullReply,
                    validation: .rejected(.wrongSource)
                )
            }
            let reading = alternateValues.removeFirst()
            return readAttempt(
                address: address, attempt: attempt,
                reply: strictReply(current: reading.current, maximum: reading.maximum),
                validation: .valid(reading)
            )
        }
        XCTAssertEqual(
            result.outcome,
            .failure(
                .inconsistentStrictReplies,
                dataAddress: 0x51,
                attempts: 4,
                onlyObservedIssueWasBadChecksum: false
            )
        )
    }

    func testHDMIDiagnosticAttemptProjectionContainsOnlyPublicTransactionFields() {
        let attempt = readAttempt(
            address: 0x51,
            attempt: 2,
            reply: strictReply(current: 42, maximum: 100),
            validation: .valid(DDCReading(current: 42, maximum: 100))
        )
        let description = attempt.diagnosticDescription

        XCTAssertTrue(description.contains("offset 0x51 attempt 2 delay-us 50000"))
        XCTAssertTrue(description.contains("write-ior=[0x00000000,0x00000000]"))
        XCTAssertTrue(description.contains("read-ior=0x00000000"))
        XCTAssertTrue(description.contains("reply-length=11 source=ddcci/strict-valid"))
        XCTAssertTrue(description.contains("strict-valid"))
        XCTAssertFalse(description.contains("6E 88 02 00 10"))
        XCTAssertFalse(description.contains("UUID"))
        XCTAssertFalse(description.contains("IORegistry"))
        XCTAssertFalse(description.contains("selector"))
    }

    func testI2CBufferBridgeProvidesContiguousInputAndMutableOutputBytes() {
        let input: [UInt8] = [0x84, 0x03, 0x60, 0x00, 0x11, 0xC9]
        var capturedInput: [UInt8] = []
        let inputLength = NativeDDCI2CBufferBridge.withInputBytes(input) { buffer -> Int in
            capturedInput = Array(buffer.bindMemory(to: UInt8.self))
            return buffer.count
        }
        XCTAssertEqual(inputLength, input.count)
        XCTAssertEqual(capturedInput, input)

        var output = [UInt8](repeating: 0, count: 11)
        let outputLength = NativeDDCI2CBufferBridge.withOutputBytes(&output) { buffer -> Int in
            let bytes = buffer.bindMemory(to: UInt8.self)
            bytes[0] = 0x6E
            bytes[10] = 0xA5
            return buffer.count
        }
        XCTAssertEqual(outputLength, 11)
        XCTAssertEqual(output[0], 0x6E)
        XCTAssertEqual(output[10], 0xA5)
    }

    func testRejectedReplyMatchingEDIDWindowIsClassifiedWithoutExposingBytes() {
        let reference = Array("SIMULATED PANEL".utf8)
        let reply: [UInt8] = [0x00, 0xFF, 0x50, 0x41, 0x4E, 0x45, 0x4C, 0x20, 0x00, 0x00, 0x00]
        let attempt = NativeDDCReadAttemptDiagnostic(
            dataAddress: 0,
            strategyAttempt: 1,
            delayMicroseconds: 50_000,
            writeIOReturns: [0, 0],
            readIOReturn: 0,
            reply: reply,
            validation: .rejected(.badChecksum),
            edidReferences: [reference]
        )

        XCTAssertEqual(attempt.dataSource, .edidLike)
        XCTAssertEqual(attempt.reply, reply)
        XCTAssertTrue(attempt.diagnosticDescription.contains("source=non-ddcci/edid-like"))
        XCTAssertFalse(attempt.diagnosticDescription.contains("PANEL"))
        XCTAssertFalse(attempt.diagnosticDescription.contains("50 41 4E 45 4C"))
    }

    func testReplySourceClassificationKeepsStrictAndUnmatchedDataSeparate() {
        let reference = [UInt8]("SIMULATED PANEL".utf8)
        let validReply = strictReply(current: 42, maximum: 100)
        XCTAssertEqual(
            NativeDDCReplySourceClassifier.classify(
                reply: validReply,
                validation: .valid(DDCReading(current: 42, maximum: 100)),
                edidReferences: [validReply]
            ),
            .strictDDCCI
        )
        XCTAssertEqual(
            NativeDDCReplySourceClassifier.classify(
                reply: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60],
                validation: .rejected(.badChecksum),
                edidReferences: [reference]
            ),
            .unclassified
        )
    }

    func testReadOffsetPreferenceIsPerDisplayAndInvalidatedWithService() {
        var cache = NativeDDCReadPreferenceCache()
        let current = NativeDDCReadPreferenceKey(
            selector: "selector-a", serviceIdentity: 101,
            transportPath: .builtinHDMIConverter
        )
        let replacementService = NativeDDCReadPreferenceKey(
            selector: "selector-a", serviceIdentity: 202,
            transportPath: .builtinHDMIConverter
        )
        let replacementTransport = NativeDDCReadPreferenceKey(
            selector: "selector-a", serviceIdentity: 101,
            transportPath: .typeCDPAlt
        )
        let preference = NativeDDCReadPreference(
            dataAddress: 0x51,
            checksumMode: .standard
        )
        let fallback = NativeDDCReadPreference(
            dataAddress: 0,
            checksumMode: .legacy
        )
        cache.remember(preference, for: current)

        XCTAssertEqual(cache.preferred(for: current, default: fallback), preference)
        XCTAssertEqual(cache.preferred(for: replacementService, default: fallback), fallback)
        XCTAssertEqual(cache.preferred(for: replacementTransport, default: fallback), fallback)

        cache.retainOnly([replacementService])
        XCTAssertEqual(cache.preferred(for: current, default: fallback), fallback)

        cache.invalidate(selector: "selector-a")
        XCTAssertEqual(cache.preferred(for: replacementService, default: fallback), fallback)
    }

    func testTypeCChecksumStrategyFallsBackToStandardAndRemembersWinningAddress() {
        var requests: [(NativeDDCRequestChecksumMode, UInt8)] = []
        let expected = DDCReading(current: 47, maximum: 100)

        let result = NativeDDCChecksumStrategyRunner.run(
            preferredMode: .legacy,
            primaryDataAddress: 0x51,
            defaultDataAddress: 0x51,
            attemptsPerAddress: 2
        ) { mode, address, _ in
            requests.append((mode, address))
            if mode == .standard && address == 0 {
                return .success(expected)
            }
            return .failure(.badChecksum)
        }

        XCTAssertEqual(requests.map(\.0), [
            .legacy, .legacy, .legacy, .legacy, .standard
        ])
        XCTAssertEqual(requests.map(\.1), [0x51, 0x51, 0, 0, 0])
        XCTAssertEqual(result.checksumMode, .standard)
        XCTAssertEqual(
            result.outcome,
            .success(expected, dataAddress: 0, attempts: 5)
        )
    }

    func testPreferredStandardChecksumStopsBeforeLegacyFallback() {
        var modes: [NativeDDCRequestChecksumMode] = []
        let expected = DDCReading(current: 64, maximum: 100)

        let result = NativeDDCChecksumStrategyRunner.run(
            preferredMode: .standard,
            primaryDataAddress: 0,
            defaultDataAddress: 0x51,
            attemptsPerAddress: 2
        ) { mode, address, _ in
            modes.append(mode)
            return address == 0 ? .success(expected) : .failure(.badChecksum)
        }

        XCTAssertEqual(modes, [.standard])
        XCTAssertEqual(result.checksumMode, .standard)
        XCTAssertEqual(result.outcome, .success(expected, dataAddress: 0, attempts: 1))
    }

    func testChecksumFallbackStopsWhenRequestWriteIsRejected() {
        var modes: [NativeDDCRequestChecksumMode] = []
        let result = NativeDDCChecksumStrategyRunner.run(
            preferredMode: .legacy,
            primaryDataAddress: 0x51,
            defaultDataAddress: 0x51,
            attemptsPerAddress: 2
        ) { mode, _, _ in
            modes.append(mode)
            return .failure(.requestWriteFailed)
        }

        XCTAssertEqual(modes, [.legacy, .legacy])
        XCTAssertEqual(result.checksumMode, .legacy)
        XCTAssertEqual(
            result.outcome,
            .failure(
                .requestWriteFailed,
                dataAddress: 0x51,
                attempts: 2,
                onlyObservedIssueWasBadChecksum: false
            )
        )
    }

    func testChecksumFallbackIsLimitedToTypeCStrategyCallers() {
        var requests: [(NativeDDCRequestChecksumMode, UInt8)] = []
        let result = NativeDDCChecksumStrategyRunner.run(
            preferredMode: .standard,
            primaryDataAddress: 0,
            defaultDataAddress: 0x51,
            attemptsPerAddress: 2,
            allowsFallback: false
        ) { mode, address, _ in
            requests.append((mode, address))
            return .failure(.badChecksum)
        }

        XCTAssertEqual(requests.map(\.0), [.standard, .standard])
        XCTAssertEqual(requests.map(\.1), [0, 0])
        XCTAssertEqual(result.checksumMode, .standard)
        XCTAssertEqual(
            result.outcome,
            .failure(
                .badChecksum,
                dataAddress: 0,
                attempts: 2,
                onlyObservedIssueWasBadChecksum: true
            )
        )
    }

    func testNativeGetVCPPacketsKeepTransportSpecificChecksumBehavior() {
        XCTAssertEqual(
            NativeDDCRequestPacketBuilder.packet(
                request: [DDCCommand.luminance.rawValue],
                chipAddress: 0x37,
                dataAddress: 0x51,
                includesDataAddressInChecksum: true
            ),
            [0x82, 0x01, 0x10, 0xAC]
        )
        XCTAssertEqual(
            NativeDDCRequestPacketBuilder.packet(
                request: [DDCCommand.luminance.rawValue],
                chipAddress: 0x37,
                dataAddress: 0x51,
                includesDataAddressInChecksum: false
            ),
            [0x82, 0x01, 0x10, 0xFD]
        )
    }

    func testNativeSetVCPPacketStillIncludesDataAddressInChecksum() {
        XCTAssertEqual(
            NativeDDCRequestPacketBuilder.packet(
                request: [DDCCommand.luminance.rawValue, 0x00, 0x64],
                chipAddress: 0x37,
                dataAddress: 0x51,
                includesDataAddressInChecksum: true
            ),
            [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC]
        )
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
            readAttemptCount: 5,
            requestChecksumMode: .standard
        )

        XCTAssertEqual(
            snapshot.userFacingDescription,
            "builtin-hdmi-converter · service matched · read-response-timeout · chip 0x37 · offset 0 · attempts 5 · checksum standard · rebuild 1"
        )
        XCTAssertFalse(snapshot.userFacingDescription.contains("IOService"))
        XCTAssertFalse(snapshot.userFacingDescription.contains("/"))
    }

    func testEveryRejectedReplyReasonHasSanitizedDiagnosticProjection() {
        let issues: [(NativeDDCReplyIssue, String)] = [
            (.nullReply, "null-reply"),
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

        XCTAssertEqual(
            try service.enumerateDisplays().displays.map(\.stableID),
            ["display-b", "display-a"]
        )
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

    private func strictReply(current: Int, maximum: Int) -> [UInt8] {
        var reply = badChecksumReply(current: current, maximum: maximum)
        reply[10] = reply.dropLast().reduce(UInt8(0x50), ^)
        return reply
    }

    private func readAttempt(
        address: UInt8,
        attempt: Int,
        reply: [UInt8],
        validation: NativeDDCStrictReadValidation,
        readIOReturn: Int32? = 0
    ) -> NativeDDCReadAttemptDiagnostic {
        NativeDDCReadAttemptDiagnostic(
            dataAddress: address,
            strategyAttempt: attempt,
            delayMicroseconds: 50_000,
            writeIOReturns: [0, 0],
            readIOReturn: readIOReturn,
            reply: reply,
            validation: validation
        )
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

    func removeValues(stableID: String) {
        values.removeValue(forKey: stableID)
    }
}

private final class MockDDCBackend: DDCBackend {
    let identifier: String
    var availabilityValue: DDCBackendAvailability = .available
    var availability: DDCBackendAvailability { availabilityValue }
    let capabilities = DDCBackendCapabilities(canEnumerate: true, canReadVCP: true, canWriteVCP: true)
    var displays: [DDCBackendDisplay] = []
    var physicalEvidence: DDCPhysicalEnumerationEvidence = .untrusted
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

    func enumerateDisplays(token: DDCCancellationToken) throws -> DDCBackendEnumeration {
        try token.throwIfCancelled()
        enumerateCount += 1
        return DDCBackendEnumeration(displays: displays, physicalEvidence: physicalEvidence)
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
