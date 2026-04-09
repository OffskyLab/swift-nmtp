# Proposal: Heartbeat Implementation

**Date:** 2026-04-10
**Priority:** High (correctness)
**Status:** Proposed

## Problem

`MatterType.heartbeat` is defined but not implemented. Silent connection failures (kill -9, network drop without TCP RST) are undetectable until the next request times out — which could be never if no request is pending.

## Proposal

- Server sends heartbeat Matter at a configurable interval (default 10s)
- Client responds with heartbeat reply
- If N consecutive heartbeats are missed (default 3), connection is considered dead
- Dead connections trigger cleanup and optional reconnect callback

## API

```swift
NMTServer.bind(on:handler:tls:heartbeatInterval:)  // default 10s, nil to disable
NMTClient.connect(to:tls:heartbeatTimeout:)         // default 35s (3 missed + margin)
```

## Impact

- Fixes silent disconnect detection
- Required before any production use of Nebula
- orbital-sync currently works around this with push stream ending, but that's unreliable
