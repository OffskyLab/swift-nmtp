import Benchmark
import NMTP

func registerNMTPThroughput() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        // echoRef bridges setUp result to tearDown (API limitation: tearDown has no state param).
        nonisolated(unsafe) var echoRef: NMTPEchoServer?

        Benchmark(
            "NMTP/Throughput/\(name)",
            // Sync closure: run() calls it directly — no runAsync(), no
            // DispatchSemaphore.wait() blocking the cooperative thread pool.
            // NIO handles every round-trip on its own event-loop threads so
            // future.wait() inside syncRequest() never deadlocks.
            closure: { (benchmark: Benchmark, echo: NMTPEchoServer) in
                let matter = Matter(behavior: .command, payload: body)
                for _ in benchmark.scaledIterations {
                    do {
                        _ = try echo.syncRequest(matter)
                    } catch {
                        benchmark.error("syncRequest failed: \(error)")
                        return
                    }
                }
            },
            setup: {
                let echo = try await NMTPEchoServer.start()
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
