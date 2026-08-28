import Foundation
import Network

enum PeerTransportConnectionState {
    case setup
    case ready
    case failed(Error)
    case cancelled
}

protocol PeerTransportConnection: AnyObject {
    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receiveMessage(completion: @escaping (Data?, Error?) -> Void)
}

protocol PeerTransportListener: AnyObject {
    var newConnectionHandler: ((PeerTransportConnection) -> Void)? { get set }
    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

protocol PeerTransportConnectionFactory {
    func makeListener(port: Int) throws -> PeerTransportListener
    func makeConnection(host: String, destinationPort: Int, sourcePort: Int) throws -> PeerTransportConnection
}

private final class NetworkPeerConnection: PeerTransportConnection {
    private let connection: NWConnection

    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)? {
        didSet {
            connection.stateUpdateHandler = { [weak self] state in
                self?.stateUpdateHandler?(Self.map(state))
            }
        }
    }

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) { connection.start(queue: queue) }
    func cancel() { connection.cancel() }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func receiveMessage(completion: @escaping (Data?, Error?) -> Void) {
        connection.receiveMessage { data, _, _, error in completion(data, error) }
    }

    fileprivate static func map(_ state: NWConnection.State) -> PeerTransportConnectionState {
        switch state {
        case .ready: return .ready
        case .failed(let error): return .failed(error)
        case .cancelled: return .cancelled
        default: return .setup
        }
    }
}

private final class NetworkPeerListener: PeerTransportListener {
    private let listener: NWListener

    var newConnectionHandler: ((PeerTransportConnection) -> Void)? {
        didSet {
            listener.newConnectionHandler = { [weak self] connection in
                self?.newConnectionHandler?(NetworkPeerConnection(connection))
            }
        }
    }

    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)? {
        didSet {
            listener.stateUpdateHandler = { [weak self] state in
                let mapped: PeerTransportConnectionState
                switch state {
                case .ready: mapped = .ready
                case .failed(let error): mapped = .failed(error)
                case .cancelled: mapped = .cancelled
                default: mapped = .setup
                }
                self?.stateUpdateHandler?(mapped)
            }
        }
    }

    init(_ listener: NWListener) { self.listener = listener }
    func start(queue: DispatchQueue) { listener.start(queue: queue) }
    func cancel() { listener.cancel() }
}

private struct NetworkPeerTransportConnectionFactory: PeerTransportConnectionFactory {
    func makeListener(port: Int) throws -> PeerTransportListener {
        guard let rawPort = UInt16(exactly: port), rawPort > 0,
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw PeerTransportError.invalidPort(port)
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        return NetworkPeerListener(try NWListener(using: parameters, on: nwPort))
    }

    func makeConnection(host: String, destinationPort: Int, sourcePort: Int) throws -> PeerTransportConnection {
        guard let rawDestination = UInt16(exactly: destinationPort), rawDestination > 0,
              let rawSource = UInt16(exactly: sourcePort), rawSource > 0,
              let destination = NWEndpoint.Port(rawValue: rawDestination),
              let source = NWEndpoint.Port(rawValue: rawSource) else {
            throw PeerTransportError.invalidPort(destinationPort)
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: source)
        return NetworkPeerConnection(NWConnection(
            host: NWEndpoint.Host(host), port: destination, using: parameters
        ))
    }
}

private enum PeerTransportError: LocalizedError {
    case invalidPort(Int)
    case notStarted

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "通信端口无效：\(port)"
        case .notStarted: return "UDP 发送失败：网络监听尚未启动"
        }
    }
}

final class PeerTransport {
    typealias DataReply = (Data) -> Void

    var onDatagram: ((Data, @escaping DataReply) -> Void)?
    var onError: ((String) -> Void)?

    private final class OutgoingChannel {
        let connection: PeerTransportConnection
        var pending: [Data] = []
        var ready = false

        init(connection: PeerTransportConnection) { self.connection = connection }
    }

    private struct DestinationKey: Hashable {
        let host: String
        let port: Int
    }

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let factory: PeerTransportConnectionFactory
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: PeerTransportListener?
    private var acceptedConnections: [ObjectIdentifier: PeerTransportConnection] = [:]
    private var outgoingChannels: [DestinationKey: OutgoingChannel] = [:]
    private var generation = 0
    private(set) var listeningPort: Int?

