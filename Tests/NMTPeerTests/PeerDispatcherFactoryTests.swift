import XCTest
import NIO
import NMTP
@testable import NMTPeer

private struct FactoryPing: PeerMessage {
    static let messageType: UInt16 = 0x0101
    let body: String
}

private struct FactoryPong: PeerMessage {
    static let messageType: UInt16 = 0x0102
    let body: String
}

final class PeerDispatcherFactoryTests: XCTestCase {

    func testConnectFactoryHandlesTypedRequest() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let clientDispatcher = try await PeerDispatcher.connect(to: listener.address)
        let serverPeer = try await listenerPeerTask.value

        let serverDispatcher = PeerDispatcher(peer: serverPeer)
        serverDispatcher.register(FactoryPing.self) { ping, _ in
            XCTAssertEqual(ping.body, "hello")
            return FactoryPong(body: "world")
        }

        let runTask = Task {
            async let clientRun: Void = { _ = try? await clientDispatcher.run() }()
            async let serverRun: Void = { _ = try? await serverDispatcher.run() }()
            _ = await (clientRun, serverRun)
        }

        let reply = try await clientDispatcher.request(
            FactoryPing(body: "hello"),
            expecting: FactoryPong.self,
            timeout: .seconds(1)
        )
        XCTAssertEqual(reply.body, "world")

        // Explicit ordered cleanup
        runTask.cancel()
        try? await clientDispatcher.peer.close()
        try? await serverPeer.close()
        try? await listener.close()
    }

    func testListenFactoryHandlesTypedRequestFromDispatcherClient() async throws {
        let serverListener = try await PeerDispatcher.listen(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        ) { dispatcher in
            dispatcher.register(FactoryPing.self) { ping, _ in
                XCTAssertEqual(ping.body, "client")
                return FactoryPong(body: "listener")
            }
        }

        let listenTask = Task { try? await serverListener.run() }

        let clientDispatcher = try await PeerDispatcher.connect(to: serverListener.address)

        let reply = try await clientDispatcher.request(
            FactoryPing(body: "client"),
            expecting: FactoryPong.self,
            timeout: .seconds(1)
        )
        XCTAssertEqual(reply.body, "listener")

        // Explicit ordered cleanup
        listenTask.cancel()
        try? await clientDispatcher.peer.close()
        try? await serverListener.close()
    }
}
