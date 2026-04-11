import XCTest
@testable import NMTP

final class NMTTransportTests: XCTestCase {

    func testTCPTransportDefaultParams() {
        let t = TCPTransport()
        XCTAssertEqual(t.heartbeatInterval, .seconds(30))
        XCTAssertEqual(t.missedLimit, 2)
    }

    func testTCPTransportCustomParams() {
        let t = TCPTransport(heartbeatInterval: .milliseconds(100), missedLimit: 5)
        XCTAssertEqual(t.heartbeatInterval, .milliseconds(100))
        XCTAssertEqual(t.missedLimit, 5)
    }

    func testTCPTransportConformsToNMTTransport() {
        // Compiler-verified: if this compiles, TCPTransport satisfies the protocol.
        let _: any NMTTransport = TCPTransport()
    }
}