    init(
        factory: PeerTransportConnectionFactory = NetworkPeerTransportConnectionFactory(),
        queue: DispatchQueue = DispatchQueue(label: "DisplaySwitcher.peer-network"),
        callbackQueue: DispatchQueue = .main
    ) {
        self.factory = factory
        self.queue = queue
        self.callbackQueue = callbackQueue
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { performSync { stopLocked() } }

    func start(port: Int) {
        performSync {
            if listener != nil, listeningPort == port { return }
            stopLocked()
            do {
                let listener = try factory.makeListener(port: port)
                generation += 1
                let activeGeneration = generation
                listener.newConnectionHandler = { [weak self] connection in
                    self?.performAsync {
                        guard self?.generation == activeGeneration else {
                            connection.cancel()
                            return
                        }
                        self?.acceptLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.performAsync {
                        guard let self, self.generation == activeGeneration else { return }
                        if case .failed(let error) = state {
                            self.reportError("网络监听失败：\(error.localizedDescription)")
                            self.stopLocked()
                        }
                    }
                }
                self.listener = listener
                listeningPort = port
                listener.start(queue: queue)
            } catch {
                reportError("无法监听端口 \(port)：\(error.localizedDescription)")
            }
        }
    }

    func stop() { performSync { stopLocked() } }

    func send(_ data: Data, host: String, port: Int) {
        guard !host.isEmpty, (1...65_535).contains(port) else { return }
        performSync {
            guard let sourcePort = listeningPort, listener != nil else {
                reportError(PeerTransportError.notStarted.localizedDescription)
                return
            }
            let key = DestinationKey(host: host.lowercased(), port: port)
            if let channel = outgoingChannels[key] {
                if channel.ready {
                    sendLocked(data, on: channel.connection, channelKey: key, isReply: false)
                } else {
                    channel.pending.append(data)
                }
                return
            }

            do {
                let connection = try factory.makeConnection(
                    host: host, destinationPort: port, sourcePort: sourcePort
                )
                let channel = OutgoingChannel(connection: connection)
                channel.pending.append(data)
                outgoingChannels[key] = channel
                let activeGeneration = generation
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let connection else { return }
                    self?.performAsync {
                        self?.handleOutgoingStateLocked(
                            state, connection: connection, key: key, generation: activeGeneration
                        )
                    }
                }
                connection.start(queue: queue)
                receiveLocked(on: connection, acceptedKey: nil, outgoingKey: key, generation: activeGeneration)
            } catch {
                reportError("UDP 连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func stopLocked() {
        generation += 1
        listener?.cancel()
        listener = nil
        listeningPort = nil
        acceptedConnections.values.forEach { $0.cancel() }
        acceptedConnections.removeAll(keepingCapacity: false)
        outgoingChannels.values.forEach { $0.connection.cancel() }
        outgoingChannels.removeAll(keepingCapacity: false)
    }

    private func handleOutgoingStateLocked(
        _ state: PeerTransportConnectionState,
        connection: PeerTransportConnection,
        key: DestinationKey,
        generation activeGeneration: Int
    ) {
        guard generation == activeGeneration,
              let channel = outgoingChannels[key], channel.connection === connection else {
            connection.cancel()
            return
        }
        switch state {
        case .ready:
            guard !channel.ready else { return }
            channel.ready = true
            let pending = channel.pending
            channel.pending.removeAll(keepingCapacity: false)
            for data in pending {
                sendLocked(data, on: connection, channelKey: key, isReply: false)
            }
        case .failed(let error):
            reportError("UDP 连接失败：\(error.localizedDescription)")
            removeOutgoingLocked(key: key, connection: connection)
        case .cancelled:
            removeOutgoingLocked(key: key, connection: connection)
        case .setup:
            break
        }
    }

    private func acceptLocked(_ connection: PeerTransportConnection) {
        let key = ObjectIdentifier(connection)
        acceptedConnections[key] = connection
        let activeGeneration = generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            self?.performAsync {
                guard let self, self.generation == activeGeneration else {
                    connection.cancel()
                    return
                }
                switch state {
                case .failed(let error):
                    self.reportError("UDP 接收连接失败：\(error.localizedDescription)")
                    self.removeAcceptedLocked(connection)
                case .cancelled:
                    self.removeAcceptedLocked(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveLocked(on: connection, acceptedKey: key, outgoingKey: nil, generation: activeGeneration)
    }

    private func receiveLocked(
        on connection: PeerTransportConnection,
        acceptedKey: ObjectIdentifier?,
        outgoingKey: DestinationKey?,
        generation activeGeneration: Int
    ) {
        connection.receiveMessage { [weak self, weak connection] data, error in
            guard let self, let connection else { return }
            self.performAsync {
                guard self.generation == activeGeneration else { return }
                if let data {
                    self.deliver(data, replyOn: connection, channelKey: outgoingKey)
                }
                if let error {
                    self.reportError("UDP 接收失败：\(error.localizedDescription)")
                    if let acceptedKey, self.acceptedConnections[acceptedKey] === connection {
                        self.removeAcceptedLocked(connection)
                    }
                    if let outgoingKey {
                        self.removeOutgoingLocked(key: outgoingKey, connection: connection)
                    }
                } else {
                    self.receiveLocked(
                        on: connection, acceptedKey: acceptedKey, outgoingKey: outgoingKey,
                        generation: activeGeneration
                    )
                }
            }
        }
    }

    private func deliver(
        _ data: Data,
        replyOn connection: PeerTransportConnection,
        channelKey: DestinationKey?
    ) {
        guard let onDatagram else { return }
        let reply: DataReply = { [weak self, weak connection] response in
            guard let self, let connection else { return }
            self.performAsync {
                self.sendLocked(response, on: connection, channelKey: channelKey, isReply: true)
            }
        }
        callbackQueue.async { onDatagram(data, reply) }
    }

    private func sendLocked(
        _ data: Data,
        on connection: PeerTransportConnection,
        channelKey: DestinationKey?,
        isReply: Bool
    ) {
        connection.send(data) { [weak self, weak connection] error in
            guard let self, let connection, let error else { return }
            self.performAsync {
                let operation = isReply ? "UDP 回复失败" : "UDP 发送失败"
                self.reportError("\(operation)：\(error.localizedDescription)")
                if let channelKey {
                    self.removeOutgoingLocked(key: channelKey, connection: connection)
                }
            }
        }
    }

    private func removeAcceptedLocked(_ connection: PeerTransportConnection) {
        acceptedConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func removeOutgoingLocked(key: DestinationKey, connection: PeerTransportConnection) {
        guard let channel = outgoingChannels[key], channel.connection === connection else { return }
        outgoingChannels.removeValue(forKey: key)
        connection.cancel()
    }

    private func reportError(_ message: String) {
        callbackQueue.async { [weak self] in self?.onError?(message) }
    }

    private func performSync(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { action() }
        else { queue.sync(execute: action) }
    }

    private func performAsync(_ action: @escaping () -> Void) {
        queue.async(execute: action)
    }
}
