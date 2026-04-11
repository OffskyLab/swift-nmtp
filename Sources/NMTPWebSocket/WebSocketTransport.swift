@preconcurrency import NIO
@preconcurrency import NIOHTTP1
@preconcurrency import NIOWebSocket
import NMTP

/// WebSocket transport for NMT connections.
///
/// Performs an HTTP/1.1 → WebSocket upgrade (RFC 6455) and carries NMT frames
/// as binary WebSocket messages. Import `NMTPWebSocket` to use this transport:
///
/// ```swift
/// import NMTPWebSocket
///
/// let server = try await NMTServer.bind(
///     on: addr, handler: h, transport: WebSocketTransport(path: "/nmt")
/// )
/// let client = try await NMTClient.connect(
///     to: addr, transport: WebSocketTransport(path: "/nmt")
/// )
/// ```
public struct WebSocketTransport: NMTTransport {
    public let path: String

    public init(path: String = "/nmt") {
        self.path = path
    }

    // MARK: - Server

    public func buildServerPipeline(
        channel: Channel,
        tls: (any TLSContext)?,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (ch: Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                guard head.uri == self.path else {
                    return ch.eventLoop.makeSucceededFuture(nil)
                }
                return ch.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (ch: Channel, _: HTTPRequestHead) -> EventLoopFuture<Void> in
                // upgradePipelineHandler is called on the event loop; syncOperations is safe.
                do {
                    try ch.pipeline.syncOperations.addHandlers([
                        NMTWebSocketFrameHandler(isClient: false),
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                    ])
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
                return applicationPipeline(ch)
            }
        )
        if let tls {
            return addTLSServerHandler(to: channel, tls: tls) { ch in
                ch.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }
        } else {
            return channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
            )
        }
    }

    // MARK: - Client

    public func connect(
        to address: SocketAddress,
        tls: (any TLSContext)?,
        elg: any EventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        var upgradeSignalContinuation: AsyncStream<Bool>.Continuation!
        let upgradeSignal = AsyncStream<Bool> { upgradeSignalContinuation = $0 }
        // Capture the continuation as an immutable let so concurrent closures can safely reference it.
        let signalCont: AsyncStream<Bool>.Continuation = upgradeSignalContinuation

        let requestKey = NIOWebSocketClientUpgrader.randomRequestKey()
        let wsPath = path

        let channel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let upgrader = NIOWebSocketClientUpgrader(
                    requestKey: requestKey,
                    upgradePipelineHandler: { (ch: Channel, _: HTTPResponseHead) -> EventLoopFuture<Void> in
                        // upgradePipelineHandler is called on the event loop; syncOperations is safe.
                        do {
                            try ch.pipeline.syncOperations.addHandlers([
                                NMTWebSocketFrameHandler(isClient: true),
                                ByteToMessageHandler(MatterDecoder()),
                                MessageToByteHandler(MatterEncoder()),
                            ])
                        } catch {
                            return ch.eventLoop.makeFailedFuture(error)
                        }
                        return applicationPipeline(ch).map {
                            signalCont.yield(true)
                            signalCont.finish()
                        }
                    }
                )
                // Build config inline at the call site to avoid capturing a non-Sendable tuple.
                if let tls {
                    return self.addTLSClientHandler(
                        to: channel, tls: tls, serverHostname: nil
                    ) { ch in
                        ch.pipeline.addHTTPClientHandlers(withClientUpgrade: (
                            upgraders: [upgrader],
                            completionHandler: { _ in }
                        ))
                    }
                } else {
                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    ))
                }
            }
            .connect(to: address)
            .get()

        // Send the HTTP GET that triggers the WebSocket upgrade handshake.
        let host: String
        switch address {
        case .v4(let addr): host = addr.host
        case .v6(let addr): host = addr.host
        default: host = "localhost"
        }
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        let requestHead = HTTPRequestHead(
            version: .http1_1, method: .GET, uri: wsPath, headers: headers
        )
        // Queue head without flushing so both head and end reach the NIO upgrade handler
        // in the same event-loop turn. A separate writeAndFlush(head) would suspend and
        // yield; if the server returns 101 during that suspension the upgrader rejects
        // the subsequent end write with writingToHandlerDuringUpgrade.
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil as EventLoopPromise<Void>?)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        // Safety net: also signal false if the channel closes before either callback fires.
        channel.closeFuture.whenComplete { _ in
            signalCont.yield(false)
            signalCont.finish()
        }

        // Wait for upgrade result.
        var upgradeSucceeded = false
        for await success in upgradeSignal {
            upgradeSucceeded = success
            break
        }

        guard upgradeSucceeded else {
            throw NMTPError.fail(
                message: "WebSocket upgrade rejected: server closed connection without upgrading"
            )
        }

        return channel
    }
}
