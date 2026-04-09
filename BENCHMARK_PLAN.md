# Benchmark Plan — NMTP vs HTTP

## Goal

Benchmark NMTP (binary protocol, 27-byte header + MessagePack) against HTTP, to quantify the performance advantage of the custom wire protocol.

## What to Measure

1. **Throughput** — requests/second (request/reply round-trips)
2. **Latency** — p50 / p95 / p99 for single request → reply
3. **Payload overhead** — actual bytes on wire for same logical payload (NMTP vs HTTP)
4. **Concurrent connections** — performance under multiple simultaneous connections

## Recommended Approach

### Tooling

Use [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark) — Swift ecosystem standard benchmark framework with automatic statistics, comparison between runs, and CI integration.

### Targets to Add

- `Benchmarks/` directory with a benchmark executable target

### NMTP Side

- Echo server: receives `call` Matter → replies with `reply` Matter (same payload echoed back)
- Client: connects and sends N request/reply cycles

### HTTP Side

- Minimal echo server using **Hummingbird** (lightweight, also NIO-based — fair comparison at transport layer)
- Client using **AsyncHTTPClient** sending same payload to echo endpoint

### Payload Sizes to Test

| Size   | Bytes |
|--------|-------|
| Small  | 64 B  |
| Medium | 1 KB  |
| Large  | 64 KB |

### Why These Choices

- **ordo-one** gives proper statistical output without manual timing code
- **Hummingbird** is NIO-based like NMTP, so the comparison isolates protocol overhead rather than framework differences
- Three payload sizes capture both header-dominated (small) and body-dominated (large) scenarios
