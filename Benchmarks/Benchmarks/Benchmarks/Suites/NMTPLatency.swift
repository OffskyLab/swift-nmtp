import Benchmark
import NMTP

func registerNMTPLatency() {
    for (name, body) in [
        ("Small",  Payloads.small),
        ("Medium", Payloads.medium),
        ("Large",  Payloads.large),
    ] {
        nonisolated(unsafe) var echoRef: NMTPEchoServer?

        Benchmark(
            "NMTP/Latency/\(name)",
            configuration: .init(
                metrics: [.wallClock, .cpuTotal],
                scalingFactor: .kilo
            ),
            closure: { (benchmark: Benchmark, echo: NMTPEchoServer) in
                let matter = Matter(type: .command, payload: body)
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
