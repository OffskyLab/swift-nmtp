# NMTPWebSocket Target Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract all WebSocket transport code from the `NMTP` target into a new `NMTPWebSocket` target, replacing the `NMTTransport` enum with a Swift protocol so users only pay for the dependencies they actually use.

**Architecture:** `NMTTransport` becomes a protocol; `TCPTransport` (in `NMTP`) and `WebSocketTransport` (in `NMTPWebSocket`) implement it. `NMTServer.bind` and `NMTClient.connect` take `any NMTTransport = TCPTransport()`. Each transport owns its full pipeline-build and connect logic; `NMTServer`/`NMTClient` pass a single `applicationPipeline` closure that appends the NMT handler at the end.

**Tech Stack:** Swift 6, SwiftNIO 2, NIOWebSocket (NMTPWebSocket only), XCTest

---

## File Map

| Action | Path |
|--------|------|
| Modify | `Package.swift` |
| Modify | `Sources/NMTP/Transport/NMTTransport.swift` — enum → protocol + TLS helpers |
| Create | `Sources/NMTP/Transport/TCPTransport.swift` |
| Create | `Sources/NMTPWebSocket/NMTWebSocketFrameHandler.swift` |
| Create | `Sources/NMTPWebSocket/WebSocketTransport.swift` |
| Modify | `Sources/NMTP/NMT/NMTServer.swift` |
| Modify | `Sources/NMTP/NMT/NMTClient.swift` |
| Modify | `Tests/NMTPTests/WebSocketTransportTests.swift` — keep only TCPTransport tests |
| Modify | `Tests/NMTPTests/NMTIntegrationTests.swift` — update heartbeat tests |
| Create | `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift` |
| Delete | `Sources/NMTP/Transport/WebSocketFrameHandler.swift` (Task 4) |
| Modify | `CLAUDE.md` |

---

### Task 1: Scaffold NMTPWebSocket in Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Sources/NMTPWebSocket/WebSocketTransport.swift` (stub)
- Create: `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift` (stub)

- [ ] **Step 1: Create stub source file for NMTPWebSocket target**

Create `Sources/NMTPWebSocket/WebSocketTransport.swift` with just an import so the target compiles:

```swift
import NIO
```

- [ ] **Step 2: Create stub test file for NMTPWebSocketTests target**

Create `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift`:

```swift
import XCTest
```

- [ ] **Step 3: Update Package.swift**

Replace the entire file:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-nmtp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NMTP", targets: ["NMTP"]),
        .library(name: "NMTPWebSocket", targets: ["NMTPWebSocket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.40.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.10.0"),
        .package(url: "https://github.com/hirotakan/MessagePacker.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NMTP", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),       // removed in Task 2
            .product(name: "NIOWebSocket", package: "swift-nio"),   // removed in Task 2
            .product(name: "NIOExtras", package: "swift-nio-extras"),
            .product(name: "MessagePacker", package: "MessagePacker"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "NMTPWebSocket", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPTests", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),   // removed in Task 2
        ]),
        .testTarget(name: "NMTPWebSocketTests", dependencies: [
            "NMTPWebSocket",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
    ]
)
```

- [ ] **Step 4: Verify build**

```bash
swift build
```

Expected: Build succeeded. Both `NMTP` and `NMTPWebSocket` targets compile.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/NMTPWebSocket/WebSocketTransport.swift Tests/NMTPWebSocketTests/WebSocketTransportTests.swift
git commit -m "[ADD] Scaffold NMTPWebSocket target and test target in Package.swift"
```

---

### Task 2: NMTTransport protocol + TCPTransport + refactor NMTServer/NMTClient

