import XCTest
import NIO
import NMTP
@testable import NMTPeer

// MARK: - Test message types

private struct Ping: PeerMessage {
    static let messageType: UInt16 = 0x0001
    let body: String
}

private struct Pong: PeerMessage {
    static let messageType: UInt16 = 0x0002
    let body: String
}

private struct Notify: PeerMessage {
    static let messageType: UInt16 = 0x0003
    let text: String
}

// MARK: - Tests

final class PeerDispatcherTests: XCTestCase {

    func testRegisteredHandlerReceivesTypedMessage() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let clientPeer = try await Peer.connect(to: listener.address)
        defer { Task { try? await clientPeer.close() } }

        let dispatcher = PeerDispatcher(peer: clientPeer)

        let expectation = XCTestExpectation(description: "Ping handler called")
        dispatcher.register(Ping.self) { ping, _ in
            XCTAssertEqual(ping.body, "hello")
            expectation.fulfill()
            return Pong(body: "world")
        }

        let serverPeer = try await listenerPeerTask.value
        defer { Task { try? await serverPeer.close() } }

        Task { try? await dispatcher.run() }

        // Server sends a Ping encoded as Matter
        let pingBody = try JSONEncoder().encode(Ping(body: "hello"))
        let pingMatter = Matter.make(behavior: .command, type: Ping.messageType, body: pingBody)
        let replyMatter = try await serverPeer.request(matter: pingMatter)

        await fulfillment(of: [expectation], timeout: 5)

        let replyPayload = try replyMatter.decodePayload()
        let pong = try JSONDecoder().decode(Pong.self, from: replyPayload.body)
        XCTAssertEqual(pong.body, "world")
    }

    func testUnregisteredTypeIsDropped() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let clientPeer = try await Peer.connect(to: listener.address)
        defer { Task { try? await clientPeer.close() } }

        let dispatcher = PeerDispatcher(peer: clientPeer)
        dispatcher.register(Pong.self) { _, _ in nil }

        let runTask = Task { try? await dispatcher.run() }
        defer { runTask.cancel() }

        let serverPeer = try await listenerPeerTask.value
        defer { Task { try? await serverPeer.close() } }

        // Send unregistered Notify — should be dropped silently
        let notifyBody = try JSONEncoder().encode(Notify(text: "ignored"))
        let notifyMatter = Matter.make(behavior: .command, type: Notify.messageType, body: notifyBody)
        serverPeer.fire(matter: notifyMatter)

        try await Task.sleep(for: .milliseconds(100))

        // Dispatcher is still running — send a registered Pong to verify
        let pongBody = try JSONEncoder().encode(Pong(body: "still alive"))
        let pongMatter = Matter.make(behavior: .command, type: Pong.messageType, body: pongBody)
        serverPeer.fire(matter: pongMatter)

        try await Task.sleep(for: .milliseconds(100))
        // Reaching here without crash = pass
    }

    func testHandlerReturningNilSendsNoReply() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let clientPeer = try await Peer.connect(to: listener.address)
        defer { Task { try? await clientPeer.close() } }

        let dispatcher = PeerDispatcher(peer: clientPeer)
        dispatcher.register(Notify.self) { _, _ in nil }

        let runTask = Task { try? await dispatcher.run() }
        defer { runTask.cancel() }

        let serverPeer = try await listenerPeerTask.value
        defer { Task { try? await serverPeer.close() } }

        let notifyBody = try JSONEncoder().encode(Notify(text: "one-way"))
        let notifyMatter = Matter.make(behavior: .command, type: Notify.messageType, body: notifyBody)

        do {
            _ = try await serverPeer.request(matter: notifyMatter, timeout: .milliseconds(200))
            XCTFail("Expected timeout — handler returns nil so no reply")
        } catch NMTPError.timeout {
            // Expected
        }
    }
}
