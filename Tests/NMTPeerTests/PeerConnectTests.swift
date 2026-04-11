import XCTest
import NIO
import NMTP
@testable import NMTPeer

final class PeerConnectTests: XCTestCase {

    func testRequestRoundTrip() async throws {
        // Use NMTServer as the remote end — Peer.connect is the client side
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )
        defer { server.closeNow() }

        let peer = try await Peer.connect(to: server.address)
        defer { Task { try? await peer.close() } }

        let matter = Matter(behavior: .command, payload: Data("hello".utf8))
        let reply = try await peer.request(matter: matter)

        XCTAssertEqual(reply.matterID, matter.matterID)
        XCTAssertEqual(reply.behavior, .reply)
        XCTAssertEqual(reply.payload, Data("hello".utf8))
    }

    func testIncomingReceivesUnsolicitedMatter() async throws {
        let pushPayload = Data("pushed".utf8)

        struct PushHandler: NMTHandler {
            let pushPayload: Data
            func handle(matter: Matter, channel: Channel) async throws -> Matter? {
                channel.writeAndFlush(Matter(behavior: .reply, payload: pushPayload), promise: nil)
                return nil
            }
        }

        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: PushHandler(pushPayload: pushPayload)
        )
        defer { server.closeNow() }

        let peer = try await Peer.connect(to: server.address)
        defer { Task { try? await peer.close() } }

        peer.fire(matter: Matter(behavior: .command, payload: Data()))

        let received = try await withThrowingTaskGroup(of: Matter?.self) { group in
            group.addTask {
                for await m in peer.incoming { return m }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.payload, pushPayload)
    }
}

private struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(behavior: .reply, matterID: matter.matterID, payload: matter.payload)
    }
}
