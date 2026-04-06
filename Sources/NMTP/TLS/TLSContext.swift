import NIO

/// Abstraction over a TLS implementation.
/// swift-nmtp depends only on this protocol — it does not import swift-nio-ssl.
public protocol TLSContext: Sendable {
    /// Returns a ChannelHandler to insert at the outermost position of a server pipeline.
    func makeServerHandler() async throws -> any ChannelHandler
    /// Returns a ChannelHandler to insert at the outermost position of a client pipeline.
    /// - Parameter serverHostname: SNI hostname for handshake. Pass nil to skip SNI.
    func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler
}
