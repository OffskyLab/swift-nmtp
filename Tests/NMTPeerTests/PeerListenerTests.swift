import XCTest
import NIO
import NMTP
@testable import NMTPeer

final class PeerListenerTests: XCTestCase {

    func testSymmetricRoundTrip() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let connector = try await Peer.connect(to: listener.address)
        defer { Task { try? await connector.close() } }

        // Connector echoes back any incoming matter (listener will call request)
        let echoTask = Task {
            for await matter in connector.incoming {
                connector.fire(matter: Matter(
                    behavior: .reply,
                    matterID: matter.matterID,
                    payload: matter.payload
                ))
            }
        }
        defer { echoTask.cancel() }

        let lPeer = try await listenerPeerTask.value

        let matter = Matter(behavior: .query, payload: Data("symmetric".utf8))
        let reply = try await lPeer.request(matter: matter)

        XCTAssertEqual(reply.matterID, matter.matterID)
        XCTAssertEqual(reply.payload, Data("symmetric".utf8))
    }

    func testClosePropagates() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )
        defer { Task { try? await listener.close() } }

        let listenerPeerTask = Task<Peer, Error> {
            for await peer in listener.peers { return peer }
            throw NMTPError.connectionClosed
        }

        let connector = try await Peer.connect(to: listener.address)
        defer { Task { try? await connector.close() } }
        let lPeer = try await listenerPeerTask.value

        try await connector.close()

        var count = 0
        for await _ in lPeer.incoming { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testListenerCloseTerminatesPeersStream() async throws {
        let listener = try await PeerListener.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0)
        )

        // Collect peers in background
        let collectTask = Task<Int, Error> {
            var count = 0
            for await _ in listener.peers { count += 1 }
            return count
        }

        // Close listener without accepting any peers
        try await listener.close()

        let count = try await collectTask.value
        XCTAssertEqual(count, 0)
    }
}
