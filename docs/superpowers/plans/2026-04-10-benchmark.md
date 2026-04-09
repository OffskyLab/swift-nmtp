# Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `Benchmarks/` package using ordo-one/package-benchmark that measures NMTP vs HTTP performance across throughput, latency, and concurrency scenarios, with CI integration that posts results on PRs.

**Architecture:** An independent Swift package at `Benchmarks/` depends on the root `NMTP` target, Hummingbird, and AsyncHTTPClient. Benchmarks are named `{Protocol}/{Metric}/{Param}` so ordo-one groups them by protocol in its HTML output. Setup/teardown (server start, client connect) occurs outside the `scaledIterations` loop and is not measured. Each suite registers benchmarks via a plain function called from the top-level `let benchmarks` closure.

**Tech Stack:** ordo-one/package-benchmark 1.x, Hummingbird 2.x, async-http-client 1.x, SwiftNIO, MessagePacker (from root package).

---

## File Map

| File | Purpose |
|------|---------|
| `Benchmarks/Package.swift` | Independent package manifest with all dependencies |
| `Benchmarks/Sources/Benchmarks/Benchmarks.swift` | Top-level `let benchmarks` closure — calls all suite registration functions |
| `Benchmarks/Sources/Benchmarks/Helpers/Payloads.swift` | Pre-built MessagePack payloads for Small/Medium/Large sizes |
| `Benchmarks/Sources/Benchmarks/Helpers/EchoHandler.swift` | NMTP `NMTHandler` that echoes call → reply (copied from Tests/) |
| `Benchmarks/Sources/Benchmarks/Helpers/NMTPEchoServer.swift` | Helper struct: start/stop NMTP server + client pair |
| `Benchmarks/Sources/Benchmarks/Helpers/HTTPEchoServer.swift` | Helper struct: start/stop Hummingbird echo server on fixed port |
| `Benchmarks/Sources/Benchmarks/Suites/NMTPThroughput.swift` | `NMTP/Throughput/Small|Medium|Large` |
| `Benchmarks/Sources/Benchmarks/Suites/HTTPThroughput.swift` | `HTTP/Throughput/Small|Medium|Large` |
| `Benchmarks/Sources/Benchmarks/Suites/NMTPLatency.swift` | `NMTP/Latency/Small|Medium|Large` |
| `Benchmarks/Sources/Benchmarks/Suites/HTTPLatency.swift` | `HTTP/Latency/Small|Medium|Large` |
| `Benchmarks/Sources/Benchmarks/Suites/NMTPConcurrent.swift` | `NMTP/Concurrent/MultiClient/4|16|64` and `Pipeline/10|100` |
| `Benchmarks/Sources/Benchmarks/Suites/HTTPConcurrent.swift` | `HTTP/Concurrent/MultiClient/4|16|64` and `Pipeline/10|100` |
| `.github/workflows/benchmark.yml` | CI: run on PR (post comment), save baseline on main merge |

---

## Task 1: Scaffold Benchmarks/Package.swift and minimal entry point

**Files:**
- Create: `Benchmarks/Package.swift`
- Create: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

- [ ] **Step 1: Create `Benchmarks/Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.22.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "Benchmarks",
            dependencies: [
                .product(name: "NMTP", package: "swift-nmtp"),
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/Benchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create minimal `Benchmarks/Sources/Benchmarks/Benchmarks.swift`**

This is the single file that declares the top-level `benchmarks` closure the ordo-one plugin discovers. It delegates to registration functions defined in each suite file. For now it is empty — we will fill in calls as we add suites.

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    // Suite registrations added in later tasks
}
```

- [ ] **Step 3: Verify the package builds**

Run:
```bash
swift package --package-path Benchmarks resolve
swift package --package-path Benchmarks build
```

Expected: builds without errors (no benchmarks run yet).

- [ ] **Step 4: Commit**

```bash
git add Benchmarks/
git commit -m "[ADD] Benchmarks: scaffold Package.swift and empty entry point"
```

---

## Task 2: Add Payload and EchoHandler helpers

**Files:**
- Create: `Benchmarks/Sources/Benchmarks/Helpers/Payloads.swift`
- Create: `Benchmarks/Sources/Benchmarks/Helpers/EchoHandler.swift`

- [ ] **Step 1: Create `Helpers/Payloads.swift`**

Payloads are pre-computed constants — not generated inside the benchmark loop — so they are never included in timing.

