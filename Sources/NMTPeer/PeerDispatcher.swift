import Foundation
import NIO
import NMTP
import Synchronization

/// Typed dispatch layer over a `Peer`. Handles decode → route → handler → reply.
public final class PeerDispatcher: Sendable {

    /// Underlying plumbing connection.
    public let peer: Peer

    private let handlers = Mutex<[UInt16: @Sendable (Matter, Data, Peer) async throws -> Void]>([:])

    public init(peer: Peer) {
        self.peer = peer
    }
}

// MARK: - Register

extension PeerDispatcher {

    public func register<M: PeerMessage>(
        _ type: M.Type,
        handler: @escaping @Sendable (M, Peer) async throws -> (any PeerMessage)?
    ) {
        let wrapped: @Sendable (Matter, Data, Peer) async throws -> Void = { matter, body, peer in
            let message = try JSONDecoder().decode(M.self, from: body)
            guard let reply = try await handler(message, peer) else { return }
            let replyBody = try JSONEncoder().encode(reply)
            let replyMatter = Matter.make(
                behavior: .reply,
                type: reply.messageType,
                body: replyBody,
                matterID: matter.matterID
            )
            peer.fire(matter: replyMatter)
        }
        handlers.withLock { $0[M.messageType] = wrapped }
    }
}

// MARK: - Run

extension PeerDispatcher {

    /// Run the dispatch loop. Returns when the connection closes.
    public func run() async throws {
        await withTaskGroup(of: Void.self) { group in
            for await matter in peer.incoming {
                let payload: MatterPayload
                do {
                    payload = try matter.decodePayload()
                } catch {
                    continue
                }
                let handler = handlers.withLock { $0[payload.type] }
                guard let handler else { continue }
                let m = matter
                let body = payload.body
                let p = peer
                group.addTask {
                    do { try await handler(m, body, p) } catch { }
                }
            }
            group.cancelAll()
        }
    }
}

// MARK: - Typed request

extension PeerDispatcher {

    /// Send a typed request and await a typed reply.
    public func request<M: PeerMessage, R: PeerMessage>(
        _ message: M,
        expecting: R.Type,
        timeout: Duration = .seconds(30)
    ) async throws -> R {
        let body = try JSONEncoder().encode(message)
        let matter = Matter.make(behavior: .command, type: M.messageType, body: body)
        let replyMatter = try await peer.request(matter: matter, timeout: timeout)
        let replyPayload = try replyMatter.decodePayload()
        guard replyPayload.type == R.messageType else {
            throw NMTPError.unexpectedReplyType(expected: R.messageType, actual: replyPayload.type)
        }
        return try JSONDecoder().decode(R.self, from: replyPayload.body)
    }
}

// MARK: - Simplified factories

extension PeerDispatcher {
    public static func connect(
        to address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> PeerDispatcher {
        let peer = try await Peer.connect(
            to: address,
            tls: tls,
            transport: transport,
            eventLoopGroup: eventLoopGroup
        )
        return PeerDispatcher(peer: peer)
    }

    public static func listen(
        on address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil,
        configure: @escaping @Sendable (PeerDispatcher) -> Void
    ) async throws -> PeerDispatcherListener {
        let listener = try await PeerListener.bind(
            on: address,
            tls: tls,
            transport: transport,
            eventLoopGroup: eventLoopGroup
        )
        return PeerDispatcherListener(listener: listener, configure: configure)
    }
}
