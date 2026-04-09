import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
}
