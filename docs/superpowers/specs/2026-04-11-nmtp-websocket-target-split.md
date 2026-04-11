# Design Spec: NMTPWebSocket Target Split

**Date:** 2026-04-11
**Status:** Proposed
**Repo:** `swift-nmtp`

---

## Problem

The WebSocket transport implementation (added 2026-04-10) placed `NIOHTTP1` and `NIOWebSocket` as direct dependencies of the `NMTP` target. Every consumer of `swift-nmtp` now pulls in HTTP and WebSocket libraries even when only using TCP. This violates the principle of paying only for what you use.

---

## Goal

Move all WebSocket-specific code into a new `NMTPWebSocket` target within the same repository. The `NMTP` core target becomes transport-agnostic — it defines the transport abstraction but carries no HTTP/WebSocket dependencies.

## Non-Goals

- Changing the wire protocol or Matter framing
- Adding new transport types (QUIC, gRPC, etc.) — this refactor just makes room for them
- Renaming existing public types beyond what the API changes require

---

## Architecture

### Package Layout

```
swift-nmtp/
  Sources/
    NMTP/                         ← core; no NIOHTTP1/NIOWebSocket
      Transport/
        NMTTransport.swift        ← protocol (replaces enum)
        TCPTransport.swift        ← TCP pipeline logic + heartbeat
      NMT/
        NMTServer.swift           ← uses any NMTTransport
        NMTClient.swift           ← uses any NMTTransport
      ...
    NMTPWebSocket/                ← new target
      WebSocketTransport.swift    ← WebSocket pipeline logic
      NMTWebSocketFrameHandler.swift ← moved from NMTP
  Tests/
    NMTPTests/                    ← existing; heartbeat tests updated
    NMTPWebSocketTests/           ← new; WebSocket tests moved here
```

### Dependency Graph

```
NMTP          ← NIO, NIOExtras, MessagePacker, Logging
NMTPWebSocket ← NMTP + NIOHTTP1 + NIOWebSocket
NMTPTests     ← NMTP + NIO
NMTPWebSocketTests ← NMTPWebSocket + NIO + NIOWebSocket
```

---

## Protocol Design

### `NMTTransport` (Swift protocol)

Replaces the current `NMTTransport` enum. Transport implementations configure the NIO pipeline up to and including their framing layer, then delegate to an `applicationPipeline` closure supplied by `NMTServer`/`NMTClient`. This keeps internal types (`NMTServerInboundHandler`, `PendingRequests`) inside `NMTP` — `NMTPWebSocket` never needs to see them.

```swift
// Sources/NMTP/Transport/NMTTransport.swift
public protocol NMTTransport: Sendable {
    func buildServerPipeline(
        channel: Channel,
        tls: (any TLSContext)?,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void>

    func buildClientPipeline(
        channel: Channel,
        tls: (any TLSContext)?,
        applicationPipeline: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void>
}
```

**POP note:** Shared TLS async setup logic lives in a `protocol extension` on `NMTTransport` — not in an abstract base class — following Swift Protocol-Oriented Programming conventions:

```swift
extension NMTTransport {
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

### `TCPTransport` (in `NMTP`)

```swift
// Sources/NMTP/Transport/TCPTransport.swift
public struct TCPTransport: NMTTransport {
    public let heartbeatInterval: Duration
    public let missedLimit: Int

    public init(
        heartbeatInterval: Duration = .seconds(30),
        missedLimit: Int = 2
    ) { ... }

    public func buildServerPipeline(channel:, tls:, applicationPipeline:) -> EventLoopFuture<Void>
    public func buildClientPipeline(channel:, tls:, applicationPipeline:) -> EventLoopFuture<Void>
}
```

Server pipeline built by `TCPTransport`:
```
[TLSHandler]?                    ← optional, added by TCPTransport
[IdleStateHandler]               ← added by TCPTransport
[HeartbeatHandler]               ← added by TCPTransport
── applicationPipeline adds ──
[ByteToMessageHandler(MatterDecoder)]
[MessageToByteHandler(MatterEncoder)]
[NMTServerInboundHandler]
```

### `WebSocketTransport` (in `NMTPWebSocket`)

```swift
// Sources/NMTPWebSocket/WebSocketTransport.swift
public struct WebSocketTransport: NMTTransport {
    public let path: String
    public init(path: String = "/nmt") { ... }

