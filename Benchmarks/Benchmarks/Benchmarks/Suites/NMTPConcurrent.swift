import Benchmark
import NMTP

func registerNMTPConcurrent() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        for concurrency in [2, 4, 8] {
            nonisolated(unsafe) var echoRef: NMTPConcurrentEchoServer?

            Benchmark(
                "NMTP/Concurrent\(concurrency)/\(name)",
                closure: { (benchmark: Benchmark, echo: NMTPConcurrentEchoServer) in
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
                    let echo = try await NMTPConcurrentEchoServer.start(concurrency: concurrency)
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
