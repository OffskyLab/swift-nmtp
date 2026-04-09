# Proposal: Backpressure

**Date:** 2026-04-10
**Priority:** Medium (stability)
**Status:** Proposed

## Problem

No flow control between sender and receiver. If one side produces Matter faster than the other can consume, the receiver's NIO channel buffers grow unbounded → OOM.

In orbital-sync this is unlikely (small files, low frequency). In Nebula microservice scenarios with high-throughput RPC, this is a real risk.

## Proposal

Leverage NIO's existing backpressure mechanisms:

- `ChannelOption.writeBufferWaterMark` — set high/low water marks
- When write buffer exceeds high water mark, `channelWritabilityChanged` fires
- Sender pauses producing until writability is restored

Implementation:
- `NMTClient.request()` checks `channel.isWritable` before sending
- If not writable, suspend (async/await) until writable again
- `NMTServer` handler signals upstream when it can't keep up

## Impact

- Prevents OOM under load
- NIO already has the primitives, just need to wire them up
- No wire protocol change needed
