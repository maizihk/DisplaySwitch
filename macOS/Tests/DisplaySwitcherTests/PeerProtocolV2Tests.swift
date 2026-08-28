import Foundation
import XCTest

final class PeerProtocolV2Tests: XCTestCase {
    func testPublicAuthenticationAndNormalizationVectors() throws {
        let object = try jsonObject(at: v2FixtureURL("auth-vectors.json"))
        let syntheticSecret = try XCTUnwrap(Data(hex: try string(object, "syntheticInputSecretHex")))

        let normalizationVectors = try array(object, "normalizationVectors")
        XCTAssertEqual(normalizationVectors.count, 1)
        for vector in normalizationVectors {
            let vectorID = try string(vector, "id")
            let input = try XCTUnwrap(Data(hex: try string(vector, "inputUtf8Hex")))
            let text = try XCTUnwrap(String(data: input, encoding: .utf8))
            XCTAssertEqual(
                try V2Crypto.normalizedPairingCodeData(text).hexString,
                try string(vector, "expectedNfcUtf8Hex"),
                vectorID
            )
        }

        let vectors = try array(object, "vectors")
        XCTAssertEqual(vectors.count, 4)
        for vector in vectors {
            let endpointID = try string(vector, "sourceEndpointID")
            let key = try V2Crypto.deriveKey(inputSecret: syntheticSecret, sourceEndpointID: endpointID)
            XCTAssertEqual(V2Crypto.base64URLEncode(key), try string(vector, "expectedDerivedKeyBase64Url"))
            guard let rawMessage = vector["messageWithoutAuthTag"] as? [String: Any] else { continue }
            var message = try v2Message(rawMessage, authTag: "")
            XCTAssertEqual(message.canonicalAuthenticationData().hexString, try string(vector, "expectedCanonicalUtf8Hex"))
            let tag = V2Crypto.authenticationTag(for: message, key: key)
            XCTAssertEqual(tag, try string(vector, "expectedAuthTag"))
            message.authTag = tag
            XCTAssertTrue(V2Crypto.authenticate(message, key: key))
        }
    }

    func testAllTwentyPublicMessageValidationVectors() throws {
        let object = try jsonObject(at: v2FixtureURL("message-validation-vectors.json"))
        let referenceTime = try integer(object, "referenceTime")
        let localEndpoint = try string(object, "localEndpointID")
        let knownSource = try string(object, "knownSourceEndpointID")
        let key = try XCTUnwrap(V2Crypto.base64URLDecode(try string(object, "authKeyBase64Url")))
        let vectors = try array(object, "vectors")
        XCTAssertEqual(vectors.count, 20)

        for vector in vectors {
            let vectorID = try string(vector, "id")
            let input = try dictionary(vector, "input")
            let encoding = try string(input, "encoding")
            let data: Data
            if encoding == "jsonObject" {
                data = try JSONSerialization.data(withJSONObject: try dictionary(input, "value"), options: [.sortedKeys])
            } else {
                data = Data(try string(input, "value").utf8)
            }
            let validation = V2MessageValidator.validate(
                data: data,
                context: V2MessageValidationContext(
                    now: referenceTime,
                    localEndpointID: localEndpoint,
                    knownSourceEndpointID: knownSource,
                    authenticationKey: key
                )
            )
            let expected = try dictionary(vector, "expected")
            XCTAssertEqual(validation.accepted, try boolean(expected, "accepted"), vectorID)
            XCTAssertEqual(validation.reason.rawValue, try string(expected, "reason"), vectorID)
            XCTAssertEqual(validation.refreshPeer, try boolean(expected, "refreshPeer"), vectorID)
            XCTAssertEqual(validation.replyTypes.map(\.rawValue), try strings(expected, "replyTypes"), vectorID)
            let hardware = try dictionary(expected, "hardwareCalls")
            XCTAssertTrue(hardware.values.allSatisfy { ($0 as? NSNumber)?.intValue == 0 })
        }
    }

    func testNonceReplayCacheDistinguishesDuplicateFromNonceReuse() throws {
        let source = "11111111-1111-4111-8111-111111111111"
        let target = "22222222-2222-4222-8222-222222222222"
        let key = try V2Crypto.deriveKey(pairingCode: "sample-code", sourceEndpointID: source)
        var first = V2Message(
            type: .statusResponse,
            eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
            sourceEndpointID: source,
            targetEndpointID: target,
            sourcePlatform: .macos,
            timestamp: 1_788_000_000,
            nonce: "AAECAwQFBgcICQoLDA0ODw"
        )
        first.authTag = V2Crypto.authenticationTag(for: first, key: key)
        var changed = V2Message(
            type: .statusResponse,
            eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2",
            sourceEndpointID: source,
            targetEndpointID: target,
            sourcePlatform: .macos,
            timestamp: 1_788_000_000,
            nonce: first.nonce
        )
        changed.authTag = V2Crypto.authenticationTag(for: changed, key: key)

        var cache = V2NonceReplayCache()
        XCTAssertEqual(cache.classify(first, nowMs: 0), .new)
        XCTAssertEqual(cache.classify(first, nowMs: 1), .duplicate)
        XCTAssertEqual(cache.classify(changed, nowMs: 2), .nonceReuse)
    }

