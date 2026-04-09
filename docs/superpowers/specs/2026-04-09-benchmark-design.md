# Benchmark Design — NMTP vs HTTP

**Date:** 2026-04-09  
**Status:** Approved

---

## Goal

Quantify the performance advantage of NMTP (binary protocol, 27-byte header + MessagePack) against HTTP, for both external showcase (README/blog) and CI regression detection.

---

## Metrics

| Metric | Description |
|--------|-------------|
| Throughput | requests/second (sequential request/reply cycles) |
| Latency | p50 / p95 / p99 per single round-trip |
| Payload overhead | actual bytes on wire for the same logical payload |
| Concurrent connections | throughput under N simultaneous clients and M pipelined requests |

---

## Technology Choices

| Side | Server | Client |
|------|--------|--------|
| NMTP | `NMTServer` + `EchoHandler` | `NMTClient` |
| HTTP | Hummingbird (~> 2.0) | AsyncHTTPClient |

**Rationale:** Both Hummingbird and NMTP are NIO-based, isolating protocol overhead rather than framework differences. Hummingbird adds negligible overhead in a simple echo scenario.

**Tooling:** [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark) — Swift ecosystem standard with automatic statistics, baseline comparison, and CI integration.

---

## Directory Structure

```
Benchmarks/
  Package.swift                   ← independent package
  Sources/
    Benchmarks/
      main.swift                  ← ordo-one entry point
      Suites/
        NMTPThroughput.swift      ← NMTP/Throughput/*
        NMTPLatency.swift         ← NMTP/Latency/*
        NMTPConcurrent.swift      ← NMTP/Concurrent/*
        HTTPThroughput.swift      ← HTTP/Throughput/*
        HTTPLatency.swift         ← HTTP/Latency/*
        HTTPConcurrent.swift      ← HTTP/Concurrent/*
      Helpers/
        NMTPEchoServer.swift      ← NMTServer + EchoHandler, setUp/tearDown
        HTTPEchoServer.swift      ← Hummingbird echo server, setUp/tearDown
        Payloads.swift            ← payload generators for all three sizes
```

`Benchmarks/Package.swift` dependencies:
- `../` (root package, `NMTP` target)
- `hummingbird` (~> 2.0)
- `async-http-client`
- `package-benchmark`

---

## Benchmark Naming

Format: `{Protocol}/{Metric}/{PayloadSize}` or `{Protocol}/{Metric}/{Mode}/{Param}`

This lets ordo-one's HTML reports and PR comments group results by protocol automatically.

---

## Payload Sizes

| Label | Bytes | MessagePack structure |
|-------|-------|-----------------------|
| Small | 64 B | `{"data": <52 bytes>}` |
| Medium | 1 KB | `{"data": <1012 bytes>}` |
| Large | 64 KB | `{"data": <65524 bytes>}` |

Payloads are generated once before benchmarks start (not counted in measurement time).

---

## Benchmark Suites (22 total)

### Throughput (6)

Single client, sequential request/reply cycles. ordo-one measures iterations/second.

```
NMTP/Throughput/Small
NMTP/Throughput/Medium
NMTP/Throughput/Large
HTTP/Throughput/Small
HTTP/Throughput/Medium
HTTP/Throughput/Large
```

### Latency (6)

Single request → wait for reply, repeated N times. ordo-one outputs p50/p95/p99.

```
NMTP/Latency/Small
NMTP/Latency/Medium
NMTP/Latency/Large
HTTP/Latency/Small
HTTP/Latency/Medium
HTTP/Latency/Large
```

### Concurrent (10)

**MultiClient** — N independent clients, each with its own channel, sending concurrently.  
Tests server throughput under multiple simultaneous connections.  
Fixed payload: **Medium (1 KB)** — representative of real-world use without being header- or body-dominated.

```
NMTP/Concurrent/MultiClient/4
NMTP/Concurrent/MultiClient/16
NMTP/Concurrent/MultiClient/64
HTTP/Concurrent/MultiClient/4
HTTP/Concurrent/MultiClient/16
HTTP/Concurrent/MultiClient/64
```

**Pipeline** — Single client, M concurrent requests via `async let`.  
Tests client-side multiplexing.  
Fixed payload: **Medium (1 KB)**.

```
NMTP/Concurrent/Pipeline/10
NMTP/Concurrent/Pipeline/100
HTTP/Concurrent/Pipeline/10
HTTP/Concurrent/Pipeline/100
```

### Payload Overhead (static, not ordo-one)

Computed in `Payloads.swift` and printed as a comparison table for the README:
- NMTP wire size = 27 (fixed header) + MessagePack body
- HTTP wire size = estimated HTTP/1.1 header + body

---

## Server Helpers

### setUp / tearDown pattern (all suites)

1. Create a shared `MultiThreadedEventLoopGroup` (passed to both server and client to avoid duplicate thread pools)
2. `setUp`: start server → connect client
3. benchmark closure: run measurement logic
4. `tearDown`: close client → stop server → shutdown ELG

### NMTPEchoServer

`EchoHandler` receives a `.call` Matter and replies with a `.reply` Matter carrying the same body. Reuses the `EchoHandler` already present in `Tests/`.

### HTTPEchoServer

Hummingbird router with a single `POST /echo` route that returns the request body unchanged. Client uses `AsyncHTTPClient.HTTPClient`.

---

## CI Integration

### Strategy

- **On PR:** Run benchmarks, post results as PR comment (job summary). Do not auto-fail.
- **On push to main:** Run benchmarks, save baseline as GitHub Actions artifact (30-day retention).

This avoids false positives from noisy cloud CI runners. Once the baseline stabilises over several releases, an auto-fail threshold can be added.

### Workflow: `.github/workflows/benchmark.yml`

**Job: `benchmark-pr`** (trigger: `pull_request`)
1. Download latest main baseline from artifacts (if available)
2. Run benchmarks: `swift package --package-path Benchmarks benchmark baseline update --no-progress`
3. If baseline exists: `swift package --package-path Benchmarks benchmark baseline check` → post report to PR comment
4. Upload current run as artifact

**Job: `benchmark-main`** (trigger: `push` to `main`)
1. Run benchmarks
2. Save as named baseline artifact

### Local Commands

```bash
# Run all benchmarks
swift package --package-path Benchmarks benchmark

# Save baseline
swift package --package-path Benchmarks benchmark baseline update

# Compare two baselines
swift package --package-path Benchmarks benchmark baseline check

# Run specific benchmarks
swift package --package-path Benchmarks benchmark --filter "NMTP/Latency"
```

---

## README Integration

The payload overhead table and latest throughput/latency numbers from main are manually updated in the README (or automated via a CI commit step in a later iteration).
