# Proposal: Structured Error Codes

**Date:** 2026-04-10
**Priority:** Medium (stability)
**Status:** Proposed

## Problem

`CallReplyBody.error` is `String?`. Callers can't distinguish between:
- Transient failure (retry makes sense)
- Permanent failure (don't retry)
- Not found (different handling)
- Timeout (backoff and retry)

## Proposal

Add an error code field alongside the message:

```swift
struct CallReplyBody: Codable, Sendable {
    let result: Data?
    let error: String?
    let errorCode: UInt16?  // new, nil = no error
}
```

Standard codes:

| Code | Name | Retry? |
|------|------|--------|
| 0 | success | — |
| 1 | unknown | maybe |
| 2 | not_found | no |
| 3 | invalid_argument | no |
| 4 | timeout | yes, with backoff |
| 5 | unavailable | yes |
| 6 | internal | maybe |
| 7 | unauthorized | no |

## Impact

- Backward compatible (new field is optional)
- Enables proper retry logic in callers
- Aligns with standard RPC error semantics (similar to gRPC status codes)
