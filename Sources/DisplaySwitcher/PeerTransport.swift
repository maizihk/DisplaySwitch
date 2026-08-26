import Foundation
import Network

enum PeerMessageType: String, Codable {
    case handoverRequest = "handover_request"
    case usbPresent = "usb_present"
    case usbReady = "usb_attached_and_awake"
    case committed
    case statusProbe = "status_probe"
    case statusResponse = "status_response"
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

    static func accepts(
        _ message: PeerMessage,
        pairingCode: String,
        expectedSource: String,
        expectedTarget: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        pairingCode.count >= 8 &&
            message.version == version &&
            message.pairingCode == pairingCode &&
            message.source == expectedSource &&
            message.target == expectedTarget &&
            UUID(uuidString: message.eventID) != nil &&
            message.timestamp.isFinite &&
            abs(now - message.timestamp) <= maximumAge
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
    var onMessage: ((PeerMessage) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "DisplaySwitcher.peer-network")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func start(port: Int) {
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
            listener.start(queue: queue)
        } catch {
            onError?("无法监听端口 \(port)：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
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

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
            case .failed, .cancelled:
                connection.cancel()
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

            if let data, let message = try? self.decoder.decode(PeerMessage.self, from: data) {
                DispatchQueue.main.async { self.onMessage?(message) }
            }

            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }
}
