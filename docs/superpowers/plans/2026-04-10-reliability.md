# Reliability Sub-system Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add request timeout, heartbeat dead-connection detection, and graceful shutdown to swift-nmtp so it is safe to run in production.

**Architecture:** Three independent mechanisms are layered on top of the existing NIO pipeline. `HeartbeatHandler` (a new `ChannelDuplexHandler`) is inserted between the codecs and the business handler on both client and server. Timeout is implemented as a `withThrowingTaskGroup` race inside `NMTClient.request()`. Graceful shutdown is orchestrated by a new shared `ServerState` object that tracks in-flight handler calls and suspends `shutdown()` until the count reaches zero.

**Tech Stack:** Swift 6, SwiftNIO 2.x (`NIO` module — `IdleStateHandler` is in core NIO), `Synchronization.Mutex` (macOS 15+), Swift Testing (unit tests), XCTest (integration tests).

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/NMTP/NMTPError.swift` | Modify | Add `.timeout`, `.connectionDead`, `.shuttingDown` |
| `Sources/NMTP/Extensions/Duration+TimeAmount.swift` | **Create** | Convert `Duration` → NIO `TimeAmount` for `IdleStateHandler` |
| `Sources/NMTP/NMT/HeartbeatHandler.swift` | **Create** | NIO `ChannelDuplexHandler` — idle detection, heartbeat send/receive |
| `Sources/NMTP/NMT/NMTClient.swift` | Modify | `request()` gains `timeout` param; pipeline gets heartbeat handlers |
| `Sources/NMTP/NMT/NMTServer.swift` | Modify | `bind()` gains heartbeat params; add `ServerState`; add `shutdown()` |
| `Tests/NMTPTests/NMTPErrorTests.swift` | Modify | Tests for the 3 new error cases |
| `Tests/NMTPTests/NMTIntegrationTests.swift` | Modify | Tests for timeout, heartbeat, graceful shutdown |

---

## Task 1: New NMTPError cases

**Files:**
- Modify: `Sources/NMTP/NMTPError.swift`
- Modify: `Tests/NMTPTests/NMTPErrorTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the `errorCasesThrowable()` test in `Tests/NMTPTests/NMTPErrorTests.swift` — append inside the existing `@Test` function body:

```swift
    @Test("New reliability error cases are throwable and equatable")
    func reliabilityErrorCases() throws {
        #expect(throws: NMTPError.self) {
            throw NMTPError.timeout
        }
        #expect(throws: NMTPError.self) {
            throw NMTPError.connectionDead
        }
        #expect(throws: NMTPError.self) {
            throw NMTPError.shuttingDown
        }
        // Equatability
        #expect(NMTPError.timeout == NMTPError.timeout)
        #expect(NMTPError.connectionDead != NMTPError.timeout)
        #expect(NMTPError.shuttingDown != NMTPError.connectionDead)
    }
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter NMTPTests/NMTPErrorTests/reliabilityErrorCases
```

Expected: compile error — `type 'NMTPError' has no member 'timeout'`

- [ ] **Step 3: Add the three cases**

Replace the full contents of `Sources/NMTP/NMTPError.swift`:

```swift
import Foundation

public enum NMTPError: Error, Equatable {
    case fail(message: String)
    case invalidMatter(_ reason: String)
    case notConnected
    case connectionClosed

    /// The remote did not reply within the caller-specified deadline.
    case timeout

    /// The heartbeat mechanism detected that the remote end is no longer responding.
    case connectionDead

    /// The server is draining in-flight requests and will not accept new ones.
    case shuttingDown
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
swift test --filter NMTPTests/NMTPErrorTests/reliabilityErrorCases
```

Expected: Test Suite 'NMTPErrorTests' passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/NMTP/NMTPError.swift Tests/NMTPTests/NMTPErrorTests.swift
git commit -m "[ADD] NMTPError: .timeout, .connectionDead, .shuttingDown"
```

---

## Task 2: Request timeout in NMTClient

**Files:**
- Modify: `Sources/NMTP/NMT/NMTClient.swift`
- Modify: `Tests/NMTPTests/NMTIntegrationTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a new `XCTestCase` class at the bottom of `Tests/NMTPTests/NMTIntegrationTests.swift`:

