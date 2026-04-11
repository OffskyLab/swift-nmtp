# swift-nmtp-peer Design Spec

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this spec.

**Goal:** Add a `NMTPeer` target to `swift-nmtp` that provides a symmetric P2P connection primitive on top of NMTP.

**Architecture:** A thin class-1 layer over NMTP. `NMTPeer` wraps an NMT channel and exposes a symmetric API — no client/server distinction. `NMTPeerListener` accepts incoming connections and yields a `NMTPeer` per connection. The target defines no type values or message semantics; those belong to consumers (orbital-sync, future Nebula Stellar).

**Tech Stack:** Swift 6, SwiftNIO, `NMTP` target (same package), `Synchronization.Mutex`

---

## Package Structure

New target `NMTPeer` in `swift-nmtp/Sources/NMTPeer/`, depending on `NMTP`:

```swift
// Package.swift addition
.target(
    name: "NMTPeer",
    dependencies: [
        .target(name: "NMTP"),
    ]
)
```

Consumers add:
```swift
.product(name: "NMTPeer", package: "swift-nmtp")
```

---

## Public API

### NMTPeerListener

Binds to a local address and produces one `NMTPeer` per accepted connection.

```swift
public final class NMTPeerListener: Sendable {

    /// Binds to `address` and starts accepting connections.
    public static func bind(
        on address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTPeerListener

    /// Async sequence of accepted peers. Each accepted connection yields one NMTPeer.
    public var peers: AsyncStream<NMTPeer> { get }

    /// Local address this listener is bound to.
    public var address: SocketAddress { get }

    /// Stop accepting new connections. Already-accepted peers are unaffected.
    public func close() async throws
}
```

### NMTPeer

A single established P2P connection. Both sides have the same API regardless of which initiated the connection.

```swift
public final class NMTPeer: Sendable {

    /// Connect to a remote peer.
    public static func connect(
        to address: SocketAddress,
        tls: (any TLSContext)? = nil,
        transport: any NMTTransport = TCPTransport(),
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) async throws -> NMTPeer

    /// The remote address of this peer.
    public var remoteAddress: SocketAddress { get }

    /// Send a matter without waiting for a reply.
    public func fire(matter: Matter)

    /// Send a matter and wait for a reply with matching matterID.
    public func request(matter: Matter, timeout: Duration = .seconds(30)) async throws -> Matter

    /// Unsolicited inbound matters (those not matching a pending request).
    public var incoming: AsyncStream<Matter> { get }

    /// Close the connection gracefully.
    public func close() async throws
}
```

---

## Internal Design

`NMTPeer` is backed by an NMT channel with an inbound handler that mirrors `NMTClientInboundHandler`:

- `PendingRequests` for matching replies by `matterID`
- `AsyncStream<Matter>.Continuation` for unsolicited inbound matters (`incoming`)
- `channelInactive` fails all pending requests with `NMTPError.connectionClosed` and finishes `incoming`

`NMTPeerListener` uses `NMTServer`'s bootstrap internally but instead of dispatching to an `NMTHandler`, it hands each accepted channel to a `NMTPeer` initializer and yields it via the `peers` stream.

Both `NMTPeer.connect` and listener-accepted peers go through the same `NMTPeer` type — no client/server distinction after construction.

---

## Error Handling

- `NMTPError.timeout` — `request` timed out
- `NMTPError.connectionClosed` — channel closed before reply arrived
- `NMTPError.connectionDead` — heartbeat missed (TCPTransport only)
- Connection errors during `NMTPeer.connect` propagate as thrown errors

---

## What This Spec Does NOT Cover

- **Typed dispatch** (`PeerMessage` protocol, handler registry) — deferred. Add when ≥2 consumers need it. See [[nmtp-peer-design]] in wiki.
- **nebula class-1 protocol** — separate spec, lives in `swift-nebula`
- **Reconnection logic** — consumer's responsibility
- **Peer identity / auth** — consumer's responsibility (orbital-sync handles via TLS + handshake Matter)

---

## Testing

Integration tests in `Tests/NMTPeerTests/`:

1. **Round-trip**: listener accepts, connector sends a `request`, listener side fires a reply via `fire` — connector receives it via `request` return value
2. **Unsolicited push**: listener-side peer fires an unsolicited matter — connector receives it via `incoming`
3. **Close propagates**: closing one side causes the other's `incoming` to finish and pending `request` to throw `connectionClosed`
4. **Symmetric**: same test as #1 but roles reversed — listener side calls `request`, connector side replies
