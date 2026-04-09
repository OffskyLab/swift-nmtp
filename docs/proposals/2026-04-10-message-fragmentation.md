# Proposal: Message Fragmentation (Chunked Transfer)

**Date:** 2026-04-10
**Priority:** Low (scale)
**Status:** Proposed

## Problem

A Matter body must be fully loaded into memory before encoding (and fully received before decoding). Body length is 4 bytes (max ~4GB), but even a 100MB file would require 100MB of contiguous memory on both sides.

No streaming / chunked transfer exists.

## Proposal

Use the Flags byte in the header to indicate fragmentation:

```
Flags bit 0: 0 = complete message, 1 = fragment
Flags bit 1: 0 = more fragments follow, 1 = last fragment
```

- Sender splits large body into chunks (configurable, default 64KB)
- Each chunk is a Matter with the same MatterID, fragment flag set
- Receiver reassembles by MatterID, delivers to handler when last fragment arrives
- Optional: streaming handler API that receives chunks as they arrive

## Impact

- Wire compatible (Flags byte is currently unused/reserved)
- Enables large file transfer without OOM
- Adds complexity to MatterDecoder/MatterEncoder
- Only needed when transferring files > ~10MB
- Can be implemented independently of stream multiplexing