```swift
// MARK: - Timeout tests

final class RequestTimeoutTests: XCTestCase {

    /// A server that accepts connections and decodes Matter, but never replies.
    private func makeSilentServer(elg: MultiThreadedEventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MatterDecoder()),
                    MessageToByteHandler(MatterEncoder()),
                    // No reply handler — connection stays silent.
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func testRequestThrowsTimeoutWhenServerNeverReplies() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? elg.syncShutdownGracefully() }

        let server = try await makeSilentServer(elg: elg)
        defer { server.close(promise: nil) }

        let address = server.localAddress!
        let client = try await NMTClient.connect(to: address, eventLoopGroup: elg)
        defer { Task { try? await client.close() } }

        let request = Matter(type: .call, body: Data("ping".utf8))
        do {
            _ = try await client.request(matter: request, timeout: .milliseconds(100))
            XCTFail("Expected NMTPError.timeout")
        } catch NMTPError.timeout {
            // Expected
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter NMTPTests/RequestTimeoutTests/testRequestThrowsTimeoutWhenServerNeverReplies
```

Expected: compile error — `extra argument 'timeout' in call`

- [ ] **Step 3: Implement timeout in NMTClient.request()**

Replace the `request(matter:)` method in `Sources/NMTP/NMT/NMTClient.swift`:

```swift
public func request(matter: Matter, timeout: Duration = .seconds(30)) async throws -> Matter {
    return try await withThrowingTaskGroup(of: Matter.self) { group in
        group.addTask {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingRequests.register(id: matter.matterID, continuation: continuation)
                    self.channel.writeAndFlush(matter, promise: nil)
                }
            } onCancel: {
                // Remove the pending UUID so no memory leak occurs.
                self.pendingRequests.fail(id: matter.matterID, error: NMTPError.timeout)
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw NMTPError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
swift test --filter NMTPTests/RequestTimeoutTests/testRequestThrowsTimeoutWhenServerNeverReplies
```

Expected: Test Case 'RequestTimeoutTests.testRequestThrowsTimeoutWhenServerNeverReplies' passed.

- [ ] **Step 5: Verify existing tests still pass**

```bash
swift test
```

Expected: All tests pass. The default `timeout: .seconds(30)` means all existing call sites compile unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/NMTP/NMT/NMTClient.swift Tests/NMTPTests/NMTIntegrationTests.swift
git commit -m "[ADD] NMTClient.request(timeout:) — TaskGroup racing with cancellation cleanup"
```

---

## Task 3: Duration → TimeAmount extension

**Files:**
- **Create:** `Sources/NMTP/Extensions/Duration+TimeAmount.swift`

This utility is needed by Task 4 to pass `Duration` values to NIO's `IdleStateHandler`, which requires `TimeAmount`. There is no existing conversion in NIO 2.x.

- [ ] **Step 1: Create the file**

```swift
// Sources/NMTP/Extensions/Duration+TimeAmount.swift
import NIO