**Context:** This is the core refactor. `NMTTransport` changes from an enum to a protocol. `TCPTransport` takes over all TCP pipeline logic (including heartbeat). `NMTServer.bind` and `NMTClient.connect` gain `transport: any NMTTransport = TCPTransport()` and lose the `heartbeatInterval`/`heartbeatMissedLimit` parameters. The WebSocket-specific code stays in NMTServer/NMTClient for now (the `import NIOHTTP1` lines remain until we remove the `NMTWebSocketFrameHandler` reference in Task 3 — wait, actually Task 2 removes the switch-on-enum entirely, so NMTServer/NMTClient won't reference NIOHTTP1/NIOWebSocket anymore. Delete those imports here.

**Files:**
- Modify: `Tests/NMTPTests/WebSocketTransportTests.swift`
- Modify: `Tests/NMTPTests/NMTIntegrationTests.swift`
- Modify: `Sources/NMTP/Transport/NMTTransport.swift`
- Create: `Sources/NMTP/Transport/TCPTransport.swift`
- Modify: `Sources/NMTP/NMT/NMTServer.swift`
- Modify: `Sources/NMTP/NMT/NMTClient.swift`
- Modify: `Package.swift` (remove NIOHTTP1/NIOWebSocket from NMTP + NMTPTests)

- [ ] **Step 1: Rewrite WebSocketTransportTests.swift — TCPTransport unit tests only**

The current file tests the old enum cases; those are replaced. Delete the WS-specific integration tests and frame-handler tests from this file (they'll move to NMTPWebSocketTests in Task 3). Keep only NMTTransportTests, now testing TCPTransport.

Replace the entire contents of `Tests/NMTPTests/WebSocketTransportTests.swift`:

```swift
import XCTest
@testable import NMTP

final class NMTTransportTests: XCTestCase {

    func testTCPTransportDefaultParams() {
        let t = TCPTransport()
        XCTAssertEqual(t.heartbeatInterval, .seconds(30))
        XCTAssertEqual(t.missedLimit, 2)
    }

    func testTCPTransportCustomParams() {
        let t = TCPTransport(heartbeatInterval: .milliseconds(100), missedLimit: 5)
        XCTAssertEqual(t.heartbeatInterval, .milliseconds(100))
        XCTAssertEqual(t.missedLimit, 5)
    }

    func testTCPTransportConformsToNMTTransport() {
        // Compiler-verified: if this compiles, TCPTransport satisfies the protocol.
        let _: any NMTTransport = TCPTransport()
    }
}
```

- [ ] **Step 2: Update heartbeat tests in NMTIntegrationTests.swift**

The heartbeat tests pass `heartbeatInterval:` and `heartbeatMissedLimit:` as top-level params. Change them to use `transport: TCPTransport(heartbeatInterval:missedLimit:)`.

In `Tests/NMTPTests/NMTIntegrationTests.swift`, find `testClientDetectsDeadConnectionViaHeartbeat` and replace the `NMTClient.connect` call:

```swift
// OLD:
let client = try await NMTClient.connect(
    to: silentServer.localAddress!,
    heartbeatInterval: .milliseconds(50),
    heartbeatMissedLimit: 2,
    eventLoopGroup: elg
)

// NEW:
let client = try await NMTClient.connect(
    to: silentServer.localAddress!,
    transport: TCPTransport(heartbeatInterval: .milliseconds(50), missedLimit: 2),
    eventLoopGroup: elg
)
```

Also in `testHeartbeatDoesNotDisruptNormalTraffic`, replace the `NMTClient.connect` call:

```swift
// OLD:
let client = try await NMTClient.connect(
    to: server.address,
    heartbeatInterval: .milliseconds(30)
)

// NEW:
let client = try await NMTClient.connect(
    to: server.address,
    transport: TCPTransport(heartbeatInterval: .milliseconds(30))
)
```

- [ ] **Step 3: Run tests — confirm they fail**

```bash
swift test --filter NMTPTests
```

Expected: Compile error — `TCPTransport` not found; `NMTClient.connect` has no `transport:` param yet.

- [ ] **Step 4: Replace NMTTransport.swift with the protocol**

Replace the entire contents of `Sources/NMTP/Transport/NMTTransport.swift`:

```swift
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
        elg: MultiThreadedEventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel
}

// MARK: - Shared TLS helpers

extension NMTTransport {

    /// Wraps the async TLS server-handler installation into an `EventLoopFuture<Void>`,
    /// then chains `next(channel)`.
    func addTLSServerHandler(
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
    func addTLSClientHandler(
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
```

- [ ] **Step 5: Create TCPTransport.swift**

Create `Sources/NMTP/Transport/TCPTransport.swift`:

```swift
import NIO
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
            ch.pipeline.addHandlers([
                ByteToMessageHandler(MatterDecoder()),
                MessageToByteHandler(MatterEncoder()),
                IdleStateHandler(readTimeout: idleTime),
                HeartbeatHandler(missedLimit: limit),
            ]).flatMap { applicationPipeline(ch) }
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
        elg: MultiThreadedEventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let idleTime = heartbeatInterval.timeAmount
        let limit = missedLimit
        return try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let build: @Sendable (Channel) -> EventLoopFuture<Void> = { ch in
                    ch.pipeline.addHandlers([
                        ByteToMessageHandler(MatterDecoder()),
                        MessageToByteHandler(MatterEncoder()),
                        IdleStateHandler(readTimeout: idleTime),
                        HeartbeatHandler(missedLimit: limit),
                    ]).flatMap { applicationPipeline(ch) }
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
```

- [ ] **Step 6: Refactor NMTServer.swift**

Replace the entire contents of `Sources/NMTP/NMT/NMTServer.swift`. Key changes:
- Remove `import NIOHTTP1` and `import NIOWebSocket`
- `bind` loses `heartbeatInterval`/`heartbeatMissedLimit`; gains `transport: any NMTTransport = TCPTransport()`
- `childChannelInitializer` calls `transport.buildServerPipeline(...)` with an `applicationPipeline` that adds only `NMTServerInboundHandler`
- Delete `buildTCPServerPipeline` and `buildWebSocketServerPipeline`

```swift
import Logging
import NIO
import Synchronization

// MARK: - ServerState

final class ServerState: Sendable {
    private struct Box {
        var inflightCount = 0
        var isShuttingDown = false
        var drainContinuation: CheckedContinuation<Void, Never>?
    }
    private let box = Mutex<Box>(Box())

    var isShuttingDown: Bool { box.withLock { $0.isShuttingDown } }

    func beginShutdown() { box.withLock { $0.isShuttingDown = true } }

    func incrementInflight() { box.withLock { $0.inflightCount += 1 } }

    func decrementInflight() {
        box.withLock { b in
            b.inflightCount -= 1
            if b.inflightCount == 0, let cont = b.drainContinuation {
                b.drainContinuation = nil
                cont.resume()
            }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            box.withLock { b in
                if b.inflightCount == 0 {
                    continuation.resume()
                } else {
                    b.drainContinuation = continuation
                }
            }
        }
    }
}

// MARK: - NMTServer

public final class NMTServer: Sendable {
    public let address: SocketAddress
    private let channel: Channel
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    private let serverState: ServerState

    internal init(
        address: SocketAddress,
        channel: Channel,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?,
        serverState: ServerState
    ) {
        self.address = address
        self.channel = channel
        self.ownedEventLoopGroup = ownedEventLoopGroup
        self.serverState = serverState
    }
}

// MARK: - Bind

extension NMTServer {
    public static func bind(
        on address: SocketAddress,
        handler: any NMTHandler,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTServer {
        let owned = eventLoopGroup == nil
            ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let serverState = ServerState()
        let channel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                transport.buildServerPipeline(
                    channel: channel,
                    tls: tls,
                    applicationPipeline: { ch in
                        ch.pipeline.addHandler(
                            NMTServerInboundHandler(handler: handler, serverState: serverState)
                        )
                    }
                )
            }
            .bind(to: address)
            .get()
        let boundAddress = channel.localAddress ?? address
        return NMTServer(
            address: boundAddress,
            channel: channel,
            ownedEventLoopGroup: owned,
            serverState: serverState
        )
    }
}

// MARK: - Listen / Stop / Shutdown

extension NMTServer {
    public func listen() async throws {
        try await channel.closeFuture.get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }

    public func stop() async throws {
        try await channel.close().get()
        try await ownedEventLoopGroup?.shutdownGracefully()
    }

    public func closeNow() {
        channel.close(promise: nil)
    }

    public func shutdown(gracePeriod: Duration = .seconds(30)) async {
        serverState.beginShutdown()
        try? await channel.close().get()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.serverState.drain() }
            group.addTask { try? await Task.sleep(for: gracePeriod) }
            await group.next()
            group.cancelAll()
        }
        try? await ownedEventLoopGroup?.shutdownGracefully()
    }
}

// MARK: - Server-side Inbound Handler

private final class NMTServerInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter
    typealias OutboundOut = Matter
    private let handler: any NMTHandler
    private let serverState: ServerState
    private let logger = Logger(label: "nmtp.server")

    init(handler: any NMTHandler, serverState: ServerState) {
        self.handler = handler
        self.serverState = serverState
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if serverState.isShuttingDown {
            context.close(promise: nil)
            return
        }
        let matter = unwrapInboundIn(data)
        let channel = context.channel
        serverState.incrementInflight()
        Task {
            defer { serverState.decrementInflight() }
            do {
                if let reply = try await handler.handle(matter: matter, channel: channel) {
                    channel.writeAndFlush(reply, promise: nil)
                }
            } catch {
                logger.error("handler error: \(error)")
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
```

- [ ] **Step 7: Refactor NMTClient.swift**

Replace the entire contents of `Sources/NMTP/NMT/NMTClient.swift`. Key changes:
- Remove `import Foundation`, `import NIOHTTP1`, `import NIOWebSocket`
- `connect` loses `heartbeatInterval`/`heartbeatMissedLimit`; gains `transport: any NMTTransport = TCPTransport()`
- Body calls `transport.connect(to:tls:elg:applicationPipeline:)` directly
- Delete `connectTCP` and `connectWebSocket` private methods

```swift
import NIO

public final class NMTClient: Sendable {
    public let targetAddress: SocketAddress
    public let pushes: AsyncStream<Matter>

    private let channel: Channel
    private let pendingRequests: PendingRequests
    private let pushContinuation: AsyncStream<Matter>.Continuation
    private let ownedEventLoopGroup: MultiThreadedEventLoopGroup?

    internal init(
        targetAddress: SocketAddress,
        channel: Channel,
        pendingRequests: PendingRequests,
        pushes: AsyncStream<Matter>,
        pushContinuation: AsyncStream<Matter>.Continuation,
        ownedEventLoopGroup: MultiThreadedEventLoopGroup?
    ) {
        self.targetAddress = targetAddress
        self.channel = channel
        self.pendingRequests = pendingRequests
        self.pushes = pushes
        self.pushContinuation = pushContinuation
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }
}

// MARK: - Connect

extension NMTClient {
    public static func connect(
        to address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTClient {
        let owned = eventLoopGroup == nil
            ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let pendingRequests = PendingRequests()
        var cont: AsyncStream<Matter>.Continuation!
        let pushes = AsyncStream<Matter> { cont = $0 }
        let inboundHandler = NMTClientInboundHandler(
            pendingRequests: pendingRequests, pushContinuation: cont
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
            return NMTClient(
                targetAddress: address,
                channel: channel,
                pendingRequests: pendingRequests,
                pushes: pushes,
                pushContinuation: cont,
                ownedEventLoopGroup: owned
            )
        } catch {
            try? await owned?.shutdownGracefully()
            throw error
        }
    }
}

// MARK: - Send

extension NMTClient {
    public func fire(matter: Matter) {
        channel.writeAndFlush(matter, promise: nil)
    }

    public func request(matter: Matter, timeout: Duration = .seconds(30)) async throws -> Matter {
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

// MARK: - Inbound Handler

private final class NMTClientInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Matter
    private let pendingRequests: PendingRequests
    private let pushContinuation: AsyncStream<Matter>.Continuation

    init(pendingRequests: PendingRequests, pushContinuation: AsyncStream<Matter>.Continuation) {
        self.pendingRequests = pendingRequests
        self.pushContinuation = pushContinuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let matter = unwrapInboundIn(data)
        if !pendingRequests.fulfill(matter) {
            pushContinuation.yield(matter)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pendingRequests.failAll(error: NMTPError.connectionClosed)
        pushContinuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pendingRequests.failAll(error: error)
        context.close(promise: nil)
    }
}
```

- [ ] **Step 8: Update Package.swift — remove NIOHTTP1/NIOWebSocket from NMTP and NMTPTests**

`NMTServer.swift` and `NMTClient.swift` no longer import NIOHTTP1 or NIOWebSocket. Remove them from the NMTP target deps and NMTPTests test target deps:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-nmtp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NMTP", targets: ["NMTP"]),
        .library(name: "NMTPWebSocket", targets: ["NMTPWebSocket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.40.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.10.0"),
        .package(url: "https://github.com/hirotakan/MessagePacker.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NMTP", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
            .product(name: "MessagePacker", package: "MessagePacker"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "NMTPWebSocket", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPTests", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPWebSocketTests", dependencies: [
            "NMTPWebSocket",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
    ]
)
```

- [ ] **Step 9: Run all NMTP tests — confirm green**

```bash
swift test --filter NMTPTests
```

Expected: All test suites pass — GracefulShutdownTests, HeartbeatTests, NMTIntegrationTests, NMTTransportTests, PendingRequestsTests, RequestTimeoutTests, TLSContextTests.

- [ ] **Step 10: Commit**

```bash
git add Package.swift \
  Sources/NMTP/Transport/NMTTransport.swift \
  Sources/NMTP/Transport/TCPTransport.swift \
  Sources/NMTP/NMT/NMTServer.swift \
  Sources/NMTP/NMT/NMTClient.swift \
  Tests/NMTPTests/WebSocketTransportTests.swift \
  Tests/NMTPTests/NMTIntegrationTests.swift
git commit -m "[REFACTOR] NMTTransport: enum → protocol; extract TCPTransport; simplify NMTServer/NMTClient"
```

---

### Task 3: NMTPWebSocket — NMTWebSocketFrameHandler + WebSocketTransport + tests

**Context:** All WebSocket-specific implementation goes into the `NMTPWebSocket` target. Write the tests first (they'll fail because `WebSocketTransport` doesn't exist yet), then implement.

**Files:**
- Modify: `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift`
- Create: `Sources/NMTPWebSocket/NMTWebSocketFrameHandler.swift`
- Modify: `Sources/NMTPWebSocket/WebSocketTransport.swift`

- [ ] **Step 1: Write NMTPWebSocketTests — all WebSocket tests**

Replace the entire contents of `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift`:

```swift
import XCTest
import NIO
import NIOWebSocket
@testable import NMTPWebSocket
import NMTP

// MARK: - Frame handler unit tests

final class WebSocketFrameHandlerTests: XCTestCase {

    // Binary frame payload must be forwarded downstream as a plain ByteBuffer.
    func testInbound_binaryFrame_extractsPayload() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        var received = try XCTUnwrap(channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(received.readString(length: 5), "hello")
    }

    // Non-binary frames (ping, text, …) must be silently dropped.
    func testInbound_nonBinaryFrame_dropsFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 4)
        buf.writeString("ping")
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        let received = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertNil(received, "Non-binary frames must not reach the NMT layer")
    }

    // Server-side outbound ByteBuffer → unmasked binary WebSocketFrame.
    func testOutbound_server_writesUnmaskedBinaryFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        XCTAssertNoThrow(try channel.writeOutbound(buf))

        let frame = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertTrue(frame.fin)
        XCTAssertNil(frame.maskKey, "Server frames must NOT be masked (RFC 6455 §5.3)")
    }

    // Client-side outbound ByteBuffer → masked binary WebSocketFrame (RFC 6455 §5.3).
    func testOutbound_client_writesMaskedBinaryFrame() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: true)).wait()

        var buf = channel.allocator.buffer(capacity: 5)
        buf.writeString("hello")
        XCTAssertNoThrow(try channel.writeOutbound(buf))

        let frame = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertNotNil(frame.maskKey, "Client frames MUST be masked (RFC 6455 §5.3)")
        // In EmbeddedChannel the WS encoder has not run yet, so frame.data holds
        // plain bytes and maskKey records the key the encoder *will* apply.
        // Reading frame.data directly avoids a double-XOR corruption.
        var payload = frame.data
        XCTAssertEqual(payload.readString(length: 5), "hello")
    }

    // Masked inbound frame (client → server): handler must unmask before forwarding.
    func testInbound_maskedFrame_unmasksPayload() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(NMTWebSocketFrameHandler(isClient: false)).wait()

        let original: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let keyArray: [UInt8] = [0xAB, 0xCD, 0xEF, 0x12]
        let key = try XCTUnwrap(WebSocketMaskingKey(keyArray))
        let maskedBytes = original.enumerated().map { i, b in b ^ keyArray[i % 4] }
        var maskedBuf = channel.allocator.buffer(capacity: original.count)
        maskedBuf.writeBytes(maskedBytes)

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: key, data: maskedBuf)
        XCTAssertNoThrow(try channel.writeInbound(frame))

        var received = try XCTUnwrap(channel.readInbound(as: ByteBuffer.self))
        XCTAssertEqual(received.readBytes(length: original.count), original)
    }
}

