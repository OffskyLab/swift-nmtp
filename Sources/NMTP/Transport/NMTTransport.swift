/// Selects the transport layer used by ``NMTServer`` and ``NMTClient``.
public enum NMTTransport: Sendable {
    /// Raw TCP byte stream (default).
    case tcp
    /// NMT frames carried inside WebSocket binary messages.
    case webSocket(path: String = "/nmt")
}
