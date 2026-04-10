import Foundation
import AsyncHTTPClient
import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - HTTPEchoServer

/// Pairs a raw NIO HTTP/1.1 echo server with an AsyncHTTPClient.
///
/// The server uses dedicated NIO event loop threads — no Swift `Task { }` —
/// so the sync benchmark closure can call `syncRequest()` which blocks the
/// calling thread on `EventLoopFuture.wait()` without touching the cooperative
/// thread pool.
struct HTTPEchoServer: Sendable {
    let url: String
    private let serverChannel: Channel
    private let httpClient: HTTPClient

    /// Starts the NIO HTTP/1.1 echo server and creates an AsyncHTTPClient.
    static func start() async throws -> HTTPEchoServer {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)

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

        // AsyncHTTPClient manages its own event loop group via .singleton.
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        return HTTPEchoServer(url: url, serverChannel: serverChannel, httpClient: httpClient)
    }

    /// Sends `body` as a POST and blocks the calling thread until the echo response arrives.
    ///
    /// Uses the legacy EventLoopFuture-based API so the block is a plain OS-level
    /// ConditionLock.wait() — no cooperative thread pool slot consumed.
    func syncRequest(body: Data) throws -> Data {
        let response = try httpClient.execute(
            .POST,
            url: url,
            body: .bytes(body),
            deadline: .now() + .seconds(30)
        ).wait()
        guard var buf = response.body else { return Data() }
        return Data(buf.readBytes(length: buf.readableBytes) ?? [])
    }

    /// Tears down the server and HTTP client.
    func stop() async throws {
        try await serverChannel.close()
        try await httpClient.shutdown()
    }
}

// MARK: - HTTPEchoHandler

/// NIO channel handler: accumulates the full HTTP/1.1 request body, then
/// writes back a 200 response with the same body — all on the NIO thread.
final class HTTPEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestBody: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            requestBody?.writeBuffer(&chunk)
        case .end:
            let body = requestBody ?? ByteBuffer()
            requestBody = nil

            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "\(body.readableBytes)")
            headers.add(name: "content-type", value: "application/octet-stream")

            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