// MARK: - WebSocket integration tests

final class WebSocketIntegrationTests: XCTestCase {

    /// Shared test helpers
    private struct EchoHandler: NMTHandler {
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            Matter(type: .reply, matterID: matter.matterID, body: matter.body)
        }
    }

    private struct PushHandler: NMTHandler {
        let pushBody: Data
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            channel.writeAndFlush(Matter(type: .reply, body: pushBody), promise: nil)
            return nil
        }
    }

    private final class MockTLSContext: TLSContext, Sendable {
        func makeServerHandler() async throws -> any ChannelHandler { PassThroughHandler() }
        func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler { PassThroughHandler() }
    }

    private final class PassThroughHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireChannelRead(data)
        }
    }

    /// Successful connect + close implies the HTTP→WebSocket upgrade was accepted.
    func testWebSocket_serverAcceptsUpgrade() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        try await client.close()
    }

    /// Matter request-reply must work end-to-end over WebSocket.
    func testWebSocket_requestReply() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        defer { Task { try await client.close() } }

        let sentBody = Data("hello-ws".utf8)
        let request = Matter(type: .call, body: sentBody)
        let reply = try await client.request(matter: request)

        XCTAssertEqual(reply.matterID, request.matterID)
        XCTAssertEqual(reply.type, .reply)
        XCTAssertEqual(reply.body, sentBody)
    }

    /// Server-initiated push must arrive at the client over WebSocket.
    func testWebSocket_serverPush() async throws {
        let pushBody = Data("push-ws".utf8)
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: PushHandler(pushBody: pushBody),
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address, transport: WebSocketTransport())
        defer { Task { try await client.close() } }

        client.fire(matter: Matter(type: .call, body: Data()))

        let received: Matter? = try await withThrowingTaskGroup(of: Matter?.self) { group in
            group.addTask {
                for await matter in client.pushes { return matter }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        XCTAssertNotNil(received)
        XCTAssertEqual(received?.body, pushBody)
    }

    /// TLS + WebSocket must complete an echo round-trip.
    func testWebSocket_withTLS() async throws {
        let tls = MockTLSContext()

        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            tls: tls,
            transport: WebSocketTransport()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(
            to: server.address,
            tls: tls,
            transport: WebSocketTransport()
        )
        defer { Task { try await client.close() } }

        let sentBody = Data("tls-ws".utf8)
        let reply = try await client.request(matter: Matter(type: .call, body: sentBody))
        XCTAssertEqual(reply.body, sentBody)
    }

    /// Default transport must still be TCP — regression guard.
    func testDefaultTransportIsTCP() async throws {
        // No transport: argument — defaults to TCPTransport
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler()
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try await client.close() } }

        let sentBody = Data("tcp-default".utf8)
        let reply = try await client.request(matter: Matter(type: .call, body: sentBody))
        XCTAssertEqual(reply.body, sentBody)
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```bash
swift test --filter NMTPWebSocketTests
```

