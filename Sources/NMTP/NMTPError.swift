public enum NMTPError: Error, Equatable {
    case fail(message: String)
    case invalidMatter(_ reason: String)
    case notConnected
    case connectionClosed

    /// The remote did not reply within the caller-specified deadline.
    case timeout

    /// The heartbeat mechanism detected that the remote end is no longer responding.
    case connectionDead

    /// The server is draining in-flight requests and will not accept new ones.
    case shuttingDown

    /// A typed request received a reply whose wire type does not match the expected response type.
    case unexpectedReplyType(expected: UInt16, actual: UInt16)
}
