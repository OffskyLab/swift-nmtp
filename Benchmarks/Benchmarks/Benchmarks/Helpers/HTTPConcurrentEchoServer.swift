import Foundation
import AsyncHTTPClient
import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - HTTPConcurrentEchoServer

/// Extends HTTPEchoServer with a concurrent request helper.
///
/// AsyncHTTPClient already manages a connection pool internally, so the same
/// `HTTPClient` instance can dispatch N concurrent requests.
/// `syncConcurrentRequest` fires N futures simultaneously then blocks on the
/// combined `whenAllSucceed` future — no cooperative thread pool slots consumed.
struct HTTPConcurrentEchoServer: Sendable {
    let url: String
    private let serverChannel: Channel
    private let httpClient: HTTPClient
    private let concurrency: Int

    static func start(concurrency: Int) async throws -> HTTPConcurrentEchoServer {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let serverChannel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPEchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress?.port ?? 0
        let url = "http://127.0.0.1:\(port)/echo"

        // Allow enough connections in the pool to serve all concurrent requests.
        var config = HTTPClient.Configuration()
        config.connectionPool = .init(idleTimeout: .seconds(60), concurrentHTTP1ConnectionsPerHostSoftLimit: concurrency)
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)

        return HTTPConcurrentEchoServer(
            url: url,
            serverChannel: serverChannel,
            httpClient: httpClient,
            concurrency: concurrency
        )
    }

    /// Fires `concurrency` POST requests simultaneously, blocks until all complete.
    func syncConcurrentRequest(body: Data) throws {
        let futures: [EventLoopFuture<HTTPClient.Response>] = (0..<concurrency).map { _ in
            httpClient.execute(
                .POST,
                url: url,
                body: .bytes(body),
                deadline: .now() + .seconds(30)
            )
        }
        _ = try EventLoopFuture.whenAllSucceed(futures, on: httpClient.eventLoopGroup.next()).wait()
    }

    func stop() async throws {
        try await serverChannel.close()
        try await httpClient.shutdown()
    }
}
