import Foundation

public enum NMTPError: Error {
    case fail(message: String)
    case invalidMatter(_ reason: String)
    case notConnected
    case connectionClosed
}