extension Duration {
    /// Converts a Swift `Duration` to a NIO `TimeAmount`.
    ///
    /// `Duration.components` returns `(seconds: Int64, attoseconds: Int64)`.
    /// 1 attosecond = 1e-18 s = 1e-9 ns, so integer-dividing attoseconds by
    /// 1_000_000_000 gives the sub-second nanoseconds without floating-point.
    var timeAmount: TimeAmount {
        let (seconds, attoseconds) = components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build
```

Expected: Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/NMTP/Extensions/Duration+TimeAmount.swift
git commit -m "[ADD] Duration+TimeAmount: convert Swift Duration to NIO TimeAmount"
```

---

## Task 4: HeartbeatHandler

**Files:**
- **Create:** `Sources/NMTP/NMT/HeartbeatHandler.swift`
- Modify: `Tests/NMTPTests/NMTIntegrationTests.swift`

`HeartbeatHandler` sits in the pipeline after `IdleStateHandler`. When the reader-idle event fires it sends a heartbeat `Matter`; after `missedLimit` consecutive unanswered heartbeats it closes the channel with `NMTPError.connectionDead`. Any received data (heartbeat or regular) resets the missed-beats counter; received heartbeats are answered and not forwarded to the business handler.

- [ ] **Step 1: Write the failing integration test**

Add after `RequestTimeoutTests` in `Tests/NMTPTests/NMTIntegrationTests.swift`:

```swift
// MARK: - Heartbeat tests

final class HeartbeatTests: XCTestCase {

    /// Connects a client with a very short heartbeat interval to a TCP server
    /// that accepts the connection but never sends any data back.
    /// Asserts the client detects the dead connection within the expected window.
    func testClientDetectsDeadConnectionViaHeartbeat() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? elg.syncShutdownGracefully() }

        // Raw silent server — accepts TCP but sends nothing.
        let silentServer = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Accept the connection silently.
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { silentServer.close(promise: nil) }

        // Client with a 50 ms heartbeat interval and missedLimit = 2.
        // Connection declared dead after 50 ms × 2 = 100 ms.
        let client = try await NMTClient.connect(
            to: silentServer.localAddress!,
            heartbeatInterval: .milliseconds(50),
            heartbeatMissedLimit: 2,
            eventLoopGroup: elg
        )
        defer { Task { try? await client.close() } }

        // Wait for 250 ms — well past the 100 ms dead-connection deadline.
        try await Task.sleep(for: .milliseconds(250))

        // The next request should fail because the channel is now closed.
        do {
            _ = try await client.request(
                matter: Matter(type: .call, body: Data()),
                timeout: .milliseconds(50)
            )
            XCTFail("Expected a connection error")
        } catch let error as NMTPError {
            // Accept connectionDead, connectionClosed, or timeout — all indicate
            // the channel is no longer usable.
            XCTAssertTrue(
                error == .connectionDead || error == .connectionClosed || error == .timeout,
                "Unexpected error: \(error)"
            )
        }
    }

    func testHeartbeatDoesNotDisruptNormalTraffic() async throws {
        // Server and client both have heartbeat enabled with a short interval.
        // Normal request/reply should still complete correctly.
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            heartbeatInterval: .milliseconds(30)
        )
        defer { server.closeNow() }

        let client = try await NMTClient.connect(
            to: server.address,
            heartbeatInterval: .milliseconds(30)
        )
        defer { Task { try? await client.close() } }

        // Fire several requests while heartbeats are running in the background.
        for i in 0..<5 {
            let body = Data("msg-\(i)".utf8)
            let reply = try await client.request(matter: Matter(type: .call, body: body))
            XCTAssertEqual(reply.body, body)
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter NMTPTests/HeartbeatTests
```

Expected: compile error — `extra argument 'heartbeatInterval' in call`

- [ ] **Step 3: Create HeartbeatHandler**

Create `Sources/NMTP/NMT/HeartbeatHandler.swift`:

```swift
import Foundation
import NIO

/// NIO channel handler that detects dead connections via application-layer heartbeats.
///
/// Place this handler immediately after `IdleStateHandler` in the pipeline:
/// ```
/// IdleStateHandler → HeartbeatHandler → NMTInboundHandler
/// ```
///
/// When the reader is idle for `heartbeatInterval`, `IdleStateHandler` fires
/// `IdleStateHandler.IdleStateEvent.read`. `HeartbeatHandler` responds by sending
/// a `Matter(type: .heartbeat)` and incrementing `missedBeats`. If `missedBeats`
/// reaches `missedLimit`, the channel is closed with `NMTPError.connectionDead`.
///
/// Any received data (heartbeat reply or regular matter) resets `missedBeats`.
/// Received heartbeats are answered with a heartbeat reply and are **not** forwarded
/// to the next handler, keeping the business layer unaware of the mechanism.
///
/// All mutable state is accessed only from the channel's event loop thread, which
/// is why `@unchecked Sendable` is safe here.
final class HeartbeatHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn  = Matter
    typealias InboundOut = Matter
    typealias OutboundIn = Matter
    typealias OutboundOut = Matter

    private let missedLimit: Int
    private var missedBeats = 0

    init(missedLimit: Int) {
        self.missedLimit = missedLimit
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        missedBeats = 0                          // any received data = connection is alive
        let matter = unwrapInboundIn(data)
        if matter.type == .heartbeat {
            // Reply to keep the other side's idle timer alive; don't forward.
            let reply = Matter(type: .heartbeat, body: Data())
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        missedBeats += 1
        guard missedBeats < missedLimit else {
            // Declare the connection dead.
            context.fireErrorCaught(NMTPError.connectionDead)
            context.close(promise: nil)
            return
        }
        // Send a heartbeat probe.
        let probe = Matter(type: .heartbeat, body: Data())
        context.writeAndFlush(wrapOutboundOut(probe), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
```

- [ ] **Step 4: Wire heartbeat into NMTClient.connect()**

Add `heartbeatInterval` and `heartbeatMissedLimit` parameters to `NMTClient.connect()` in `Sources/NMTP/NMT/NMTClient.swift`. Replace the `connect()` method:

```swift
public static func connect(
    to address: SocketAddress,
    tls: (any TLSContext)? = nil,
    heartbeatInterval: Duration = .seconds(30),
    heartbeatMissedLimit: Int = 2,
    eventLoopGroup: MultiThreadedEventLoopGroup? = nil
) async throws -> NMTClient {
    let owned = eventLoopGroup == nil
        ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
    let elg = eventLoopGroup ?? owned!
    let pendingRequests = PendingRequests()
    var cont: AsyncStream<Matter>.Continuation!
    let pushes = AsyncStream<Matter> { cont = $0 }
    let inboundHandler = NMTClientInboundHandler(pendingRequests: pendingRequests, pushContinuation: cont)
    do {
        let channel = try await ClientBootstrap(group: elg)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let heartbeat = [
                    IdleStateHandler(readerIdleTime: heartbeatInterval.timeAmount),
                    HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                ] as [any ChannelHandler]
                if let tls {
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let tlsHandler = try await tls.makeClientHandler(serverHostname: nil)
                        try await channel.pipeline.addHandlers([
                            tlsHandler,
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                        ] + heartbeat + [inboundHandler]).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHandlers(
                        [
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                        ] + heartbeat + [inboundHandler]
                    )
                }
            }
            .connect(to: address)
            .get()
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
```

> **Note:** `NMTServer.bind()` also gets `heartbeatInterval`/`heartbeatMissedLimit` parameters, but that change is included in Task 5 (which rewrites the entire server file together with graceful shutdown). Do **not** modify `NMTServer.swift` in this task.

- [ ] **Step 5: Run client heartbeat test — expect PASS**

```bash
swift test --filter NMTPTests/HeartbeatTests/testClientDetectsDeadConnectionViaHeartbeat
```

Expected: Test Case 'HeartbeatTests.testClientDetectsDeadConnectionViaHeartbeat' passed.

- [ ] **Step 6: Run full test suite**

```bash
swift test
```

Expected: All tests pass. (`testHeartbeatDoesNotDisruptNormalTraffic` is not yet runnable — it needs the server-side changes in Task 5.)

- [ ] **Step 7: Commit**

```bash
git add Sources/NMTP/NMT/HeartbeatHandler.swift \
        Sources/NMTP/NMT/NMTClient.swift \
        Tests/NMTPTests/NMTIntegrationTests.swift
git commit -m "[ADD] HeartbeatHandler: idle-detection via IdleStateHandler + missed-beat close"
```

---

## Task 5: Graceful shutdown

**Files:**
- Modify: `Sources/NMTP/NMT/NMTServer.swift`
- Modify: `Tests/NMTPTests/NMTIntegrationTests.swift`

`ServerState` is a `Sendable` shared object (one per server) that tracks how many `NMTHandler.handle()` calls are currently executing. It provides `drain() async` which suspends until the count reaches zero. It is created in `NMTServer.bind()` and passed to every `NMTServerInboundHandler` instance.

- [ ] **Step 1: Write the failing tests**

Add after `HeartbeatTests` in `Tests/NMTPTests/NMTIntegrationTests.swift`:

```swift
// MARK: - Graceful shutdown tests

final class GracefulShutdownTests: XCTestCase {

    /// A handler that waits `delay` before replying, simulating slow work.
    private struct SlowEchoHandler: NMTHandler {
        let delay: Duration
        func handle(matter: Matter, channel: Channel) async throws -> Matter? {
            try await Task.sleep(for: delay)
            return Matter(type: .reply, matterID: matter.matterID, body: matter.body)
        }
    }

    func testSlowRequestCompletesBeforeShutdownCloses() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(300))
        )

        let client = try await NMTClient.connect(to: server.address)
        defer { Task { try? await client.close() } }

        // Fire the slow request — it will take ~300 ms to reply.
        async let replyTask = client.request(matter: Matter(type: .call, body: Data("slow".utf8)))

        // Immediately start shutdown with a generous grace period.
        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        // Both should complete: reply arrives, THEN server closes.
        let reply = try await replyTask
        try await shutdownTask

        XCTAssertEqual(reply.body, Data("slow".utf8))
    }

    func testNewRequestDuringDrainFailsWithConnectionError() async throws {
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: SlowEchoHandler(delay: .milliseconds(500))
        )

        let clientA = try await NMTClient.connect(to: server.address)
        let clientB = try await NMTClient.connect(to: server.address)
        defer {
            Task { try? await clientA.close() }
            Task { try? await clientB.close() }
        }

        // clientA fires a slow request.
        async let _ = clientA.request(matter: Matter(type: .call, body: Data()))

        // Give the slow request a moment to reach the server handler.
        try await Task.sleep(for: .milliseconds(50))

        // Start shutdown.
        async let shutdownTask: Void = server.shutdown(gracePeriod: .seconds(5))

        // Give shutdown a moment to set the flag.
        try await Task.sleep(for: .milliseconds(50))

        // clientB sends a new request during drain — server should reject it.
        do {
            _ = try await clientB.request(
                matter: Matter(type: .call, body: Data()),
                timeout: .milliseconds(200)
            )
            XCTFail("Expected a connection error during drain")
        } catch let e as NMTPError {
            XCTAssertTrue(
                e == .connectionClosed || e == .timeout || e == .connectionDead,
                "Unexpected error: \(e)"
            )
        }

        try await shutdownTask
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

```bash
swift test --filter NMTPTests/GracefulShutdownTests
```

Expected: compile error — `value of type 'NMTServer' has no member 'shutdown'`

- [ ] **Step 3: Add ServerState to NMTServer.swift**

Add `ServerState` before the `NMTServer` class declaration in `Sources/NMTP/NMT/NMTServer.swift`. Also update `NMTServerInboundHandler` to use it. Replace the entire file with:

```swift
import Logging
import NIO
import Synchronization

// MARK: - ServerState

/// Tracks the number of currently-executing `NMTHandler.handle()` calls.
/// Thread-safe via a single `Mutex`-protected struct.
/// Created once per server instance; shared across all child-channel handlers.
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

    /// Suspends until all in-flight handler calls complete, then returns.
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
        heartbeatInterval: Duration = .seconds(30),
        heartbeatMissedLimit: Int = 2,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTServer {
        let owned = eventLoopGroup == nil ? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) : nil
        let elg = eventLoopGroup ?? owned!
        let serverState = ServerState()
        let channel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let heartbeat = [
                    IdleStateHandler(readerIdleTime: heartbeatInterval.timeAmount),
                    HeartbeatHandler(missedLimit: heartbeatMissedLimit),
                ] as [any ChannelHandler]
                if let tls {
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let tlsHandler = try await tls.makeServerHandler()
                        try await channel.pipeline.addHandlers(
                            [
                                tlsHandler,
                                ByteToMessageHandler(MatterDecoder()),
                                MessageToByteHandler(MatterEncoder()),
                            ] + heartbeat + [NMTServerInboundHandler(handler: handler, serverState: serverState)]
                        ).get()
                    }
                    return promise.futureResult
                } else {
                    return channel.pipeline.addHandlers(
                        [
                            ByteToMessageHandler(MatterDecoder()),
                            MessageToByteHandler(MatterEncoder()),
                        ] + heartbeat + [NMTServerInboundHandler(handler: handler, serverState: serverState)]
                    )
                }
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

    /// Gracefully stops the server:
    /// 1. Stops accepting new connections.
    /// 2. Waits up to `gracePeriod` for all in-flight `NMTHandler.handle()` calls to complete.
    /// 3. Shuts down the event loop group (closing all remaining channels).
    public func shutdown(gracePeriod: Duration = .seconds(30)) async throws {
        serverState.beginShutdown()
        // Stop accepting new connections (child channels remain open).
        try? await channel.close().get()
        // Drain with a deadline: whichever finishes first (drain or sleep) wins.
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
        // During drain, reject new requests by closing the child channel.
        // The client's channelInactive fires, failing pending requests with .connectionClosed.
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

- [ ] **Step 4: Run graceful shutdown tests — expect PASS**

```bash
swift test --filter NMTPTests/GracefulShutdownTests
```

Expected: Both graceful-shutdown tests pass.

- [ ] **Step 5: Run full test suite**

```bash
swift test
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/NMTP/NMT/NMTServer.swift \
        Tests/NMTPTests/NMTIntegrationTests.swift
git commit -m "[ADD] NMTServer.shutdown(gracePeriod:) — ServerState drain + in-flight tracking"
```

---

## Appendix: swift-nebula adoption notes

The following changes are **backwards-compatible** — nebula compiles unchanged after this update. However the nebula team should make one proactive update:

### Replace `closeNow()` with `shutdown(gracePeriod:)` in server lifecycle

Wherever swift-nebula calls `server.closeNow()` or `server.stop()` during deployment, replace with:

```swift
try await server.shutdown(gracePeriod: .seconds(30))
```

This ensures in-flight RPCs complete cleanly on every rolling deploy instead of being forcibly interrupted.

### New error cases to be aware of

`NMTPError` now has three additional cases. If nebula ever switches exhaustive pattern matching on `NMTPError`, add handling for:

```swift
case .timeout:       // client request timed out
case .connectionDead: // heartbeat detected dead connection
case .shuttingDown:  // (server-internal, currently surfaces as .connectionClosed on client)
```

No other call sites need changes.
