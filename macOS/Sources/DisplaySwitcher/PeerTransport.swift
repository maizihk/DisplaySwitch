import Foundation
import Network

enum PeerMessageType: RawRepresentable, Codable, Hashable {
    case handoverRequest
    case usbPresent
    case usbReady
    case committed
    case statusProbe
    case statusResponse
    case unknown(String)

    var rawValue: String {
        switch self {
        case .handoverRequest:
            return "handover_request"
        case .usbPresent:
            return "usb_present"
        case .usbReady:
            return "usb_attached_and_awake"
        case .committed:
            return "committed"
        case .statusProbe:
            return "status_probe"
        case .statusResponse:
            return "status_response"
        case let .unknown(value):
            return value
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "handover_request":
            self = .handoverRequest
        case "usb_present":
            self = .usbPresent
        case "usb_attached_and_awake":
            self = .usbReady
        case "committed":
            self = .committed
        case "status_probe":
            self = .statusProbe
        case "status_response":
            self = .statusResponse
        default:
            self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown(rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PeerMessageValidationReason: String {
    case accepted
    case unsupported_version
    case invalid_event_id
    case timestamp_out_of_window
    case wrong_direction
    case pairing_mismatch
    case unknown_type
    case missing_field
    case invalid_field_type
    case parse_error
}

struct PeerMessageValidationResult {
    let accepted: Bool
    let reason: PeerMessageValidationReason
}

struct PeerMessage: Codable {
    let version: Int
    let type: PeerMessageType
    let eventID: String
    let source: String
    let target: String
    let timestamp: TimeInterval
    let pairingCode: String
    let wakeSucceeded: Bool?

    init(
        version: Int = 1,
        type: PeerMessageType,
        eventID: String,
        source: String,
        target: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        pairingCode: String,
        wakeSucceeded: Bool? = nil
    ) {
        self.version = version
        self.type = type
        self.eventID = eventID
        self.source = source
        self.target = target
        self.timestamp = timestamp
        self.pairingCode = pairingCode
        self.wakeSucceeded = wakeSucceeded
    }
}

enum PeerMessageValidation {
    static let version = 1
    static let maximumAge: TimeInterval = 10
    static let maximumAgeMs = Int64(maximumAge * 1000)

    static func validate(
        message: PeerMessage,
        pairingCode: String,
        expectedSource: String,
        expectedTarget: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> PeerMessageValidationResult {
        switch message.type {
        case .unknown:
            return PeerMessageValidationResult(accepted: false, reason: .unknown_type)
        default:
            break
        }

        guard message.version == version else {
            return PeerMessageValidationResult(accepted: false, reason: .unsupported_version)
        }
        guard message.pairingCode == pairingCode else {
            return PeerMessageValidationResult(accepted: false, reason: .pairing_mismatch)
        }
        guard message.source == expectedSource, message.target == expectedTarget else {
            return PeerMessageValidationResult(accepted: false, reason: .wrong_direction)
        }
        guard UUID(uuidString: message.eventID) != nil else {
            return PeerMessageValidationResult(accepted: false, reason: .invalid_event_id)
        }
        guard message.timestamp.isFinite else {
            return PeerMessageValidationResult(accepted: false, reason: .timestamp_out_of_window)
        }
        guard abs(now - message.timestamp) <= maximumAge else {
            return PeerMessageValidationResult(accepted: false, reason: .timestamp_out_of_window)
        }
        return PeerMessageValidationResult(accepted: true, reason: .accepted)
    }

    static func accepts(
        _ message: PeerMessage,
        pairingCode: String,
        expectedSource: String,
        expectedTarget: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let result = validate(
            message: message,
            pairingCode: pairingCode,
            expectedSource: expectedSource,
            expectedTarget: expectedTarget,
            now: now
        )
        return pairingCode.count >= 8 && result.accepted
    }
}

enum PeerMessageDisposition: Equatable {
    case new
    case duplicate
    case outOfOrder
}

struct PeerReplayGuard {
    private var seenKeys: [String: TimeInterval] = [:]
    private var newestHandoverTimestamp: TimeInterval = 0

    mutating func classify(
        _ message: PeerMessage,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> PeerMessageDisposition {
        seenKeys = seenKeys.filter { now - $0.value <= PeerMessageValidation.maximumAge }
        let key = "\(message.type.rawValue):\(message.eventID.lowercased())"
        if seenKeys[key] != nil {
            return .duplicate
        }

        if message.type == .handoverRequest {
            guard message.timestamp >= newestHandoverTimestamp else {
                return .outOfOrder
            }
            newestHandoverTimestamp = message.timestamp
        }

        seenKeys[key] = now
        if seenKeys.count > 2_048,
           let oldestKey = seenKeys.min(by: { $0.value < $1.value })?.key {
            seenKeys.removeValue(forKey: oldestKey)
        }
        return .new
    }

    mutating func reset() {
        seenKeys.removeAll(keepingCapacity: true)
        newestHandoverTimestamp = 0
    }
}

final class PeerTransport {
    typealias Reply = (PeerMessage) -> Void
    typealias DataReply = (Data) -> Void

    var onMessage: ((PeerMessage, @escaping Reply) -> Void)?
    var onDatagram: ((Data, @escaping DataReply) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "DisplaySwitcher.peer-network")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var listeningPort: Int?

    func start(port: Int) {
        if listener != nil, listeningPort == port { return }
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            onError?("通信端口无效：\(port)")
            return
        }

        do {
            let listener = try NWListener(using: .udp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    DispatchQueue.main.async { self?.onError?("网络监听失败：\(error.localizedDescription)") }
                }
            }
            self.listener = listener
            listeningPort = port
            listener.start(queue: queue)
        } catch {
            onError?("无法监听端口 \(port)：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    func send(_ message: PeerMessage, host: String, port: Int) {
        guard
            !host.isEmpty,
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port)),
            let data = try? encoder.encode(message)
        else {
            return
        }

        send(data, host: host, port: nwPort)
    }

    func send(_ data: Data, host: String, port: Int) {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        send(data, host: host, port: nwPort)
    }

    private func send(_ data: Data, host: String, port: NWEndpoint.Port) {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.reportError("UDP 发送失败：\(error.localizedDescription)")
                    }
                    connection.cancel()
                })
            case let .failed(error):
                self?.reportError("UDP 连接失败：\(error.localizedDescription)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .cancelled = state {
                self.connections.removeAll { $0 === connection }
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let data {
                if let onDatagram = self.onDatagram {
                    let reply: DataReply = { [weak self, weak connection] response in
                        guard let self, let connection else { return }
                        self.send(response, on: connection)
                    }
                    DispatchQueue.main.async { onDatagram(data, reply) }
                } else if let message = try? self.decoder.decode(PeerMessage.self, from: data) {
                    let reply: Reply = { [weak self, weak connection] response in
                        guard let self, let connection else { return }
                        self.send(response, on: connection)
                    }
                    DispatchQueue.main.async { self.onMessage?(message, reply) }
                }
            }

            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func send(_ message: PeerMessage, on connection: NWConnection) {
        guard let data = try? encoder.encode(message) else { return }
        send(data, on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.reportError("UDP 回复失败：\(error.localizedDescription)")
            }
        })
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}