Expected: Compile error — `WebSocketTransport` not found, `NMTWebSocketFrameHandler` not found.

- [ ] **Step 3: Create NMTWebSocketFrameHandler.swift in NMTPWebSocket**

Create `Sources/NMTPWebSocket/NMTWebSocketFrameHandler.swift`. This is the same logic that currently lives in `Sources/NMTP/Transport/WebSocketFrameHandler.swift`, now living in the WebSocket-specific target:

```swift
import NIO
import NIOWebSocket

/// Bridges WebSocket frames ↔ raw `ByteBuffer`s in the NMT pipeline.
///
/// - Inbound:  `WebSocketFrame` (binary) → `ByteBuffer` (for `MatterDecoder`)
/// - Outbound: `ByteBuffer` → `WebSocketFrame` (binary, masked when `isClient == true`)
///
/// Non-binary frames (text, continuation, ping, pong, close) are silently
/// dropped on the inbound path — the NMT protocol layer has no use for them.
final class NMTWebSocketFrameHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private let isClient: Bool

    init(isClient: Bool) {
        self.isClient = isClient
    }

    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .binary else { return }
        let unmasked = frame.unmaskedData
        context.fireChannelRead(wrapInboundOut(unmasked))
    }

    // MARK: Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        // Client frames MUST be masked with a fresh random key (RFC 6455 §5.3).
        let maskKey: WebSocketMaskingKey? = isClient ? .random() : nil
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: buffer)
        context.write(wrapOutboundOut(frame), promise: promise)
    }
}
```

