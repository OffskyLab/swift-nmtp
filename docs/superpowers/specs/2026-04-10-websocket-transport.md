# Design Spec: WebSocket Transport for swift-nmtp

**Date:** 2026-04-10
**Status:** Proposed
**Repo:** `swift-nmtp`

---

## Problem

NMT currently only supports TCP transport. When peers are behind NAT or firewalls, direct TCP connections require either:
- Both sides running `cloudflared` (TCP tunnel mode)
- A rendezvous server + NAT hole punching

WebSocket transport would allow NMT traffic to flow through standard HTTP infrastructure (Cloudflare, nginx, CDNs) without requiring special client-side software.

---

## Goal

Add WebSocket as an alternative transport layer alongside TCP. The NMT protocol (Matter framing, encoding, request-reply matching) stays unchanged — only the underlying byte stream changes.

## Non-Goals

- Replacing TCP (WebSocket is an additional option, not a replacement)
- Browser client support (this is server-to-server)
- Changing Matter encoding format

---

## Architecture

### Current

```
Matter (27-byte header + MessagePack body)
  ↓
NIO Pipeline (MatterDecoder / MatterEncoder)
  ↓
TCP (NIO ServerBootstrap / ClientBootstrap)
  ↓
TLS (optional, pluggable via TLSContext protocol)
```

### Proposed

```
Matter (unchanged)
  ↓
NIO Pipeline (unchanged)
  ↓
Transport (pluggable)
  ├── .tcp    — current behavior (default)
  └── .webSocket  — NMT frames inside WebSocket binary messages
  ↓
TLS (unchanged, still pluggable)
```

---

## API Changes

### Transport enum

```swift
public enum NMTTransport: Sendable {
    case tcp
    case webSocket(path: String = "/nmt")
}
```

### NMTServer

```swift
public static func bind(
    on address: SocketAddress,
    handler: any NMTHandler,
    tls: (any TLSContext)? = nil,
    transport: NMTTransport = .tcp,
    eventLoopGroup: MultiThreadedEventLoopGroup? = nil
) async throws -> NMTServer
```

When `transport = .webSocket`:
- Server accepts HTTP upgrade to WebSocket at the configured path
- After upgrade, WebSocket binary frames carry raw NMT bytes
- MatterDecoder/MatterEncoder work on the decoded WebSocket frame payloads

### NMTClient

```swift
public static func connect(
    to address: SocketAddress,
    tls: (any TLSContext)? = nil,
    transport: NMTTransport = .tcp,
    eventLoopGroup: MultiThreadedEventLoopGroup? = nil
) async throws -> NMTClient
```

When `transport = .webSocket`:
- Client performs HTTP upgrade to WebSocket
- All subsequent Matter is sent as WebSocket binary frames

---

## NIO Pipeline (WebSocket mode)

```
Server:
  [TLSHandler]               ← optional
  [HTTPServerCodec]
  [NIOWebSocketServerUpgrader]
  ── after upgrade ──
  [WebSocketFrameDecoder]     ← unwraps WS frames to ByteBuffer
  [WebSocketFrameEncoder]     ← wraps ByteBuffer into WS binary frames
  [MatterDecoder]             ← same as TCP mode
  [MatterEncoder]             ← same as TCP mode
  [NMTServerInboundHandler]   ← same as TCP mode

Client:
  [TLSHandler]               ← optional
  [HTTPClientCodec]
  [WebSocketClientUpgrader]
  ── after upgrade ──
  [WebSocketFrameDecoder]
  [WebSocketFrameEncoder]
  [MatterDecoder]
  [MatterEncoder]
  [NMTClientInboundHandler]
```

Key insight: `MatterDecoder` and `MatterEncoder` don't care where the bytes come from. The WebSocket layer just needs to pass raw bytes through after stripping/adding WS framing.

---

## Dependencies

Add to `Package.swift`:
```swift
.package(url: "https://github.com/apple/swift-nio.git", from: "2.40.0"),
// NIOWebSocket is part of swift-nio, no additional package needed
```

Use `NIOWebSocket` module (already included in swift-nio):
```swift
.product(name: "NIOWebSocket", package: "swift-nio"),
```

---

## Use Case: Cloudflare Tunnel

The primary motivation. With WebSocket transport:

```
Peer A (behind NAT)                    Cloudflare                    Peer B
NMTServer (ws://localhost:9527/nmt)
  ↓
cloudflared tunnel                 →   edge proxy    ←     NMTClient (wss://sync.example.com/nmt)
  (only server side needs this)        (transparent)       (no cloudflared needed)
```

- Server runs `cloudflared tunnel --url http://localhost:9527`
- Cloudflare proxies WebSocket transparently
- Client connects to `wss://sync.example.com/nmt` — standard HTTPS, no special software
- mTLS still works inside the WebSocket connection

---

## Testing Strategy

| Test | What it checks |
|------|---------------|
| `WebSocket_serverAcceptsUpgrade` | HTTP upgrade to WebSocket succeeds |
| `WebSocket_requestReply` | Matter request-reply works over WebSocket |
| `WebSocket_serverPush` | Server-initiated push arrives via WebSocket |
| `WebSocket_withTLS` | TLS + WebSocket combined |
| `WebSocket_tcpDefault` | Default transport is still TCP (no regression) |
| `WebSocket_binaryFrames` | Verifies binary (not text) WebSocket frames are used |

---

## Implementation Plan

1. Add `NMTTransport` enum
2. Add WebSocket frame encoder/decoder handlers (thin wrappers)
3. Modify `NMTServer.bind` — branch on transport for pipeline setup
4. Modify `NMTClient.connect` — branch on transport for pipeline setup
5. Tests
6. Update CLAUDE.md with WebSocket naming conventions

---

## File Changes

| Action | File |
|--------|------|
| Add | `Sources/NMTP/Transport/NMTTransport.swift` |
| Add | `Sources/NMTP/Transport/WebSocketFrameHandler.swift` |
| Modify | `Sources/NMTP/NMT/NMTServer.swift` — add `transport` param |
| Modify | `Sources/NMTP/NMT/NMTClient.swift` — add `transport` param |
| Modify | `Package.swift` — add `NIOWebSocket` product |
| Add | `Tests/NMTPTests/WebSocketTransportTests.swift` |