    func testVersionDispatcherOnlyAdmitsIntegerV2() throws {
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":1}"#.utf8)), .unsupported(1))
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":2}"#.utf8)), .v2)
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":9}"#.utf8)), .unsupported(9))
        XCTAssertNil(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":"2"}"#.utf8)))
    }

    func testEndpointRoutingRejectsDuplicatesAndUsesStableLogicalIDs() throws {
        let display = DisplayConfigurationV4Display(
            id: "display-a", name: "Display A", selector: "1", localInput: 15,
            readEnabled: true, brightnessEnabled: true, contrastEnabled: true, volumeEnabled: true
        )
        func profile(_ id: String, endpoint: String) -> CollaborationProfile {
            CollaborationProfile(
                id: id, name: id, peerHost: "peer.example", peerPort: 49_731,
                pairingCode: "sample-code", peerEndpointID: endpoint, peerProtocolVersion: 2,
                coordinationEnabled: true,
                displayInputs: [DisplayInputMapping(displayID: "display-a", peerInput: 18)],
                triggerDevices: []
            )
        }
        let endpoint = "22222222-2222-4222-8222-222222222222"
        let duplicate = DisplayConfigurationStoreV4Document(
            schemaVersion: 4,
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            localDeviceName: "Local", listenPort: 49_731,
            controlChannel: .automatic, linkAllDisplays: false, displays: [display],
            collaborationProfiles: [profile("A", endpoint: endpoint), profile("B", endpoint: endpoint.uppercased())]
        )
        let rejected = V2EndpointRoutingTable.build(from: duplicate)
        XCTAssertTrue(rejected.routesByEndpointID.isEmpty)
        XCTAssertEqual(rejected.rejectedProfileIDs, ["A", "B"])

        var distinct = duplicate
        distinct.collaborationProfiles[1].peerEndpointID = "33333333-3333-4333-8333-333333333333"
        let routes = V2EndpointRoutingTable.build(from: distinct)
        XCTAssertEqual(routes.route(for: endpoint)?.profileID, "A")
        XCTAssertEqual(routes.route(for: "33333333-3333-4333-8333-333333333333")?.profileID, "B")
    }

    func testInputPresentCarriesNoDeviceTypeOrIdentifier() throws {
        let message = V2Message(
            type: .inputPresent,
            eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sourceEndpointID: "11111111-1111-4111-8111-111111111111",
            targetEndpointID: "22222222-2222-4222-8222-222222222222",
            sourcePlatform: .macos,
            timestamp: 1_788_000_000,
            nonce: "AAECAwQFBgcICQoLDA0ODw",
            authTag: String(repeating: "A", count: 43)
        )
        let dictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        XCTAssertNil(dictionary["deviceType"])
        XCTAssertNil(dictionary["deviceID"])
        XCTAssertNil(dictionary["deviceName"])
        XCTAssertNil(dictionary["localReference"])
        XCTAssertEqual(Set(dictionary.keys), [
            "version", "type", "eventID", "sourceEndpointID", "targetEndpointID",
            "sourcePlatform", "timestamp", "nonce", "authTag"
        ])
    }

    func testUnboundEndpointsCompleteFirstStatusProbeWithoutSavingIdentityOrHardwareEffects() throws {
        let localEndpoint = "11111111-1111-4111-8111-111111111111"
        let peerEndpoint = "22222222-2222-4222-8222-222222222222"
        let eventID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let now: Int64 = 1_788_000_000
        let pairingCode = "sample-code"
        let document = unboundDocument(localEndpointID: localEndpoint, pairingCodes: [pairingCode])
        let originalDocument = document
        let request = try signedStatusProbe(
            eventID: eventID,
            sourceEndpointID: peerEndpoint,
            targetEndpointID: nil,
            pairingCode: pairingCode,
            timestamp: now
        )

        let resolution = try XCTUnwrap(V2UnboundStatusProbeResolver.resolve(
            data: request,
            document: document,
            routingTable: V2EndpointRoutingTable.build(from: document),
            now: now,
            responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))
        let response = try JSONDecoder().decode(V2Message.self, from: resolution.responseData)
        let responseKey = try V2Crypto.deriveKey(pairingCode: pairingCode, sourceEndpointID: localEndpoint)

        XCTAssertEqual(response.type, .statusResponse)
        XCTAssertEqual(response.eventID, eventID)
        XCTAssertEqual(response.sourceEndpointID, localEndpoint)
        XCTAssertEqual(response.targetEndpointID, peerEndpoint)
        XCTAssertTrue(V2Crypto.authenticate(response, key: responseKey))
        XCTAssertNil(document.collaborationProfiles[0].peerEndpointID)
        XCTAssertNil(document.collaborationProfiles[0].peerProtocolVersion)
        XCTAssertEqual(document, originalDocument)

        let peerDocument = unboundDocument(localEndpointID: peerEndpoint, pairingCodes: [pairingCode])
        let reverseRequest = try signedStatusProbe(
            eventID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            sourceEndpointID: localEndpoint,
            targetEndpointID: nil,
            pairingCode: pairingCode,
            timestamp: now
        )
        let reverseResolution = try XCTUnwrap(V2UnboundStatusProbeResolver.resolve(
            data: reverseRequest,
            document: peerDocument,
            routingTable: V2EndpointRoutingTable.build(from: peerDocument),
            now: now,
            responseNonce: "ICEiIyQlJicoKSorLC0uLw"
        ))
        let reverseResponse = try JSONDecoder().decode(V2Message.self, from: reverseResolution.responseData)
        XCTAssertEqual(reverseResponse.eventID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertEqual(reverseResponse.targetEndpointID, localEndpoint)
        XCTAssertNil(peerDocument.collaborationProfiles[0].peerEndpointID)

        let hardwareCalls = (usb: 0, bluetooth: 0, wake: 0, ddc: 0)
        _ = resolution.responseData
        XCTAssertEqual(hardwareCalls.usb, 0)
        XCTAssertEqual(hardwareCalls.bluetooth, 0)
        XCTAssertEqual(hardwareCalls.wake, 0)
        XCTAssertEqual(hardwareCalls.ddc, 0)
    }

    func testUnboundStatusProbeRequiresExactlyOneAuthenticatedCandidate() throws {
        let localEndpoint = "11111111-1111-4111-8111-111111111111"
        let peerEndpoint = "22222222-2222-4222-8222-222222222222"
        let eventID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let now: Int64 = 1_788_000_000
        let pairingCode = "sample-code"
        let request = try signedStatusProbe(
            eventID: eventID,
            sourceEndpointID: peerEndpoint,
            targetEndpointID: nil,
            pairingCode: pairingCode,
            timestamp: now
        )

        let unique = unboundDocument(localEndpointID: localEndpoint, pairingCodes: [pairingCode, "different-code"])
        XCTAssertNotNil(V2UnboundStatusProbeResolver.resolve(
            data: request, document: unique, routingTable: V2EndpointRoutingTable.build(from: unique),
            now: now, responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))

        let ambiguous = unboundDocument(localEndpointID: localEndpoint, pairingCodes: [pairingCode, pairingCode])
        XCTAssertNil(V2UnboundStatusProbeResolver.resolve(
            data: request, document: ambiguous, routingTable: V2EndpointRoutingTable.build(from: ambiguous),
            now: now, responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))

        let wrongPairing = unboundDocument(localEndpointID: localEndpoint, pairingCodes: ["different-code"])
        XCTAssertNil(V2UnboundStatusProbeResolver.resolve(
            data: request, document: wrongPairing, routingTable: V2EndpointRoutingTable.build(from: wrongPairing),
            now: now, responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))
    }

    func testUnboundStatusProbeRejectsWrongTargetAndEndpointConflict() throws {
        let localEndpoint = "11111111-1111-4111-8111-111111111111"
        let peerEndpoint = "22222222-2222-4222-8222-222222222222"
        let now: Int64 = 1_788_000_000
        let pairingCode = "sample-code"
        let document = unboundDocument(localEndpointID: localEndpoint, pairingCodes: [pairingCode])
        let wrongTarget = try signedStatusProbe(
            eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sourceEndpointID: peerEndpoint,
            targetEndpointID: "33333333-3333-4333-8333-333333333333",
            pairingCode: pairingCode,
            timestamp: now
        )
        XCTAssertNil(V2UnboundStatusProbeResolver.resolve(
            data: wrongTarget, document: document, routingTable: V2EndpointRoutingTable.build(from: document),
            now: now, responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))

        var conflict = document
        conflict.collaborationProfiles.append(CollaborationProfile(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Bound but disabled",
            peerHost: "peer.example", peerPort: 49_731, pairingCode: "another-code",
            peerEndpointID: peerEndpoint, peerProtocolVersion: 2, coordinationEnabled: false,
            displayInputs: conflict.collaborationProfiles[0].displayInputs, triggerDevices: []
        ))
        let valid = try signedStatusProbe(
            eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sourceEndpointID: peerEndpoint,
            targetEndpointID: nil,
            pairingCode: pairingCode,
            timestamp: now
        )
        XCTAssertNil(V2UnboundStatusProbeResolver.resolve(
            data: valid, document: conflict, routingTable: V2EndpointRoutingTable.build(from: conflict),
            now: now, responseNonce: "EBESExQVFhcYGRobHB0eHw"
        ))
    }
}

private func unboundDocument(localEndpointID: String, pairingCodes: [String]) -> DisplayConfigurationStoreV4Document {
    let displayID = "44444444-4444-4444-8444-444444444444"
    let display = DisplayConfigurationV4Display(
        id: displayID, name: "Display", selector: "display-selector", localInput: 15,
        readEnabled: true, brightnessEnabled: true, contrastEnabled: true, volumeEnabled: true
    )
    let profiles = pairingCodes.enumerated().map { index, pairingCode in
        CollaborationProfile(
            id: String(format: "55555555-5555-4555-8555-%012d", index + 1),
            name: "Profile \(index + 1)", peerHost: "peer.example", peerPort: 49_731,
            pairingCode: pairingCode, peerEndpointID: nil, peerProtocolVersion: nil,
            coordinationEnabled: false,
            displayInputs: [DisplayInputMapping(displayID: displayID, peerInput: 18)],
            triggerDevices: []
        )
    }
    return DisplayConfigurationStoreV4Document(
        schemaVersion: 4, localEndpointID: localEndpointID, localDeviceName: "Local",
        listenPort: 49_731, controlChannel: .automatic, linkAllDisplays: false,
        displays: [display], collaborationProfiles: profiles
    )
}

private func signedStatusProbe(
    eventID: String,
    sourceEndpointID: String,
    targetEndpointID: String?,
    pairingCode: String,
    timestamp: Int64
) throws -> Data {
    var message = V2Message(
        type: .statusProbe, eventID: eventID, sourceEndpointID: sourceEndpointID,
        targetEndpointID: targetEndpointID, sourcePlatform: .windows, timestamp: timestamp,
        nonce: "AAECAwQFBgcICQoLDA0ODw"
    )
    let key = try V2Crypto.deriveKey(pairingCode: pairingCode, sourceEndpointID: sourceEndpointID)
    message.authTag = V2Crypto.authenticationTag(for: message, key: key)
    return try JSONEncoder().encode(message)
}

private func v2FixtureURL(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle(for: PeerProtocolV2Tests.self).resourceURL)
        .appendingPathComponent("contracts/protocol-v2")
        .appendingPathComponent(name)
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    try XCTUnwrap(object[key] as? [String: Any])
}

private func array(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
    try XCTUnwrap(object[key] as? [[String: Any]])
}

private func string(_ object: [String: Any], _ key: String) throws -> String {
    try XCTUnwrap(object[key] as? String)
}

private func strings(_ object: [String: Any], _ key: String) throws -> [String] {
    try XCTUnwrap(object[key] as? [String])
}

private func integer(_ object: [String: Any], _ key: String) throws -> Int64 {
    try XCTUnwrap(object[key] as? NSNumber).int64Value
}

private func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
    try XCTUnwrap(object[key] as? NSNumber).boolValue
}

private func v2Message(_ object: [String: Any], authTag: String) throws -> V2Message {
    V2Message(
        type: try XCTUnwrap(V2MessageType(rawValue: try string(object, "type"))),
        eventID: try string(object, "eventID"),
        sourceEndpointID: try string(object, "sourceEndpointID"),
        targetEndpointID: object["targetEndpointID"] as? String,
        sourcePlatform: try XCTUnwrap(V2SourcePlatform(rawValue: try string(object, "sourcePlatform"))),
        timestamp: try integer(object, "timestamp"),
        nonce: try string(object, "nonce"),
        authTag: authTag,
        intent: (object["intent"] as? String).flatMap(V2HandoverIntent.init(rawValue:)),
        wakeSucceeded: (object["wakeSucceeded"] as? NSNumber)?.boolValue,
        switchSucceeded: (object["switchSucceeded"] as? NSNumber)?.boolValue,
        reason: (object["reason"] as? String).flatMap(V2CancellationReason.init(rawValue:))
    )
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