- [ ] **Step 4: Implement WebSocketTransport.swift**

Replace the stub contents of `Sources/NMTPWebSocket/WebSocketTransport.swift`:

```swift
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
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
                // NIOWebSocket automatically adds WebSocketFrameDecoder + WebSocketFrameEncoder
                // before this callback fires.
                // IdleStateHandler/HeartbeatHandler are intentionally omitted — heartbeat
                // over WebSocket is out of scope for this implementation.
                ch.pipeline.addHandlers([
                    NMTWebSocketFrameHandler(isClient: false),
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                ]).flatMap { applicationPipeline(ch) }
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
        elg: MultiThreadedEventLoopGroup,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        // AsyncStream bridges the async upgrade completion into structured concurrency.
        var upgradeSignalContinuation: AsyncStream<Void>.Continuation!
        let upgradeSignal = AsyncStream<Void> { upgradeSignalContinuation = $0 }

        // Random 16-byte nonce for Sec-WebSocket-Key (RFC 6455 §4.1).
        let requestKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        let wsPath = path

        let channel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let upgrader = NIOWebSocketClientUpgrader(
                    requestKey: requestKey,
                    upgradePipelineHandler: { (ch: Channel, _: HTTPResponseHead) -> EventLoopFuture<Void> in
                        ch.pipeline.addHandlers([
                            NMTWebSocketFrameHandler(isClient: true),
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                        ]).flatMap { applicationPipeline(ch) }
                            .map {
                                upgradeSignalContinuation.yield(())
                                upgradeSignalContinuation.finish()
                            }
                    }
                )
                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )
                if let tls {
                    return self.addTLSClientHandler(
                        to: channel, tls: tls, serverHostname: nil
                    ) { ch in
                        ch.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
                    }
                } else {
                    return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config)
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
        // Queue head without flushing so both head and end reach the NIO upgrade handler's
        // write() in the same event-loop turn. A separate writeAndFlush(head) would suspend
        // and yield; if the server returns 101 during that suspension the upgrader rejects
        // the subsequent end write with writingToHandlerDuringUpgrade.
        channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        // Safety net: finish the signal if the server closes without upgrading.
        let signalCont = upgradeSignalContinuation!
        channel.closeFuture.whenComplete { _ in signalCont.finish() }

        // Wait for the server's 101 Switching Protocols and pipeline swap.
        for await _ in upgradeSignal { break }

        guard channel.isActive else {
            throw NMTPError.fail(
                message: "WebSocket upgrade rejected: server closed connection without upgrading"
            )
        }

        return channel
    }
}
```

