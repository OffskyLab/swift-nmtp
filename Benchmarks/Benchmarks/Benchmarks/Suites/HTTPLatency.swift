import Benchmark

func registerHTTPLatency() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        nonisolated(unsafe) var echoRef: HTTPEchoServer?

        Benchmark(
            "HTTP/Latency/\(name)",
            configuration: .init(
                metrics: [.wallClock, .cpuTotal],
                scalingFactor: .kilo
            ),
            closure: { (benchmark: Benchmark, echo: HTTPEchoServer) in
                for _ in benchmark.scaledIterations {
                    do {
                        _ = try echo.syncRequest(body: body)
                    } catch {
                        benchmark.error("syncRequest failed: \(error)")
                        return
                    }
                }
            },
            setup: {
                let echo = try await HTTPEchoServer.start()
                echoRef = echo
                return echo
            },
            teardown: {
                try await echoRef?.stop()
                echoRef = nil
            }
        )
    }
}