The MessagePack structure is `{"data": <bytes>}`. We use `MessagePacker` (available via the root `NMTP` package's transitive dependency).

```swift
import Foundation
import MessagePacker
import NMTP

/// Pre-built MessagePack payloads for benchmark use.
/// Never regenerate inside a benchmark loop — pass these constants directly.
enum Payloads {
    struct Echo: Codable {
        let data: Data
    }

    static let small: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 52))   // 52 B data → ~64 B encoded
        return (try? MessagePackEncoder().encode(payload)) ?? Data()
    }()

    static let medium: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 1012)) // 1012 B data → ~1 KB encoded
        return (try? MessagePackEncoder().encode(payload)) ?? Data()
    }()

    static let large: Data = {
        let payload = Echo(data: Data(repeating: 0xAB, count: 65524)) // 65524 B data → ~64 KB encoded
        return (try? MessagePackEncoder().encode(payload)) ?? Data()
    }()

    /// Wire-size comparison for README table.
    static func printOverheadTable() {
        let httpHeaderEstimate = 130 // typical HTTP/1.1 POST header bytes
        print("| Payload | NMTP wire | HTTP wire |")
        print("|---------|-----------|-----------|")
        for (label, body) in [("Small", small), ("Medium", medium), ("Large", large)] {
            let nmtp = Matter.headerSize + body.count
            let http = httpHeaderEstimate + body.count
            print("| \(label) | \(nmtp) B | \(http) B |")
        }
    }
}
```

- [ ] **Step 2: Create `Helpers/EchoHandler.swift`**

Copied from `Tests/NMTPTests/TestHelpers.swift`. Cannot import the test target from a separate package, so we duplicate it here.

```swift
import NIO
import NMTP

/// Echoes each incoming .call Matter back as .reply with the same matterID and body.
struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(type: .reply, matterID: matter.matterID, body: matter.body)
    }
}
```

- [ ] **Step 3: Verify both files compile**

```bash
swift package --package-path Benchmarks build
```

Expected: builds without errors.

- [ ] **Step 4: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/Helpers/
git commit -m "[ADD] Benchmarks: Payloads + EchoHandler helpers"
```

---

## Task 3: Add NMTPEchoServer helper + first NMTP benchmark

**Files:**
- Create: `Benchmarks/Sources/Benchmarks/Helpers/NMTPEchoServer.swift`
- Create: `Benchmarks/Sources/Benchmarks/Suites/NMTPThroughput.swift` (partial — Small only)
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

- [ ] **Step 1: Create `Helpers/NMTPEchoServer.swift`**

```swift
import NIO
import NMTP

/// Owns a paired NMTP server + client for use in benchmark setUp/tearDown.
/// Create before `scaledIterations`, tear down after.
struct NMTPEchoServer {
    let client: NMTClient
    private let server: NMTServer
    private let elg: MultiThreadedEventLoopGroup

    /// Starts the NMTP echo server and connects a client to it.
    /// Not measured — call this before `benchmark.scaledIterations`.
    static func start(threads: Int = 2) async throws -> NMTPEchoServer {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        let server = try await NMTServer.bind(
            on: .makeAddressResolvingHost("127.0.0.1", port: 0),
            handler: EchoHandler(),
            eventLoopGroup: elg
        )
        let client = try await NMTClient.connect(to: server.address, eventLoopGroup: elg)
        return NMTPEchoServer(client: client, server: server, elg: elg)
    }

    /// Stops the client, server, and ELG.
    /// Not measured — call this after `benchmark.scaledIterations`.
    func stop() async throws {
        try await client.close()
        try await server.stop()
        try await elg.shutdownGracefully()
    }
}
```

- [ ] **Step 2: Create `Suites/NMTPThroughput.swift` with Small benchmark only**

```swift
import Benchmark
import NMTP

func registerNMTPThroughput() {
    Benchmark("NMTP/Throughput/Small") { benchmark in
        let echo = try await NMTPEchoServer.start()
        let matter = Matter(type: .call, body: Payloads.small)
        for _ in benchmark.scaledIterations {
            _ = try await echo.client.request(matter: matter)
        }
        try await echo.stop()
    }
}
```

- [ ] **Step 3: Wire it into `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
}
```

- [ ] **Step 4: Run the benchmark to verify the pipeline works end to end**

```bash
swift package --package-path Benchmarks benchmark --filter "NMTP/Throughput/Small"
```

Expected: benchmark runs, prints throughput and latency statistics without errors.

- [ ] **Step 5: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/
git commit -m "[ADD] Benchmarks: NMTPEchoServer helper + NMTP/Throughput/Small"
```