- [ ] **Step 5: Run NMTPWebSocketTests — confirm green**

```bash
swift test --filter NMTPWebSocketTests
```

Expected: All 9 tests pass — WebSocketFrameHandlerTests (5) + WebSocketIntegrationTests (5 including testDefaultTransportIsTCP).

- [ ] **Step 6: Run all tests — confirm no regression**

```bash
swift test
```

Expected: All test suites pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/NMTPWebSocket/NMTWebSocketFrameHandler.swift \
  Sources/NMTPWebSocket/WebSocketTransport.swift \
  Tests/NMTPWebSocketTests/WebSocketTransportTests.swift
git commit -m "[ADD] NMTPWebSocket target: NMTWebSocketFrameHandler + WebSocketTransport + tests"
```

---

### Task 4: Cleanup — delete old NMTP WebSocket files + update CLAUDE.md

**Files:**
- Delete: `Sources/NMTP/Transport/WebSocketFrameHandler.swift`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Delete the old WebSocketFrameHandler from NMTP**

```bash
git rm Sources/NMTP/Transport/WebSocketFrameHandler.swift
```

- [ ] **Step 2: Verify build and tests pass**

```bash
swift build && swift test
```

Expected: Build succeeded. All tests pass. (No source in NMTP references `NMTWebSocketFrameHandler` anymore — it was only used in the deleted `buildWebSocketServerPipeline` / `connectWebSocket` methods.)

- [ ] **Step 3: Update CLAUDE.md WebSocket Transport naming conventions**

In `CLAUDE.md`, replace the `## WebSocket Transport — Naming Conventions` section with:

