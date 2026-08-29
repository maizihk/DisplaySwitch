import Foundation
import XCTest

final class PeerTransportTests: XCTestCase {
    func testAllActiveRequestsUseOneBoundSocketAndConfiguredDestination() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let sent = expectation(description: "all datagrams sent")
        sent.expectedFulfillmentCount = 3

        transport.start(port: 49_731)
        transport.start(port: 49_731)
        factory.sockets[0].onSend = { _, _, completion in completion(nil); sent.fulfill() }
        for payload in ["status_probe", "wake_display", "handover_request"] {
            transport.send(Data(payload.utf8), host: "peer.example", port: 50_001)
        }

        wait(for: [sent], timeout: 1)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(factory.sockets[0].startedPorts, [49_731])
        XCTAssertEqual(factory.sockets[0].sent.map(\.endpoint), Array(
            repeating: PeerTransportEndpoint(host: "peer.example", port: 50_001), count: 3
        ))
    }

    func testStatusProbeResponseKeepsEventAndReturnsToOriginalSource() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let replySent = expectation(description: "status response sent")
        let source = PeerTransportEndpoint(host: "198.51.100.20", port: 50_001)
        let eventID = "simulated-event-id"
        factory.onSocketCreated = { socket in
            socket.onSend = { data, endpoint, completion in
                XCTAssertEqual(endpoint, source)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(eventID))
                completion(nil)
                replySent.fulfill()
            }
        }
        transport.onDatagram = { data, reply in
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(eventID))
            reply(Data("status_response:\(eventID)".utf8))
        }

        transport.start(port: 49_731)
        factory.sockets[0].emit(Data("status_probe:\(eventID)".utf8), from: source)

        wait(for: [replySent], timeout: 1)
    }

    func testConsecutiveBidirectionalProbesStayOnSingleSocket() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let sent = expectation(description: "continuous outgoing probes")
        sent.expectedFulfillmentCount = 4
        transport.start(port: 49_731)
        factory.sockets[0].onSend = { _, _, completion in completion(nil); sent.fulfill() }

        for index in 0..<4 {
            transport.send(Data("probe-\(index)".utf8), host: "peer.example", port: 50_001)
        }
        wait(for: [sent], timeout: 1)

        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(factory.sockets[0].sent.count, 4)
        XCTAssertEqual(transport.listeningPort, 49_731)
    }

    func testRepliesRemainBoundToEachDatagramSourceAndPort() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let replies = expectation(description: "source-specific replies")
        replies.expectedFulfillmentCount = 2
        transport.onDatagram = { data, reply in reply(data) }
        transport.start(port: 49_731)
        factory.sockets[0].onSend = { _, _, completion in completion(nil); replies.fulfill() }

        let first = PeerTransportEndpoint(host: "198.51.100.10", port: 50_001)
        let second = PeerTransportEndpoint(host: "198.51.100.11", port: 50_002)
        factory.sockets[0].emit(Data("first".utf8), from: first)
        factory.sockets[0].emit(Data("second".utf8), from: second)

        wait(for: [replies], timeout: 1)
        XCTAssertEqual(factory.sockets[0].sent.map(\.endpoint), [first, second])
    }

    func testReconfigureAndReceiveFailureStopOldSocketAndAllowCleanRestart() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let receiveError = expectation(description: "receive failure reported")
        transport.onError = { message in
            if message.contains("UDP 接收失败") { receiveError.fulfill() }
        }

        transport.start(port: 49_731)
        let first = factory.sockets[0]
        transport.start(port: 49_732)
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(factory.sockets[1].startedPorts, [49_732])

        factory.sockets[1].failReceive()
        wait(for: [receiveError], timeout: 1)
        XCTAssertTrue(factory.sockets[1].stopped)
        XCTAssertNil(transport.listeningPort)

        transport.start(port: 49_733)
        XCTAssertEqual(factory.sockets[2].startedPorts, [49_733])
    }

    func testSendFailureReportsErrorWithoutCreatingOrLosingBoundSocket() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let errorReported = expectation(description: "send error reported")
        let retrySent = expectation(description: "retry sent")
        transport.onError = { message in
            if message.contains("UDP 发送失败") { errorReported.fulfill() }
        }
        transport.start(port: 49_731)
        let socket = factory.sockets[0]
        var fail = true
        socket.onSend = { _, _, completion in
            if fail { fail = false; completion(MockTransportError.sendFailed) }
            else { completion(nil); retrySent.fulfill() }
        }

        transport.send(Data("first".utf8), host: "peer.example", port: 50_001)
        wait(for: [errorReported], timeout: 1)
        transport.send(Data("retry".utf8), host: "peer.example", port: 50_001)
        wait(for: [retrySent], timeout: 1)

        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertFalse(socket.stopped)
        XCTAssertEqual(socket.sent.count, 2)
    }

    func testStopPreventsUnboundSend() {
        let factory = MockPeerTransportSocketFactory()
        let transport = PeerTransport(factory: factory, callbackQueue: .main)
        let errorReported = expectation(description: "send after stop rejected")
        transport.onError = { message in
            if message.contains("尚未启动") { errorReported.fulfill() }
        }
        transport.start(port: 49_731)
        let socket = factory.sockets[0]
        transport.stop()
        transport.send(Data("after-stop".utf8), host: "peer.example", port: 50_001)

        wait(for: [errorReported], timeout: 1)
        XCTAssertTrue(socket.stopped)
        XCTAssertTrue(socket.sent.isEmpty)
    }
}

private enum MockTransportError: LocalizedError {
    case sendFailed
    case receiveFailed
    var errorDescription: String? { "simulated transport failure" }
}

private final class MockPeerTransportSocketFactory: PeerTransportSocketFactory {
    private(set) var sockets: [MockPeerDatagramSocket] = []
    var onSocketCreated: ((MockPeerDatagramSocket) -> Void)?

    func makeSocket() -> PeerTransportDatagramSocket {
        let socket = MockPeerDatagramSocket()
        sockets.append(socket)
        onSocketCreated?(socket)
        return socket
    }
}

private final class MockPeerDatagramSocket: PeerTransportDatagramSocket {
    struct SentDatagram {
        let data: Data
        let endpoint: PeerTransportEndpoint
    }

    var onDatagram: ((Data, PeerTransportEndpoint) -> Void)?
    var onReceiveError: ((Error) -> Void)?
    var onSend: ((Data, PeerTransportEndpoint, @escaping (Error?) -> Void) -> Void)?
    private(set) var startedPorts: [Int] = []
    private(set) var sent: [SentDatagram] = []
    private(set) var stopped = false

    func start(port: Int, queue: DispatchQueue) throws { startedPorts.append(port) }

    func send(_ data: Data, to endpoint: PeerTransportEndpoint, completion: @escaping (Error?) -> Void) {
        sent.append(SentDatagram(data: data, endpoint: endpoint))
        if let onSend { onSend(data, endpoint, completion) } else { completion(nil) }
    }

    func stop() { stopped = true }
    func emit(_ data: Data, from endpoint: PeerTransportEndpoint) { onDatagram?(data, endpoint) }
    func failReceive() { onReceiveError?(MockTransportError.receiveFailed) }
}
