import NIO

/// Pluggable transport layer for NMT connections.
///
/// Implement this protocol to add a new transport (e.g. WebSocket, QUIC).
/// The default transport is ``TCPTransport``.
///
/// Both methods receive an `applicationPipeline` closure. Call it at the end
/// of your pipeline setup to let ``NMTServer`` or ``NMTClient`` append their
/// own handlers (``NMTServerInboundHandler`` / ``NMTClientInboundHandler``).
public protocol NMTTransport: Sendable {

    /// Configure the server-side NIO pipeline for one accepted child channel.
    /// Called from `ServerBootstrap.childChannelInitializer`.
    func buildServerPipeline(
        channel: Channel,
        tls: (any TLSContext)?,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void>

    /// Create a fully connected client channel.
    /// Implementations run the bootstrap, perform any handshake (e.g. HTTP upgrade),
    /// configure the pipeline, and return the ready channel.
    func connect(
        to address: SocketAddress,
        tls: (any TLSContext)?,
        elg: any EventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel
}

// MARK: - Shared TLS helpers

extension NMTTransport {

    /// Wraps the async TLS server-handler installation into an `EventLoopFuture<Void>`,
    /// then chains `next(channel)`.
    package func addTLSServerHandler(
        to channel: Channel,
        tls: any TLSContext,
        then next: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            let tlsHandler = try await tls.makeServerHandler()
            try await channel.pipeline.addHandler(tlsHandler).get()
            try await next(channel).get()
        }
        return promise.futureResult
    }

    /// Wraps the async TLS client-handler installation into an `EventLoopFuture<Void>`,
    /// then chains `next(channel)`.
    package func addTLSClientHandler(
        to channel: Channel,
        tls: any TLSContext,
        serverHostname: String?,
        then next: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            let tlsHandler = try await tls.makeClientHandler(serverHostname: serverHostname)
            try await channel.pipeline.addHandler(tlsHandler).get()
            try await next(channel).get()
        }
        return promise.futureResult
    }
}