```markdown
## Transport — Naming Conventions

Applies to all transport-related code in `swift-nmtp`.

### NMTTransport protocol (in `NMTP`)

| Concept | Name |
|---------|------|
| Transport protocol | `NMTTransport` (`protocol`) |
| Default TCP transport | `TCPTransport` (`struct`); `heartbeatInterval` + `missedLimit` params |
| Protocol TLS helpers | `addTLSServerHandler(to:tls:then:)` / `addTLSClientHandler(to:tls:serverHostname:then:)` — protocol extension, shared by all conformers |

### NMTPWebSocket target

| Concept | Name |
|---------|------|
| WebSocket transport | `WebSocketTransport` (`struct`); `path` param (default `"/nmt"`) |
| Frame bridge handler | `NMTWebSocketFrameHandler` (internal to `NMTPWebSocket`) |

**Binary-only rule:** `NMTWebSocketFrameHandler` uses `.binary` frames exclusively. Any inbound frame whose opcode is not `.binary` (including `.text`, `.continuation`, `.ping`, `.pong`, `.close`) is silently dropped.

**Masking rule:** Client → server frames are always masked (RFC 6455 §5.3). Server → client frames are never masked. `NMTWebSocketFrameHandler(isClient:)` controls this.

**Heartbeat:** `IdleStateHandler`/`HeartbeatHandler` live inside `TCPTransport`. They are intentionally absent from `WebSocketTransport` — heartbeat over WebSocket is out of scope.
```

- [ ] **Step 4: Run all tests one final time**

```bash
swift test
```

Expected: All test suites pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "[CLEANUP] Remove WebSocketFrameHandler from NMTP; update CLAUDE.md transport conventions"
```
