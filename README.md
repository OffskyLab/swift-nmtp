# swift-nmtp

> [!WARNING]
> This package is in early development. Many features are not yet implemented and the API is subject to breaking changes. Do not use in production.

**Nebula Matter Transfer Protocol** — a lightweight binary transport protocol for Swift, built on [SwiftNIO](https://github.com/apple/swift-nio).

NMTP is the wire-protocol layer of the Nebula distributed RPC framework. It handles TCP framing, binary encoding, and request/reply matching. It has no knowledge of service discovery, load balancing, or node roles — those are framework concerns.

---

## Overview

The unit of transmission is called **Matter**. Every interaction between nodes is the transfer of Matter through the Nebula.

### Wire Format

27-byte fixed header + MessagePack body:

```
| Magic "NBLA" (4) | Version (1) | Type (1) | Flags (1) | MatterID/UUID (16) | Length (4) | Body (N) |
```

### MatterType

| Value | Name | Description |
|-------|------|-------------|
| 1 | `clone` | Node identity exchange |
| 2 | `register` | Register a service endpoint |
| 3 | `find` | Discover a service endpoint |
| 4 | `unregister` | Remove a dead endpoint |
| 5 | `call` | RPC invocation |
| 6 | `reply` | RPC reply (unused directly — replies reuse the request's type) |
| 7 | `enqueue` | Async task / broker message |
| 8 | `ack` | Acknowledge a broker message |
| 9 | `subscribe` | Join a pub-sub subscription group |
| 10 | `unsubscribe` | Leave a pub-sub subscription group |
| 11 | `heartbeat` | Keep-alive ping |
| 12 | `activate` | Node activation signal |
| 13 | `findGalaxy` | Discover the Galaxy for a broker topic |

---

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/gradyzhuo/swift-nmtp.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "NMTP", package: "swift-nmtp"),
    ]),
]
```

---

## Usage

### NMTServer

Implement `NMTHandler` to handle incoming Matter:

```swift
import NMTP
import NIO

struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        // echo back whatever arrived
        return matter
    }
}

let address = try SocketAddress.makeAddressResolvingHost("0.0.0.0", port: 7000)
let server = try await NMTServer.bind(on: address, handler: EchoHandler())
try await server.listen()
```

### NMTClient

```swift
import NMTP
import NIO

let address = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 7000)
let client = try await NMTClient.connect(to: address)

// Request/reply
let request = try Matter.make(type: .call, body: CallBody(
    namespace: "production.ml",
    service:   "w2v",
    method:    "wordVector",
    arguments: []
))
let reply = try await client.request(matter: request)

// Fire-and-forget
client.fire(matter: request)

// Server-push stream (unsolicited inbound Matter)
for await pushed in client.pushes {
    print("Pushed:", pushed.type)
}
```

### Argument encoding

```swift
// Encode
let arg = try Argument.wrap(key: "word", value: "hello")

// Decode
let word = try arg.unwrap(as: String.self)
```

---

## Architecture

```
NMTServer.bind(on:handler:)
    └── ServerBootstrap (SwiftNIO)
            └── pipeline: MatterDecoder → MatterEncoder → NMTServerInboundHandler
                                                                └── NMTHandler.handle(matter:channel:)

NMTClient.connect(to:)
    └── ClientBootstrap (SwiftNIO)
            └── pipeline: MatterDecoder → MatterEncoder → NMTClientInboundHandler
                                                                └── pendingRequests (UUID → continuation)
                                                                └── pushes (AsyncStream<Matter>)
```

---

## Relationship to Nebula

```
swift-nmtp          ← this repo — protocol spec & transport
    ↓
swift-nebula        ← server framework (Galaxy, Stellar, Ingress)
    ↓
swift-nebula-client ← Swift client SDK (Planet, Comet, Subscriber)
```

NMTP defines the wire format and transport. Higher-level concepts (node roles, service discovery, load balancing) live in `swift-nebula` and `swift-nebula-client`.

Other language client SDKs implement NMTP independently and interoperate at the wire level.

---

## Performance

Benchmarks compare NMTP against a plain HTTP/1.1 echo server (NIO + AsyncHTTPClient).
Both sides use the same MessagePack-encoded payload over a loopback TCP connection.
Run with [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark) in release mode on macOS (Apple M-series, single machine, loopback).

> Results reflect protocol overhead only. Real-world numbers on Linux servers will vary.

### Throughput — sequential request/reply round-trips

| Payload | NMTP p50 | HTTP p50 | Speedup |
|---------|--------:|--------:|--------:|
| Small  (64 B)  | 20,000 /s | 5,467 /s | **3.7×** |
| Medium (1 KB)  | 20,000 /s | 5,155 /s | **3.9×** |
| Large  (64 KB) | 12,000 /s | 2,733 /s | **4.4×** |

### Latency — wall-clock time per round-trip

| Payload | NMTP p50 | NMTP p99 | HTTP p50 | HTTP p99 |
|---------|--------:|--------:|--------:|--------:|
| Small  (64 B)  |  41 μs |  42 μs | 149 μs | 161 μs |
| Medium (1 KB)  |  40 μs |  64 μs | 149 μs | 156 μs |
| Large  (64 KB) |  94 μs | 379 μs | 379 μs | 379 μs |

### Concurrent connections — wall-clock per batch (N simultaneous requests, Small payload)

| Connections | NMTP p50 | HTTP p50 |
|:-----------:|--------:|--------:|
| 2 |  87 μs | 246 μs |
| 4 | 121 μs | 322 μs |
| 8 | 152 μs | 427 μs |

### Wire overhead

27-byte fixed header (vs ~130 bytes for a typical HTTP/1.1 POST):

| Payload | NMTP wire | HTTP wire |
|---------|----------:|----------:|
| Small  (64 B)  |    87 B |    190 B |
| Medium (1 KB)  | 1,048 B |  1,151 B |
| Large  (64 KB) | 65,560 B | 65,663 B |

To reproduce:

```bash
cd Benchmarks
swift package --disable-sandbox benchmark
```

---

## Requirements

- Swift 6.0+
- macOS 13+

## Dependencies

- [apple/swift-nio](https://github.com/apple/swift-nio)
- [apple/swift-nio-extras](https://github.com/apple/swift-nio-extras)
- [hirotakan/MessagePacker](https://github.com/hirotakan/MessagePacker)
- [apple/swift-log](https://github.com/apple/swift-log)
