import Benchmark

func registerHTTPConcurrent() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        for concurrency in [2, 4, 8] {
            nonisolated(unsafe) var echoRef: HTTPConcurrentEchoServer?

            Benchmark(
                "HTTP/Concurrent\(concurrency)/\(name)",
                closure: { (benchmark: Benchmark, echo: HTTPConcurrentEchoServer) in
                    for _ in benchmark.scaledIterations {
                        do {
                            try echo.syncConcurrentRequest(body: body)
                        } catch {
                            benchmark.error("syncConcurrentRequest failed: \(error)")
                            return
                        }
                    }
                },
                setup: {
                    let echo = try await HTTPConcurrentEchoServer.start(concurrency: concurrency)
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
}