---

## Task 4: Add HTTPEchoServer helper + first HTTP benchmark

**Files:**
- Create: `Benchmarks/Sources/Benchmarks/Helpers/HTTPEchoServer.swift`
- Create: `Benchmarks/Sources/Benchmarks/Suites/HTTPThroughput.swift` (partial — Small only)
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

- [ ] **Step 1: Create `Helpers/HTTPEchoServer.swift`**

Uses Hummingbird 2.x with a fixed port. The server is started in a background `Task` and given 100ms to bind before the benchmark begins. Port 18765 is reserved for this benchmark suite; change it if that port is already in use on your machine.

```swift
import Hummingbird
import NIOCore

/// Owns a Hummingbird echo server running on a fixed local port.
struct HTTPEchoServer {
    static let host = "127.0.0.1"
    static let port = 18765
    static var baseURL: String { "http://\(host):\(port)" }

    private let task: Task<Void, Error>

    /// Starts the HTTP echo server. Not measured.
    static func start() async throws -> HTTPEchoServer {
        let router = Router()
        router.post("/echo") { request, _ async throws -> ByteBuffer in
            try await request.body.collect(upTo: 10 * 1024 * 1024)
        }
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        let task = Task { try await app.runService() }
        // Give the server time to bind before the benchmark starts sending requests.
        try await Task.sleep(for: .milliseconds(100))
        return HTTPEchoServer(task: task)
    }

    /// Cancels the server task. Not measured.
    func stop() async throws {
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
    }
}
```

- [ ] **Step 2: Create `Suites/HTTPThroughput.swift` with Small benchmark only**

```swift
import AsyncHTTPClient
import Benchmark
import NIOCore

func registerHTTPThroughput() {
    Benchmark("HTTP/Throughput/Small") { benchmark in
        let server = try await HTTPEchoServer.start()
        let httpClient = HTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        var request = HTTPClientRequest(url: "\(HTTPEchoServer.baseURL)/echo")
        request.method = .POST
        request.body = .bytes(ByteBuffer(data: Payloads.small))

        for _ in benchmark.scaledIterations {
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            _ = try await response.body.collect(upTo: 10 * 1024 * 1024)
        }

        try await server.stop()
    }
}
```

- [ ] **Step 3: Wire it into `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerHTTPThroughput()
}
```

- [ ] **Step 4: Run the HTTP benchmark to verify**

```bash
swift package --package-path Benchmarks benchmark --filter "HTTP/Throughput/Small"
```

Expected: benchmark runs and produces output comparable to the NMTP run.

- [ ] **Step 5: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/
git commit -m "[ADD] Benchmarks: HTTPEchoServer helper + HTTP/Throughput/Small"
```

---

## Task 5: Complete NMTP Throughput + Latency suites

**Files:**
- Modify: `Benchmarks/Sources/Benchmarks/Suites/NMTPThroughput.swift`
- Create: `Benchmarks/Sources/Benchmarks/Suites/NMTPLatency.swift`
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

Throughput benchmarks use default ordo-one configuration (maximise iterations). Latency benchmarks use `BenchmarkMetric.wallClock` only and a higher warmup count to stabilise per-iteration timing. Both run the same sequential request/reply loop — the configuration controls which stats are highlighted in reports.

- [ ] **Step 1: Expand `NMTPThroughput.swift` to all three payload sizes**

```swift
import Benchmark
import NMTP

func registerNMTPThroughput() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        Benchmark("NMTP/Throughput/\(name)") { benchmark in
            let echo = try await NMTPEchoServer.start()
            let matter = Matter(type: .call, body: body)
            for _ in benchmark.scaledIterations {
                _ = try await echo.client.request(matter: matter)
            }
            try await echo.stop()
        }
    }
}
```

- [ ] **Step 2: Create `NMTPLatency.swift`**

```swift
import Benchmark
import NMTP