    public func buildServerPipeline(channel:, tls:, applicationPipeline:) -> EventLoopFuture<Void>
    public func buildClientPipeline(channel:, tls:, applicationPipeline:) -> EventLoopFuture<Void>
}
```

Server pipeline built by `WebSocketTransport`:
```
[TLSHandler]?                              ← optional, added by WebSocketTransport
[HTTPServerCodec]                          ← added by WebSocketTransport (via configureHTTPServerPipeline)
[NIOWebSocketServerUpgrader]              ← added by WebSocketTransport
── after WS upgrade ──
[WebSocketFrameDecoder]                   ← added automatically by NIOWebSocket
[WebSocketFrameEncoder]                   ← added automatically by NIOWebSocket
[NMTWebSocketFrameHandler(isClient: false)] ← added by WebSocketTransport
── applicationPipeline adds ──
[ByteToMessageHandler(MatterDecoder)]
[MessageToByteHandler(MatterEncoder)]
[NMTServerInboundHandler]
```

---

## API Changes

### Heartbeat parameters move to `TCPTransport`

```swift
// BEFORE
NMTServer.bind(on: addr, handler: h,
               heartbeatInterval: .seconds(10), heartbeatMissedLimit: 3)
NMTClient.connect(to: addr,
                  heartbeatInterval: .seconds(10), heartbeatMissedLimit: 3)

// AFTER
NMTServer.bind(on: addr, handler: h,
               transport: TCPTransport(heartbeatInterval: .seconds(10), missedLimit: 3))
NMTClient.connect(to: addr,
                  transport: TCPTransport(heartbeatInterval: .seconds(10), missedLimit: 3))
```

### New signatures

```swift
// NMTServer
public static func bind(
    on address: SocketAddress,
    handler: any NMTHandler,
    tls: (any TLSContext)? = nil,
    transport: any NMTTransport = TCPTransport(),
    eventLoopGroup: MultiThreadedEventLoopGroup? = nil
) async throws -> NMTServer

// NMTClient
public static func connect(
    to address: SocketAddress,
    tls: (any TLSContext)? = nil,
    transport: any NMTTransport = TCPTransport(),
    eventLoopGroup: MultiThreadedEventLoopGroup? = nil
) async throws -> NMTClient
```

### WebSocket usage (requires `import NMTPWebSocket`)

```swift
import NMTPWebSocket

let server = try await NMTServer.bind(
    on: addr,
    handler: h,
    transport: WebSocketTransport(path: "/nmt")
)

let client = try await NMTClient.connect(
    to: addr,
    transport: WebSocketTransport(path: "/nmt")
)
```

---

## File Changes

| Action | File |
|--------|------|
| Modify | `Package.swift` — add `NMTPWebSocket` target + test target; remove NIOHTTP1/NIOWebSocket from NMTP |
| Modify | `Sources/NMTP/Transport/NMTTransport.swift` — enum → protocol + extension TLS helpers |
| Add | `Sources/NMTP/Transport/TCPTransport.swift` — TCP pipeline + heartbeat logic |
| Delete | `Sources/NMTP/Transport/WebSocketFrameHandler.swift` — moved to NMTPWebSocket |
| Add | `Sources/NMTPWebSocket/NMTWebSocketFrameHandler.swift` — moved from NMTP |
| Add | `Sources/NMTPWebSocket/WebSocketTransport.swift` — WebSocket pipeline logic |
| Modify | `Sources/NMTP/NMT/NMTServer.swift` — remove WS imports; use `any NMTTransport`; remove heartbeat params |
| Modify | `Sources/NMTP/NMT/NMTClient.swift` — same |
| Move | `Tests/NMTPTests/WebSocketTransportTests.swift` → `Tests/NMTPWebSocketTests/WebSocketTransportTests.swift` |
| Modify | `Tests/NMTPTests/NMTIntegrationTests.swift` — heartbeat tests use `TCPTransport(heartbeatInterval:)` |

---

## Testing Strategy

| Test File | Target | What it covers |
|-----------|--------|----------------|
| `NMTPTests/NMTIntegrationTests.swift` | NMTPTests | TCP round-trip, push, timeout, heartbeat (via TCPTransport), graceful shutdown |
| `NMTPTests/TLSContextTests.swift` | NMTPTests | TLS context hooks |
| `NMTPWebSocketTests/WebSocketTransportTests.swift` | NMTPWebSocketTests | WS upgrade, request-reply, server push, TLS+WS, binary frame enforcement |

---

## Breaking Changes

- `heartbeatInterval` and `heartbeatMissedLimit` removed from `NMTServer.bind` and `NMTClient.connect` — pass via `TCPTransport(heartbeatInterval:missedLimit:)` instead.
- `NMTTransport` is no longer an enum; existing `.tcp` and `.webSocket(path:)` usages must be updated to `TCPTransport()` and `WebSocketTransport(path:)`.
- `NMTPWebSocket` must be explicitly imported to use `WebSocketTransport`.
