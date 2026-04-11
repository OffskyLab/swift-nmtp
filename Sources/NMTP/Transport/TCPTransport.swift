@preconcurrency import NIO
import NIOExtras

/// TCP transport with optional application-layer heartbeat.
///
/// This is the default transport used by ``NMTServer`` and ``NMTClient``.
/// It builds the pipeline:
/// ```
/// [TLSHandler]?
/// [ByteToMessageHandler(MatterDecoder)]
/// [MessageToByteHandler(MatterEncoder)]
/// [IdleStateHandler]
/// [HeartbeatHandler]
/// ── applicationPipeline ──
/// [NMTServerInboundHandler / NMTClientInboundHandler]
/// ```
public struct TCPTransport: NMTTransport {
    public let heartbeatInterval: Duration
    public let missedLimit: Int

    public init(
        heartbeatInterval: Duration = .seconds(30),
        missedLimit: Int = 2
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.missedLimit = missedLimit
    }

    // MARK: - Server

    public func buildServerPipeline(
        channel: Channel,
        tls: (any TLSContext)?,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let idleTime = heartbeatInterval.timeAmount
        let limit = missedLimit
        let build: @Sendable (Channel) -> EventLoopFuture<Void> = { ch in
            // channelInitializer is called on the event loop; syncOperations.addHandlers
            // takes [ChannelHandler] (no Sendable requirement) and runs synchronously.
            do {
                try ch.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    IdleStateHandler(readTimeout: idleTime),
                    HeartbeatHandler(missedLimit: limit),
                ])
            } catch {
                return ch.eventLoop.makeFailedFuture(error)
            }
            return applicationPipeline(ch)
        }
        if let tls {
            return addTLSServerHandler(to: channel, tls: tls, then: build)
        } else {
            return build(channel)
        }
    }

    // MARK: - Client

    public func connect(
        to address: SocketAddress,
        tls: (any TLSContext)?,
        elg: any EventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let idleTime = heartbeatInterval.timeAmount
        let limit = missedLimit
        return try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let build: @Sendable (Channel) -> EventLoopFuture<Void> = { ch in
                    do {
                        try ch.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                            IdleStateHandler(readTimeout: idleTime),
                            HeartbeatHandler(missedLimit: limit),
                        ])
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                    return applicationPipeline(ch)
                }
                if let tls {
                    return self.addTLSClientHandler(
                        to: channel, tls: tls, serverHostname: nil, then: build
                    )
                } else {
                    return build(channel)
                }
            }
            .connect(to: address)
            .get()
    }
}