func registerNMTPLatency() {
    let config = Benchmark.Configuration(
        metrics: [.wallClock],
        warmupIterations: 10
    )
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        Benchmark("NMTP/Latency/\(name)", configuration: config) { benchmark in
            let echo = try await NMTPEchoServer.start()
            let matter = Matter(type: .call, body: body)
            for _ in benchmark.scaledIterations {
                _ = try await echo.client.request(matter: matter)
            }
            try await echo.stop()
        }
    }
}
```

- [ ] **Step 3: Wire into `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerNMTPLatency()
    registerHTTPThroughput()
}
```

- [ ] **Step 4: Run all NMTP throughput + latency benchmarks**

```bash
swift package --package-path Benchmarks benchmark --filter "NMTP/Throughput"
swift package --package-path Benchmarks benchmark --filter "NMTP/Latency"
```

Expected: 3 throughput + 3 latency benchmarks each complete without errors and produce p50/p95/p99 statistics.

- [ ] **Step 5: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/Suites/NMTPThroughput.swift \
        Benchmarks/Sources/Benchmarks/Suites/NMTPLatency.swift \
        Benchmarks/Sources/Benchmarks/Benchmarks.swift
git commit -m "[ADD] Benchmarks: NMTP/Throughput and NMTP/Latency suites (Small/Medium/Large)"
```

---

## Task 6: Complete HTTP Throughput + Latency suites

**Files:**
- Modify: `Benchmarks/Sources/Benchmarks/Suites/HTTPThroughput.swift`
- Create: `Benchmarks/Sources/Benchmarks/Suites/HTTPLatency.swift`
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

- [ ] **Step 1: Expand `HTTPThroughput.swift` to all three payload sizes**

```swift
import AsyncHTTPClient
import Benchmark
import NIOCore

func registerHTTPThroughput() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        Benchmark("HTTP/Throughput/\(name)") { benchmark in
            let server = try await HTTPEchoServer.start()
            let httpClient = HTTPClient()

            var request = HTTPClientRequest(url: "\(HTTPEchoServer.baseURL)/echo")
            request.method = .POST
            request.body = .bytes(ByteBuffer(data: body))

            for _ in benchmark.scaledIterations {
                let response = try await httpClient.execute(request, timeout: .seconds(30))
                _ = try await response.body.collect(upTo: 10 * 1024 * 1024)
            }

            try await httpClient.shutdown()
            try await server.stop()
        }
    }
}
```

- [ ] **Step 2: Create `HTTPLatency.swift`**

```swift
import AsyncHTTPClient
import Benchmark
import NIOCore

func registerHTTPLatency() {
    let config = Benchmark.Configuration(
        metrics: [.wallClock],
        warmupIterations: 10
    )
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        Benchmark("HTTP/Latency/\(name)", configuration: config) { benchmark in
            let server = try await HTTPEchoServer.start()
            let httpClient = HTTPClient()

            var request = HTTPClientRequest(url: "\(HTTPEchoServer.baseURL)/echo")
            request.method = .POST
            request.body = .bytes(ByteBuffer(data: body))

            for _ in benchmark.scaledIterations {
                let response = try await httpClient.execute(request, timeout: .seconds(30))
                _ = try await response.body.collect(upTo: 10 * 1024 * 1024)
            }

            try await httpClient.shutdown()
            try await server.stop()
        }
    }
}
```

- [ ] **Step 3: Wire into `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerNMTPLatency()
    registerHTTPThroughput()
    registerHTTPLatency()
}
```

- [ ] **Step 4: Run all HTTP throughput + latency benchmarks**

```bash
swift package --package-path Benchmarks benchmark --filter "HTTP/Throughput"
swift package --package-path Benchmarks benchmark --filter "HTTP/Latency"
```

Expected: 6 benchmarks complete without errors.

- [ ] **Step 5: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/Suites/HTTPThroughput.swift \
        Benchmarks/Sources/Benchmarks/Suites/HTTPLatency.swift \
        Benchmarks/Sources/Benchmarks/Benchmarks.swift
git commit -m "[ADD] Benchmarks: HTTP/Throughput and HTTP/Latency suites (Small/Medium/Large)"
```

---

## Task 7: Implement NMTP Concurrent suite

**Files:**
- Create: `Benchmarks/Sources/Benchmarks/Suites/NMTPConcurrent.swift`
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

All concurrent benchmarks use the Medium (1 KB) payload.

- [ ] **Step 1: Create `NMTPConcurrent.swift`**

```swift
import Benchmark
import NIO
import NMTP

