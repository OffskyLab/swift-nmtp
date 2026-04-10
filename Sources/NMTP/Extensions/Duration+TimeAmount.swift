import NIO

extension Duration {
    /// Converts a Swift `Duration` to a NIO `TimeAmount`.
    ///
    /// `Duration.components` returns `(seconds: Int64, attoseconds: Int64)`.
    /// 1 attosecond = 1e-18 s = 1e-9 ns, so integer-dividing attoseconds by
    /// 1_000_000_000 gives the sub-second nanoseconds without floating-point.
    var timeAmount: TimeAmount {
        let (seconds, attoseconds) = components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}
