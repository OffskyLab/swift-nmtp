# Reliability Sub-system Design

**Date:** 2026-04-10
**Status:** Approved
**Scope:** swift-nmtp production readiness — Phase 1 of 4

---

## Goal

Make swift-nmtp safe to run in production by covering the three most critical failure modes: requests that hang forever, connections that silently die, and servers that drop in-flight work on restart.

## Context

This is the first of four production-readiness sub-systems:

| Phase | Sub-system | Status |
|-------|-----------|--------|
| 1 | **Reliability** (this spec) | Designing |
| 2 | Observability (logging/metrics) | Pending |
| 3 | Protocol correctness (version negotiation, backpressure) | Pending |
| 4 | 1.0 release (API freeze, docs, SemVer) | Pending |

swift-nebula already depends on swift-nmtp but has not been deployed to production. This spec addresses all known reliability risks before first deployment.

---

## Mechanisms

### 1. Request Timeout

**Problem:** `NMTClient.request()` has no timeout. If the server crashes or stops responding after the TCP connection is established, the caller hangs indefinitely.

**Design:**

Add a `timeout` parameter to `request()`:

```swift
// Before
public func request(matter: Matter) async throws -> Matter

// After
public func request(matter: Matter, timeout: Duration = .seconds(30)) async throws -> Matter
```

Implementation uses Swift structured concurrency racing:

```swift
try await withThrowingTaskGroup(of: Matter.self) { group in
    group.addTask { try await self._send(matter) }
    group.addTask {
        try await Task.sleep(for: timeout)
        throw NMTPError.timeout
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
}
```

When the timeout task wins, the cancellation of the send task must remove the UUID from `PendingRequests` to prevent memory leaks. `PendingRequests` must handle `Task` cancellation via `withTaskCancellationHandler`.

**New error:** `NMTPError.timeout`

---

### 2. Heartbeat

**Problem:** TCP connections can appear alive while the remote end is dead (network partition, process crash, NAT table expiry). Without application-layer heartbeats, neither side discovers the dead connection until the next send attempt.

`MatterType.heartbeat` (value `0x07`) is already defined but has no implementation.

**Design:**

Add a `HeartbeatHandler: ChannelDuplexHandler` to the NIO pipeline, placed after the codecs and before the business handler:

```
MatterDecoder → MatterEncoder → IdleStateHandler → HeartbeatHandler → NMTInboundHandler
```

`IdleStateHandler` (from `swift-nio-extras`, already a dependency) fires `IdleStateEvent.readerIdle` when no data arrives within `heartbeatInterval`. `HeartbeatHandler` responds by sending a `Matter(type: .heartbeat)`. If `heartbeatMissedLimit` consecutive heartbeats go unanswered, the handler closes the channel with `NMTPError.connectionDead`.

On receiving a heartbeat from the remote side, `HeartbeatHandler` replies immediately with another heartbeat and does **not** forward the event to the business handler.

Both `NMTServer` and `NMTClient` install `HeartbeatHandler`. This means both sides detect dead connections, regardless of which end stopped responding.

**New parameters on `NMTServer.bind()` and `NMTClient.connect()`:**

```swift
heartbeatInterval: Duration = .seconds(30),
heartbeatMissedLimit: Int = 2
```

A missed limit of 2 means the connection is declared dead after `heartbeatInterval × missedLimit` = 60 seconds with the defaults: the first heartbeat fires after one idle interval, and the connection closes after `missedLimit` consecutive unanswered heartbeats. Callers in latency-sensitive deployments can tighten this.

**New error:** `NMTPError.connectionDead`

---

### 3. Graceful Shutdown

**Problem:** `NMTServer.closeNow()` immediately closes all channels. Any in-flight `request()` calls on connected clients receive a channel-closed error, causing failed RPCs on every rolling deploy.

**Design:**

Add `NMTServer.shutdown(gracePeriod:)`:

```swift
public func shutdown(gracePeriod: Duration = .seconds(30)) async throws
```

Shutdown proceeds in three steps:

1. **Stop accepting new connections** — bind channel stops accepting, existing channels remain open.
2. **Drain in-flight requests** — wait until `PendingRequests.inflightCount == 0`, or until `gracePeriod` elapses, whichever comes first.
3. **Force close** — close all remaining channels and shut down the event loop group.

During the drain window, any new `request()` received by the server handler is rejected immediately with `NMTPError.shuttingDown`. This gives upstream load balancers and clients a chance to route to other nodes.

`PendingRequests` (client-side) gains cancellation support for the timeout mechanism — see Request Timeout above.

For server-side drain, `NMTServer` maintains its own `inflightCount: Int` counter (Mutex-protected), shared across all server-side channel handlers. `NMTServerInboundHandler` increments the counter when `NMTHandler.handle()` is called and decrements when it returns. `shutdown()` waits on a `drain() async` method that suspends via `CheckedContinuation` and resumes when `inflightCount` drops to zero.

**New error:** `NMTPError.shuttingDown`

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/NMTP/NMTPError.swift` | Add `.timeout`, `.connectionDead`, `.shuttingDown` |
| `Sources/NMTP/Message Routing/PendingRequests.swift` | Add `withTaskCancellationHandler` support for timeout cancellation |
| `Sources/NMTP/NMTClient.swift` | `request()` adds `timeout` param; pipeline gets `IdleStateHandler` + `HeartbeatHandler` |
| `Sources/NMTP/NMTServer.swift` | `bind()` adds heartbeat params; add `shutdown(gracePeriod:)`; add `inflightCount` counter; reject requests when shutting down |

**New file:**

| File | Content |
|------|---------|
| `Sources/NMTP/HeartbeatHandler.swift` | `ChannelDuplexHandler` — idle detection, heartbeat send/receive, missed-beat counting |

---

## Testing Strategy (TDD order)

Tests are written before implementation, one mechanism at a time.

### Timeout tests
1. Build a mock server that accepts connections but never replies
2. Assert `request(matter:timeout:.milliseconds(200))` throws `NMTPError.timeout` within ~200 ms
3. Assert `PendingRequests.inflightCount == 0` after timeout (no leak)

### Heartbeat tests
4. Connect client to server; manually close the server's channel without sending any Matter
5. Assert client receives `NMTPError.connectionDead` within `interval × (missedLimit + 1)`
6. Assert normal request/reply flow is unaffected by heartbeats running in the background

### Graceful shutdown tests
7. Send a request to a server that delays its reply by 500 ms
8. Immediately call `server.shutdown(gracePeriod: .seconds(5))`
9. Assert the slow request completes successfully (not interrupted)
10. Assert the server channel is fully closed after the request finishes
11. Send a new request during the drain window; assert it throws `NMTPError.shuttingDown`

---

## Non-goals (deferred)

- **Auto-reconnect** — client reconnection logic is a separate sub-system
- **Backpressure** — belongs to Protocol correctness (Phase 3)
- **Logging/metrics** — Observability sub-system (Phase 2)
- **TLS implementation** — deferred; `TLSContext` abstraction already allows callers to supply their own
