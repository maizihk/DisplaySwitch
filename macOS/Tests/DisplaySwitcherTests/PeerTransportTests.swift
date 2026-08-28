import Foundation
import XCTest

final class PeerTransportTests: XCTestCase {
    func testAllActiveRequestTypesUseListenPortAsSourceAndProfilePortAsDestination() {
        let factory = MockPeerTransportFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let sent = expectation(description: "all active request datagrams sent")
        sent.expectedFulfillmentCount = 3

        transport.start(port: 49_731)
        transport.start(port: 49_731)
        for payload in ["status_probe", "wake_display", "handover_request"] {
            transport.send(Data(payload.utf8), host: "peer.example", port: 50_001)
        }

        XCTAssertEqual(factory.listenerPorts, [49_731])
        XCTAssertEqual(factory.connectionRequests, [
            .init(host: "peer.example", destinationPort: 50_001, sourcePort: 49_731)
        ])
        let connection = factory.connections[0]
        connection.onSend = { _, completion in
            completion(nil)
            sent.fulfill()
        }
        connection.emit(.ready)

        wait(for: [sent], timeout: 1)
        XCTAssertEqual(connection.sentData.map { String(decoding: $0, as: UTF8.self) }, [
            "status_probe", "wake_display", "handover_request"
        ])
    }

    func testReconfigureCancelsOldResourcesAndUsesNewSourcePort() {
        let factory = MockPeerTransportFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)

        transport.start(port: 49_731)
        transport.send(Data("first".utf8), host: "peer.example", port: 50_001)
        let oldListener = factory.listeners[0]
        let oldConnection = factory.connections[0]

        transport.start(port: 49_732)
        XCTAssertTrue(oldListener.cancelled)
        XCTAssertTrue(oldConnection.cancelled)
        XCTAssertEqual(transport.listeningPort, 49_732)

        transport.send(Data("second".utf8), host: "peer.example", port: 50_001)
        XCTAssertEqual(factory.connectionRequests.last, .init(
            host: "peer.example", destinationPort: 50_001, sourcePort: 49_732
        ))
    }

    func testStopCancelsListenerAndOutgoingConnectionAndPreventsUnboundSend() {
        let factory = MockPeerTransportFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let errorReported = expectation(description: "send after stop rejected")
        transport.onError = { message in
            if message.contains("尚未启动") { errorReported.fulfill() }
        }

        transport.start(port: 49_731)
        transport.send(Data("request".utf8), host: "peer.example", port: 50_001)
        transport.stop()

        XCTAssertTrue(factory.listeners[0].cancelled)
        XCTAssertTrue(factory.connections[0].cancelled)
        XCTAssertNil(transport.listeningPort)
        transport.send(Data("after-stop".utf8), host: "peer.example", port: 50_001)

        wait(for: [errorReported], timeout: 1)
        XCTAssertEqual(factory.connections.count, 1)
    }

    func testSendFailureReleasesChannelSoNextSendRebuildsIt() {
        let factory = MockPeerTransportFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let errorReported = expectation(description: "send failure reported")
        transport.onError = { message in
            if message.contains("UDP 发送失败") { errorReported.fulfill() }
        }

        transport.start(port: 49_731)
        transport.send(Data("first".utf8), host: "peer.example", port: 50_001)
        let failedConnection = factory.connections[0]
        failedConnection.onSend = { _, completion in completion(MockTransportError.sendFailed) }
        failedConnection.emit(.ready)

        wait(for: [errorReported], timeout: 1)
        XCTAssertTrue(failedConnection.cancelled)

        transport.send(Data("retry".utf8), host: "peer.example", port: 50_001)
        XCTAssertEqual(factory.connections.count, 2)
        XCTAssertEqual(factory.connectionRequests.last?.sourcePort, 49_731)
    }

    func testReplyUsesTheConnectionThatReceivedTheDatagram() {
        let factory = MockPeerTransportFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let receiveRegistered = expectation(description: "receive registered")
        let replySent = expectation(description: "reply sent on accepted connection")
        let accepted = MockPeerTransportConnection()
        accepted.onReceiveRegistered = { receiveRegistered.fulfill() }
        accepted.onSend = { data, completion in
            XCTAssertEqual(data, Data("response".utf8))
            completion(nil)
            replySent.fulfill()
        }
        transport.onDatagram = { data, reply in
            XCTAssertEqual(data, Data("request".utf8))
            reply(Data("response".utf8))
        }

        transport.start(port: 49_731)
        factory.listeners[0].emit(accepted)
        wait(for: [receiveRegistered], timeout: 1)
        accepted.deliver(Data("request".utf8))

        wait(for: [replySent], timeout: 1)
        XCTAssertEqual(factory.connections.count, 0)
        XCTAssertEqual(accepted.sentData, [Data("response".utf8)])
    }
}

private enum MockTransportError: LocalizedError {
    case sendFailed
    var errorDescription: String? { "simulated send failure" }
}

private struct MockConnectionRequest: Equatable {
    let host: String
    let destinationPort: Int
    let sourcePort: Int
}

private final class MockPeerTransportFactory: PeerTransportConnectionFactory {
    private(set) var listenerPorts: [Int] = []
    private(set) var listeners: [MockPeerTransportListener] = []
    private(set) var connectionRequests: [MockConnectionRequest] = []
    private(set) var connections: [MockPeerTransportConnection] = []

    func makeListener(port: Int) throws -> PeerTransportListener {
        listenerPorts.append(port)
        let listener = MockPeerTransportListener()
        listeners.append(listener)
        return listener
    }

    func makeConnection(host: String, destinationPort: Int, sourcePort: Int) throws -> PeerTransportConnection {
        connectionRequests.append(.init(
            host: host, destinationPort: destinationPort, sourcePort: sourcePort
        ))
        let connection = MockPeerTransportConnection()
        connections.append(connection)
        return connection
    }
}

private final class MockPeerTransportListener: PeerTransportListener {
    var newConnectionHandler: ((PeerTransportConnection) -> Void)?
    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)?
    private(set) var cancelled = false

    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }
    func emit(_ connection: PeerTransportConnection) { newConnectionHandler?(connection) }
}

private final class MockPeerTransportConnection: PeerTransportConnection {
    var stateUpdateHandler: ((PeerTransportConnectionState) -> Void)?
    var onSend: ((Data, @escaping (Error?) -> Void) -> Void)?
    var onReceiveRegistered: (() -> Void)?
    private var receiveCompletion: ((Data?, Error?) -> Void)?
    private(set) var sentData: [Data] = []
    private(set) var cancelled = false

    func start(queue: DispatchQueue) {}
    func cancel() { cancelled = true }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sentData.append(data)
        if let onSend { onSend(data, completion) } else { completion(nil) }
    }

    func receiveMessage(completion: @escaping (Data?, Error?) -> Void) {
        receiveCompletion = completion
        onReceiveRegistered?()
        onReceiveRegistered = nil
    }

    func emit(_ state: PeerTransportConnectionState) { stateUpdateHandler?(state) }

    func deliver(_ data: Data) {
        let completion = receiveCompletion
        receiveCompletion = nil
        completion?(data, nil)
    }
}
