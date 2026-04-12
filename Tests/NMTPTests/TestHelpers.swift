// Tests/NMTPTests/TestHelpers.swift
// Shared test helpers for the NMTPTests target.
import Foundation
import NIO
import Synchronization
@testable import NMTP

/// Echoes each incoming matter back as a `.reply` with the same matterID and payload.
struct EchoHandler: NMTHandler {
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        Matter(type: .reply, matterID: matter.matterID, payload: matter.payload)
    }
}

// MARK: - PushHandler

/// Sends one unsolicited matter to the channel; returns nil (no direct reply).
struct PushHandler: NMTHandler {
    let pushBody: Data
    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        channel.writeAndFlush(Matter(type: .reply, payload: pushBody), promise: nil)
        return nil
    }
}

// MARK: - MockTLSContext

/// Installs a no-op passthrough handler and records call counts. Thread-safe.
final class MockTLSContext: TLSContext, Sendable {
    private let _serverCalls = Mutex<Int>(0)
    private let _clientCalls = Mutex<Int>(0)

    var serverCallCount: Int { _serverCalls.withLock { $0 } }
    var clientCallCount: Int { _clientCalls.withLock { $0 } }

    func makeServerHandler() async throws -> any ChannelHandler {
        _serverCalls.withLock { $0 += 1 }
        return PassThroughHandler()
    }

    func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler {
        _clientCalls.withLock { $0 += 1 }
        return PassThroughHandler()
    }
}

// MARK: - PassThroughHandler

/// Forwards all inbound ByteBuffer data unchanged. Used by MockTLSContext.
final class PassThroughHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}
