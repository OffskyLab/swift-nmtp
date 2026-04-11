/// Opaque AsyncSequence wrapper for Peer. Hides AsyncStream from public API.
public struct PeerStream: AsyncSequence, Sendable {
    public typealias Element = Peer

    private let _stream: AsyncStream<Peer>

    init(_ stream: AsyncStream<Peer>) {
        self._stream = stream
    }

    public func makeAsyncIterator() -> AsyncStream<Peer>.AsyncIterator {
        _stream.makeAsyncIterator()
    }
}
