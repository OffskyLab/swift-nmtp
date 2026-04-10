import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerNMTPThroughput()
    registerNMTPLatency()
    registerNMTPConcurrent()
    registerHTTPThroughput()
    registerHTTPLatency()
    registerHTTPConcurrent()
}
