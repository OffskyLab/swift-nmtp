import NIO
import NMTP

/// Binds to a local address and produces one Peer per accepted connection.
public final class PeerListener: Sendable {
    /// Local address this listener is bound to.
    public let address: SocketAddress
    /// Async sequence of accepted peer connections.
    public let peers: PeerStream

    private let channel: Channel
    private let peersContinuation: AsyncStream<Peer>.Continuation
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?

    init(
        address: SocketAddress,
        channel: Channel,
        peers: PeerStream,
        peersContinuation: AsyncStream<Peer>.Continuation,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    ) {
        self.address = address
        self.channel = channel
        self.peers = peers
        self.peersContinuation = peersContinuation
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }
}

// MARK: - Bind

extension PeerListener {
    public static func bind(
        on address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> PeerListener {
        let owned = eventLoopGroup == nil
            ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!

        var peersCont: AsyncStream<Peer>.Continuation!
        let peersStream = AsyncStream<Peer> { peersCont = $0 }
        let capturedCont = peersCont!

        let serverChannel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                transport.buildServerPipeline(
                    channel: childChannel,
                    tls: tls,
                    applicationPipeline: { ch in
                        let pendingRequests = PendingRequests()
                        var incomingCont: AsyncStream<Matter>.Continuation!
                        let incomingStream = AsyncStream<Matter> { incomingCont = $0 }
                        let handler = PeerInboundHandler(
                            pendingRequests: pendingRequests,
                            incomingContinuation: incomingCont
                        )
                        let peer = Peer(
                            channel: ch,
                            pendingRequests: pendingRequests,
                            incoming: MatterStream(incomingStream),
                            incomingContinuation: incomingCont,
                            ownedEventLoopGroup: nil  // listener owns the ELG, not the peer
                        )
                        capturedCont.yield(peer)
                        return ch.pipeline.addHandler(handler)
                    }
                )
            }
            .bind(to: address)
            .get()

        return PeerListener(
            address: serverChannel.localAddress ?? address,
            channel: serverChannel,
            peers: PeerStream(peersStream),
            peersContinuation: peersCont,
            ownedEventLoopGroup: owned
        )
    }
}

// MARK: - Close

extension PeerListener {
    /// Stop accepting new connections. Already-accepted peers are unaffected.
    public func close() async throws {
        peersContinuation.finish()
        try await channel.close().get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }
}
