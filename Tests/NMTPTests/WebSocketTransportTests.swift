import XCTest
@testable import NMTP

final class NMTTransportTests: XCTestCase {

    func testDefaultCaseIsTCP() {
        if case .tcp = NMTTransport.tcp { } else {
            XCTFail("Expected .tcp")
        }
    }

    func testWebSocketDefaultPath() {
        if case .webSocket(let path) = NMTTransport.webSocket() {
            XCTAssertEqual(path, "/nmt")
        } else {
            XCTFail("Expected .webSocket")
        }
    }

    func testWebSocketCustomPath() {
        if case .webSocket(let path) = NMTTransport.webSocket(path: "/custom") {
            XCTAssertEqual(path, "/custom")
        } else {
            XCTFail("Expected .webSocket")
        }
    }
}
