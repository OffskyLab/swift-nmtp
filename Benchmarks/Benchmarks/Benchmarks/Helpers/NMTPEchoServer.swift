import Foundation
import NIO
import NMTP

// MARK: - NMTPEchoServer

/// Pairs a direct NIO echo server with a synchronous NIO client.
///
/// The server uses `DirectEchoHandler` (a plain ChannelDuplexHandler) — no Swift
/// `Task { }` — so the measurement loop's `syncRequest()` call blocks the calling
/// thread on an `EventLoopFuture.wait()` without consuming any cooperative thread
/// pool slots.  This sidesteps the release-mode deadlock caused by
/// package-benchmark's `runAsync()` blocking the one cooperative thread that
/// the pool starts with.
struct NMTPEchoServer: Sendable {
    private let serverChannel: Channel
    private let clientChannel: Channel
    private let clientHandler: SyncClientHandler
    private let elg: MultiThreadedEventLoopGroup

    /// Starts the echo server and connects a client.  Runs during benchmark
    /// setUp (before `scaledIterations`), so the cooperative thread is free.
    static func start() async throws -> NMTPEchoServer {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    DirectEchoHandler(),
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let address = serverChannel.localAddress!

        let clientHandler = SyncClientHandler()
        let clientChannel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    clientHandler,
                ])
            }
            .connect(to: address)
            .get()

        return NMTPEchoServer(
            serverChannel: serverChannel,
            clientChannel: clientChannel,
            clientHandler: clientHandler,
            elg: elg
        )
    }

    /// Sends `matter` and blocks the calling thread until the echo reply arrives.
    ///
    /// Safe to call from any non-event-loop thread (including the cooperative
    /// thread running the sync benchmark closure).  NIO handles the round-trip
    /// entirely on NIO threads; no cooperative thread pool slots are consumed.
    func syncRequest(_ matter: Matter) throws -> Matter {
        let promise = clientChannel.eventLoop.makePromise(of: Matter.self)
        clientHandler.register(promise, id: matter.matterID)
        clientChannel.writeAndFlush(matter, promise: nil)
        return try promise.futureResult.wait()
    }

    /// Tears down the client, server, and shared ELG.
    func stop() async throws {
        clientChannel.close(promise: nil)
        try await serverChannel.close().get()
        try await elg.shutdownGracefully()
    }
}

// MARK: - DirectEchoHandler

/// Pure NIO echo handler: receives a Matter, immediately writes back a reply
/// on the same event loop thread — no Swift Task, no cooperative pool usage.
final class DirectEchoHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn  = Matter
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = Matter

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let req = unwrapInboundIn(data)
        let reply = Matter(behavior: .reply, matterID: req.matterID, payload: req.payload)
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - SyncClientHandler

/// Receives reply Matters and fulfills the matching `EventLoopPromise`.
/// Thread-safe: `register` is called from the benchmark thread; `channelRead`
/// is called from a NIO event loop thread.
final class SyncClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Matter

    private let lock = NSLock()
    private var pending: [UUID: EventLoopPromise<Matter>] = [:]

    func register(_ promise: EventLoopPromise<Matter>, id: UUID) {
        lock.lock()
        pending[id] = promise
        lock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reply = unwrapInboundIn(data)
        lock.lock()
        let promise = pending.removeValue(forKey: reply.matterID)
        lock.unlock()
        promise?.succeed(reply)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        let all = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        all.forEach { $0.fail(ChannelError.ioOnClosedChannel) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
