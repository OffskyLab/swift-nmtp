import Foundation
import NIO

public final class MatterEncoder: MessageToByteEncoder {
    public typealias OutboundIn = Matter
    public init() {}
    public func encode(data: Matter, out: inout ByteBuffer) throws {
        out.writeBytes(data.serialized())
    }
}
