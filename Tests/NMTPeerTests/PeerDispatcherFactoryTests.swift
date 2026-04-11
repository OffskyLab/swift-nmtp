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
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let clientDispatcher = try await PeerDispatcher.connect(to: listener.address)
        defer { Task { try? await clientDispatcher.peer.close() } }

        let serverPeer = try await listenerPeerTask.value
        defer { Task { try? await serverPeer.close() } }

        let serverDispatcher = PeerDispatcher(peer: serverPeer)
        serverDispatcher.register(FactoryPing.self) { ping, _ in
            XCTAssertEqual(ping.body, "hello")
            return FactoryPong(body: "world")
        }

        let runTask = Task {
            async let clientRun: Void = { try await clientDispatcher.run() }()
            async let serverRun: Void = { try await serverDispatcher.run() }()
            _ = try await (clientRun, serverRun)
        }
        defer { runTask.cancel() }

        let reply = try await clientDispatcher.request(
            FactoryPing(body: "hello"),
            expecting: FactoryPong.self,
            timeout: .seconds(1)
        )

        XCTAssertEqual(reply.body, "world")
    }

    func testListenFactoryHandlesTypedRequestFromDispatcherClient() async throws {
        let listener = try await PeerDispatcher.listen(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        ) { dispatcher in
            dispatcher.register(FactoryPing.self) { ping, _ in
                XCTAssertEqual(ping.body, "client")
                return FactoryPong(body: "listener")
            }
        }
        defer { Task { try? await listener.close() } }

        let listenTask = Task { try? await listener.run() }
        defer { listenTask.cancel() }

        let clientDispatcher = try await PeerDispatcher.connect(to: listener.address)
        defer { Task { try? await clientDispatcher.peer.close() } }

        let reply = try await clientDispatcher.request(
            FactoryPing(body: "client"),
            expecting: FactoryPong.self,
            timeout: .seconds(1)
        )

        XCTAssertEqual(reply.body, "listener")
    }
}
