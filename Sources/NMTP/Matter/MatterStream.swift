/// Opaque AsyncSequence wrapper for Matter. Hides AsyncStream from public API.
public struct MatterStream: AsyncSequence, Sendable {
    public typealias Element = Matter

    private let _stream: AsyncStream<Matter>

    package init(_ stream: AsyncStream<Matter>) {
        self._stream = stream
    }

    public func makeAsyncIterator() -> AsyncStream<Matter>.AsyncIterator {
        _stream.makeAsyncIterator()
    }
}
