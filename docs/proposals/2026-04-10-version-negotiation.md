# Proposal: Version Negotiation

**Date:** 2026-04-10
**Priority:** High (correctness)
**Status:** Proposed

## Problem

Matter header has a version byte (currently hardcoded to 1), but there's no handshake to negotiate version on connect. If the protocol changes, old and new nodes will exchange incompatible bytes with no error — just silent corruption.

## Proposal

- On connection, client sends a version negotiation Matter as the first message
- Contains: min supported version, max supported version, client capabilities
- Server responds with the agreed version and capabilities
- All subsequent Matter uses the agreed version
- If no overlap, server rejects with an error and closes

## API

```swift
// Automatic — happens inside NMTClient.connect and NMTServer on accept
// No API change needed, just internal behavior

// For inspection:
client.negotiatedVersion  // UInt8
client.peerCapabilities   // Set<String>
```

## Impact

- Enables safe protocol evolution
- Must be done before v2 of the wire format, or there's no upgrade path
