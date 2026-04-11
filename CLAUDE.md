# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Workflow — MANDATORY

**All modifications and new features in `swift-nmtp` must follow this process:**

1. **Use `superpowers` + TDD** — invoke the superpowers brainstorming/planning skills and follow TDD for every change.
2. **Every change must have test coverage** — no exception. If a feature or fix has no test case, it is not done.
3. **Minor changes** — if the change is very small (e.g. a one-line rename, doc fix), ask the user before skipping superpowers. Even then, TDD still applies: write the test first.

## Build & Test Commands

```bash
# Build
swift build

# Test
swift test

# Run a single test
swift test --filter NMTPTests.<TestClassName>/<testMethodName>
```

## Platform Policy: Linux First

This package is the wire protocol layer for the Nebula framework. It runs on Linux as server infrastructure.

- **Do not use Apple-only APIs** — no `import os`, no `OSAllocatedUnfairLock`, no macOS-only Foundation types.
- **Use cross-platform Swift stdlib and open-source packages only.** Use `Synchronization.Mutex` for synchronous locking.
- **macOS is development-only.** Minimum `.macOS(.v15)` is set solely for `Synchronization.Mutex` compatibility during local development.

## WebSocket Transport — Naming Conventions

Introduced 2026-04-10. Applies to all WebSocket-related code in `swift-nmtp`.

| Concept | Name |
|---------|------|
| Transport selector enum | `NMTTransport` (`.tcp` / `.webSocket(path:)`) |
| Frame bridge handler | `NMTWebSocketFrameHandler` (in `Sources/NMTP/Transport/`) |
| Server pipeline builder | `NMTServer.buildWebSocketServerPipeline` (private static) |
| Client connect helper | `NMTClient.connectWebSocket` (private static) |

**Binary-only rule:** The WebSocket layer uses `.binary` frames exclusively. Any frame whose opcode is not `.binary` (including text, continuation, ping, pong, and close) is silently dropped on the inbound path by `NMTWebSocketFrameHandler`. Heartbeat handling for WebSocket connections is out of scope for this implementation; `IdleStateHandler`/`HeartbeatHandler` are not added to the WebSocket pipeline.

**Masking rule:** Client → server frames are always masked (RFC 6455 §5.3). Server → client frames are never masked. `NMTWebSocketFrameHandler(isClient:)` controls this.

**Heartbeat:** `IdleStateHandler`/`HeartbeatHandler` are present in the TCP pipeline but intentionally omitted from the WebSocket pipeline (out of scope for initial implementation).
