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

    func testVersionDispatcherKeepsV1AndV2Independent() throws {
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":1}"#.utf8)), .v1)
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":2}"#.utf8)), .v2)
        XCTAssertEqual(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":9}"#.utf8)), .unsupported(9))
        XCTAssertNil(PeerProtocolVersionDispatcher.version(in: Data(#"{"version":"2"}"#.utf8)))
    }

    func testEndpointRoutingRejectsDuplicatesAndUsesStableLogicalIDs() throws {
        let display = DisplayConfigurationV3Display(
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
        let duplicate = DisplayConfigurationStoreV3Document(
            schemaVersion: 3,
            localEndpointID: "11111111-1111-4111-8111-111111111111",
            localDeviceName: "Local", listenPort: 49_731, displays: [display],
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
