# Proposal: Stream Multiplexing

**Date:** 2026-04-10
**Priority:** Low (scale)
**Status:** Proposed

## Problem

All requests and pushes share a single TCP connection. A slow request (e.g., large file transfer) blocks all subsequent messages — head-of-line (HOL) blocking.

HTTP/2 solves this with stream multiplexing over a single connection. NMT currently has no equivalent.

## Proposal

Add a stream ID to the Matter header:

```
Current header (27 bytes):
| Magic (4) | Version (1) | Type (1) | Flags (1) | MatterID (16) | Length (4) |

Proposed header (29 bytes):
| Magic (4) | Version (1) | Type (1) | Flags (1) | StreamID (2) | MatterID (16) | Length (4) |
```

- StreamID 0 = control stream (heartbeat, version negotiation)
- StreamID 1+ = data streams, each independent
- Receiver processes streams concurrently
- Per-stream flow control (combined with backpressure proposal)

## Impact

- Breaking wire format change (version 2) — requires version negotiation first
- Significant complexity increase
- Only needed at high concurrency (100+ concurrent requests)
- Don't implement until there's a measured need
