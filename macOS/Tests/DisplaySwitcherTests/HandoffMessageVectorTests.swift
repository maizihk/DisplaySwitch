import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DisplaySwitcher
#endif

private enum DecodingValidationFailureReason: String {
    case parseError = "parse_error"
    case missingField = "missing_field"
    case invalidFieldType = "invalid_field_type"
}

private enum MessageVectorInput: Decodable {
    case jsonObject([String: JSONValue])
    case rawUtf8(String)

    enum CodingKeys: String, CodingKey {
        case encoding
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoding = try container.decode(String.self, forKey: .encoding)
        switch encoding {
        case "jsonObject":
            let value = try container.decode([String: JSONValue].self, forKey: .value)
            self = .jsonObject(value)
        case "rawUtf8":
            let value = try container.decode(String.self, forKey: .value)
            self = .rawUtf8(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .encoding,
                in: container,
                debugDescription: "Unsupported encoding \(encoding)"
            )
        }
    }

    var payloadData: Data {
        switch self {
        case .jsonObject(let value):
            let payload = try! JSONEncoder().encode(value)
            return payload
        case .rawUtf8(let text):
            return Data(text.utf8)
        }
    }
}

private indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct MessageValidationExpected: Decodable {
    let accepted: Bool
    let reason: String
    let refreshPeer: Bool
    let replyTypes: [String]
    let hardwareCalls: [String: Int]
}

private struct MessageValidationVector: Decodable {
    let id: String
    let description: String
    let localPlatform: String
    let input: MessageVectorInput
    let expected: MessageValidationExpected
}

private struct MessageValidationVectorFile: Decodable {
    let vectors: [MessageValidationVector]
    let configuredPairingCode: String
}

private struct MessageValidationResult {
    let accepted: Bool
    let reason: String
}

private func expectedSource(for localPlatform: String) -> String {
    localPlatform == "mac" ? "windows" : "mac"
}

private func expectedTarget(for localPlatform: String) -> String {
    localPlatform == "mac" ? "mac" : "windows"
}

private func readMessageVectorFixtures() throws -> MessageValidationVectorFile {
    let fileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contracts/protocol-v1/message-validation-vectors.json")
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(MessageValidationVectorFile.self, from: data)
}

private func messageValidationResult(for vector: MessageValidationVector, now: TimeInterval, pairingCode: String) -> MessageValidationResult {
    func decodeFailureReason(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return DecodingValidationFailureReason.parseError.rawValue
        }

        switch decodingError {
        case .typeMismatch:
            return DecodingValidationFailureReason.invalidFieldType.rawValue
        case .valueNotFound, .keyNotFound:
            return DecodingValidationFailureReason.missingField.rawValue
        case .dataCorrupted:
            return DecodingValidationFailureReason.parseError.rawValue
        @unknown default:
            return DecodingValidationFailureReason.parseError.rawValue
        }
    }

    let message: PeerMessage
    do {
        message = try JSONDecoder().decode(PeerMessage.self, from: vector.input.payloadData)
    } catch {
        let expectedReason = decodeFailureReason(error)
        return MessageValidationResult(accepted: false, reason: expectedReason)
    }

    let validation = PeerMessageValidation.validate(
        message: message,
        pairingCode: pairingCode,
        expectedSource: expectedSource(for: vector.localPlatform),
        expectedTarget: expectedTarget(for: vector.localPlatform),
        now: now
    )
    return MessageValidationResult(accepted: validation.accepted, reason: validation.reason.rawValue)
}

final class HandoffMessageVectorTests: XCTestCase {
    func testMessageVectorsMatchValidator() throws {
        let fixture = try readMessageVectorFixtures()
        XCTAssertEqual(fixture.vectors.count, 17, "expect 17 message validation vectors")

        let referenceTime = TimeInterval(1_788_000_000)
        for vector in fixture.vectors {
            let result = messageValidationResult(
                for: vector,
                now: referenceTime,
                pairingCode: fixture.configuredPairingCode
            )

            XCTAssertEqual(
                result.accepted,
                vector.expected.accepted,
                "MSG vector \(vector.id): \(vector.description) acceptance mismatch"
            )
            XCTAssertEqual(
                result.reason,
                vector.expected.reason,
                "MSG vector \(vector.id): \(vector.description) reason mismatch"
            )
            XCTAssertEqual(
                vector.expected.hardwareCalls["wake"] ?? 0,
                0,
                "MSG vector \(vector.id): expected hardware count must be zero in protocol validation"
            )
            XCTAssertEqual(
                vector.expected.hardwareCalls["switchDisplay"] ?? 0,
                0,
                "MSG vector \(vector.id): expected hardware count must be zero in protocol validation"
            )
            XCTAssertEqual(
                vector.expected.hardwareCalls["usbActions"] ?? 0,
                0,
                "MSG vector \(vector.id): expected hardware count must be zero in protocol validation"
            )
        }
    }
}
