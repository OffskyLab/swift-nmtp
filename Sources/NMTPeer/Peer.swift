import NIO
import NMTP

/// A single established P2P connection. Both sides have the same API regardless of
/// which side initiated the connection.
public final class Peer: Sendable {
    /// Remote address of this connection.
    public let remoteAddress: SocketAddress
    /// Unsolicited inbound Matters — those not matching any pending `request`.
    public let incoming: MatterStream

    private let channel: Channel
    private let pendingRequests: PendingRequests
    private let incomingContinuation: AsyncStream<Matter>.Continuation
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?

    init(
        channel: Channel,
        pendingRequests: PendingRequests,
        incoming: MatterStream,
        incomingContinuation: AsyncStream<Matter>.Continuation,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    ) {
        guard let addr = channel.remoteAddress else {
            preconditionFailure("Peer.init called with a channel that has no remoteAddress")
        }
        self.remoteAddress = addr
        self.channel = channel
        self.pendingRequests = pendingRequests
        self.incoming = incoming
        self.incomingContinuation = incomingContinuation
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }
}

// MARK: - Connect

extension Peer {
    public static func connect(
        to address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> Peer {
        let owned = eventLoopGroup == nil
            ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let pendingRequests = PendingRequests()
        var cont: AsyncStream<Matter>.Continuation!
        let incomingStream = AsyncStream<Matter> { cont = $0 }
        let inboundHandler = PeerInboundHandler(
            pendingRequests: pendingRequests,
            incomingContinuation: cont
        )
        do {
            let channel = try await transport.connect(
                to: address,
                tls: tls,
                elg: elg,
                applicationPipeline: { ch in
                    ch.pipeline.addHandler(inboundHandler)
                }
            )
            return Peer(
                channel: channel,
                pendingRequests: pendingRequests,
                incoming: MatterStream(incomingStream),
                incomingContinuation: cont,
                ownedEventLoopGroup: owned
            )
        } catch {
            try? await owned?.shutdownGracefully()
            throw error
        }
    }
}

// MARK: - Send / Receive

extension Peer {
    public func fire(matter: Matter) {
        channel.writeAndFlush(matter, promise: nil)
    }

    public func request(
        matter: Matter,
        timeout: Duration = .seconds(30)
    ) async throws -> Matter {
        return try await withThrowingTaskGroup(of: Matter.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.pendingRequests.register(id: matter.matterID, continuation: continuation)
                        self.channel.writeAndFlush(matter, promise: nil)
                    }
                } onCancel: {
                    self.pendingRequests.fail(id: matter.matterID, error: NMTPError.timeout)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NMTPError.timeout
            }
            guard let result = try await group.next() else {
                preconditionFailure("Task group unexpectedly empty — both tasks were added above")
            }
            group.cancelAll()
            return result
        }
    }

    public func close() async throws {
        try await channel.close().get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }
}