func registerNMTPConcurrent() {
    // MultiClient: N independent NMTClient instances sending simultaneously.
    // Each iteration: all N clients fire one request concurrently, wait for all replies.
    for n in [4, 16, 64] {
        Benchmark("NMTP/Concurrent/MultiClient/\(n)") { benchmark in
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let server = try await NMTServer.bind(
                on: .makeAddressResolvingHost("127.0.0.1", port: 0),
                handler: EchoHandler(),
                eventLoopGroup: elg
            )
            var clients: [NMTClient] = []
            for _ in 0..<n {
                clients.append(try await NMTClient.connect(to: server.address, eventLoopGroup: elg))
            }

            for _ in benchmark.scaledIterations {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for client in clients {
                        group.addTask {
                            _ = try await client.request(
                                matter: Matter(type: .call, body: Payloads.medium)
                            )
                        }
                    }
                    try await group.waitForAll()
                }
            }

            for client in clients { try await client.close() }
            try await server.stop()
            try await elg.shutdownGracefully()
        }
    }

    // Pipeline: single client, M concurrent in-flight requests via async let.
    // Tests how well the server handles multiplexed requests from one connection.
    for m in [10, 100] {
        Benchmark("NMTP/Concurrent/Pipeline/\(m)") { benchmark in
            let echo = try await NMTPEchoServer.start(threads: System.coreCount)

            for _ in benchmark.scaledIterations {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<m {
                        group.addTask {
                            _ = try await echo.client.request(
                                matter: Matter(type: .call, body: Payloads.medium)
                            )
                        }
                    }
                    try await group.waitForAll()
                }
            }

            try await echo.stop()
        }
    }
}
```

- [ ] **Step 2: Wire into `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerNMTPLatency()
    registerNMTPConcurrent()
    registerHTTPThroughput()
    registerHTTPLatency()
}
```

- [ ] **Step 3: Run NMTP concurrent benchmarks**

```bash
swift package --package-path Benchmarks benchmark --filter "NMTP/Concurrent"
```

Expected: 5 benchmarks (MultiClient/4, 16, 64 and Pipeline/10, 100) complete without errors. MultiClient/64 will be slow — that is expected.

- [ ] **Step 4: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/Suites/NMTPConcurrent.swift \
        Benchmarks/Sources/Benchmarks/Benchmarks.swift
git commit -m "[ADD] Benchmarks: NMTP/Concurrent suite (MultiClient + Pipeline)"
```

---

## Task 8: Implement HTTP Concurrent suite

**Files:**
- Create: `Benchmarks/Sources/Benchmarks/Suites/HTTPConcurrent.swift`
- Modify: `Benchmarks/Sources/Benchmarks/Benchmarks.swift`

For HTTP, a single `HTTPClient` manages its own connection pool. To simulate N concurrent connections, we configure `maxConnectionsPerHost = N` so the pool opens N distinct TCP connections to the echo server.

- [ ] **Step 1: Create `HTTPConcurrent.swift`**

```swift
import AsyncHTTPClient
import Benchmark
import NIOCore

func registerHTTPConcurrent() {
    // MultiClient: N concurrent connections via a single HTTPClient connection pool.
    for n in [4, 16, 64] {
        Benchmark("HTTP/Concurrent/MultiClient/\(n)") { benchmark in
            let server = try await HTTPEchoServer.start()
            let config = HTTPClient.Configuration(
                connectionPool: .init(concurrentHTTP1ConnectionsPerHostSoftLimit: n)
            )
            let httpClient = HTTPClient(configuration: config)

            var request = HTTPClientRequest(url: "\(HTTPEchoServer.baseURL)/echo")
            request.method = .POST
            request.body = .bytes(ByteBuffer(data: Payloads.medium))

            for _ in benchmark.scaledIterations {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<n {
                        group.addTask {
                            let response = try await httpClient.execute(
                                request, timeout: .seconds(30)
                            )
                            _ = try await response.body.collect(upTo: 10 * 1024 * 1024)
                        }
                    }
                    try await group.waitForAll()
                }
            }

            try await httpClient.shutdown()
            try await server.stop()
        }
    }

    // Pipeline: M concurrent requests from a single connection.
    for m in [10, 100] {
        Benchmark("HTTP/Concurrent/Pipeline/\(m)") { benchmark in
            let server = try await HTTPEchoServer.start()
            let httpClient = HTTPClient()

            var request = HTTPClientRequest(url: "\(HTTPEchoServer.baseURL)/echo")
            request.method = .POST
            request.body = .bytes(ByteBuffer(data: Payloads.medium))

            for _ in benchmark.scaledIterations {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<m {
                        group.addTask {
                            let response = try await httpClient.execute(
                                request, timeout: .seconds(30)
                            )
                            _ = try await response.body.collect(upTo: 10 * 1024 * 1024)
                        }
                    }
                    try await group.waitForAll()
                }
            }

            try await httpClient.shutdown()
            try await server.stop()
        }
    }
}
```

- [ ] **Step 2: Wire all suites into final `Benchmarks.swift`**

