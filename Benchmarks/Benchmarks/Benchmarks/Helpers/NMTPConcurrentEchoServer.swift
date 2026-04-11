import Foundation
import NIOCore
import NIOPosix
import NMTP

// MARK: - NMTPConcurrentEchoServer

/// Like NMTPEchoServer but with N independent client channels connected to the
/// same server.  `syncConcurrentRequest` dispatches one request per client
/// simultaneously and blocks until all N replies arrive — measuring true
/// concurrent throughput without consuming cooperative thread pool slots.
struct NMTPConcurrentEchoServer: Sendable {
    private let serverChannel: Channel
    private let clients: [(Channel, SyncClientHandler)]
    private let elg: MultiThreadedEventLoopGroup

    static func start(concurrency: Int) async throws -> NMTPConcurrentEchoServer {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

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

        var clients: [(Channel, SyncClientHandler)] = []
        for _ in 0..<concurrency {
            let handler = SyncClientHandler()
            let channel = try await ClientBootstrap(group: elg)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { ch in
                    ch.pipeline.addHandlers([
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                        handler,
                    ])
                }
                .connect(to: address)
                .get()
            clients.append((channel, handler))
        }

        return NMTPConcurrentEchoServer(
            serverChannel: serverChannel,
            clients: clients,
            elg: elg
        )
    }

    /// Sends one request per client channel concurrently, then blocks until all
    /// N replies have arrived.  Uses `EventLoopFuture.whenAllSucceed` to combine
    /// the promises — no cooperative thread pool slots consumed.
    func syncConcurrentRequest(body: Data) throws {
        let futures: [EventLoopFuture<Matter>] = clients.map { (channel, handler) in
            let matter = Matter(behavior: .command, payload: body)
            let promise = channel.eventLoop.makePromise(of: Matter.self)
            handler.register(promise, id: matter.matterID)
            channel.writeAndFlush(matter, promise: nil)
            return promise.futureResult
        }
        _ = try EventLoopFuture.whenAllSucceed(futures, on: elg.next()).wait()
    }

    func stop() async throws {
        for (channel, _) in clients {
            channel.close(promise: nil)
        }
        try await serverChannel.close().get()
        try await elg.shutdownGracefully()
    }
}
