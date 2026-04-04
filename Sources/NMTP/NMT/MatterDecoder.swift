import Foundation
import NIO

public final class MatterDecoder: ByteToMessageDecoder {
    public typealias InboundOut = Matter
    public init() {}

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= Matter.headerSize else { return .needMoreData }
        guard let bodyLength = buffer.getInteger(at: buffer.readerIndex + 23, endianness: .big, as: UInt32.self) else { return .needMoreData }
        let totalLength = Matter.headerSize + Int(bodyLength)
        guard buffer.readableBytes >= totalLength else { return .needMoreData }
        guard let frameBytes = buffer.readBytes(length: totalLength) else { return .needMoreData }
        let matter = try Matter(bytes: frameBytes)
        context.fireChannelRead(wrapInboundOut(matter))
        return .continue
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        .needMoreData
    }
}
