import Foundation
import Network

final class PeerTransport {
    typealias DataReply = (Data) -> Void

    var onDatagram: ((Data, @escaping DataReply) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "DisplaySwitcher.peer-network")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
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
                }
            }

            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
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