```swift
import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerNMTPLatency()
    registerNMTPConcurrent()
    registerHTTPThroughput()
    registerHTTPLatency()
    registerHTTPConcurrent()
}
```

- [ ] **Step 3: Run HTTP concurrent benchmarks**

```bash
swift package --package-path Benchmarks benchmark --filter "HTTP/Concurrent"
```

Expected: 5 benchmarks complete without errors.

- [ ] **Step 4: Run all 22 benchmarks to confirm nothing is broken**

```bash
swift package --package-path Benchmarks benchmark
```

Expected: all 22 benchmarks listed and completed. Note: this will take several minutes.

- [ ] **Step 5: Save initial baseline**

```bash
swift package --package-path Benchmarks benchmark baseline update --no-progress
```

Expected: baseline saved to `.benchmarkBaselines/` inside the `Benchmarks/` directory.

- [ ] **Step 6: Commit**

```bash
git add Benchmarks/Sources/Benchmarks/Suites/HTTPConcurrent.swift \
        Benchmarks/Sources/Benchmarks/Benchmarks.swift
git commit -m "[ADD] Benchmarks: HTTP/Concurrent suite (MultiClient + Pipeline)"
```

---

## Task 9: Add GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/benchmark.yml`

- [ ] **Step 1: Create `.github/workflows/benchmark.yml`**

```yaml
name: Benchmarks

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  benchmark-pr:
    name: Benchmark (PR)
    if: github.event_name == 'pull_request'
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Download main baseline (if available)
        uses: actions/download-artifact@v4
        with:
          name: benchmark-baseline
          path: Benchmarks/.benchmarkBaselines
        continue-on-error: true  # First PR has no baseline yet

      - name: Run benchmarks
        run: |
          swift package --package-path Benchmarks benchmark \
            baseline update --no-progress

      - name: Compare against main baseline
        id: compare
        run: |
          swift package --package-path Benchmarks benchmark \
            baseline check --no-progress 2>&1 | tee benchmark-report.txt || true

      - name: Post benchmark report as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const report = fs.existsSync('benchmark-report.txt')
              ? fs.readFileSync('benchmark-report.txt', 'utf8')
              : 'No baseline available for comparison yet.';
            const body = `## Benchmark Results\n\`\`\`\n${report}\n\`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body,
            });

      - name: Upload current run as artifact
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-pr-${{ github.event.pull_request.number }}
          path: Benchmarks/.benchmarkBaselines/
          retention-days: 7

  benchmark-main:
    name: Benchmark (main)
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Run benchmarks and save baseline
        run: |
          swift package --package-path Benchmarks benchmark \
            baseline update --no-progress

      - name: Upload baseline as artifact
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-baseline
          path: Benchmarks/.benchmarkBaselines/
          retention-days: 30
```

- [ ] **Step 2: Add `.benchmarkBaselines/` to `.gitignore` (baselines are tracked via CI artifacts, not git)**

Check if `.gitignore` exists at the root:

```bash
# If .gitignore exists, add this line:
echo ".benchmarkBaselines/" >> .gitignore
# If it doesn't exist yet:
echo ".benchmarkBaselines/" > .gitignore
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/benchmark.yml .gitignore
git commit -m "[ADD] CI: benchmark workflow — post results on PR, save baseline on main"
```

---

## Spec Coverage Verification

| Spec requirement | Implemented in |
|-----------------|---------------|
| Throughput (req/s) | Tasks 5, 6 — `*/Throughput/*` benchmarks |
| Latency p50/p95/p99 | Tasks 5, 6 — `*/Latency/*` benchmarks with `.wallClock` metric |
| Payload overhead table | Task 2 — `Payloads.printOverheadTable()` |
| Concurrent MultiClient | Tasks 7, 8 — `*/Concurrent/MultiClient/4|16|64` |
| Concurrent Pipeline | Tasks 7, 8 — `*/Concurrent/Pipeline/10|100` |
| 64B / 1KB / 64KB payloads | Task 2 — `Payloads.small/medium/large` |
| Structured MessagePack | Task 2 — `Payloads.Echo` Codable struct |
| Hummingbird + AsyncHTTPClient | Tasks 4, 6, 8 |
| ordo-one/package-benchmark | Task 1 |
| Independent `Benchmarks/` package | Task 1 |
| CI: post results on PR | Task 9 |
| CI: save baseline on main | Task 9 |
| CI: do not auto-fail | Task 9 — `continue-on-error: true` + no threshold |
| Benchmark naming `{Protocol}/{Metric}/{Param}` | All suite tasks |
