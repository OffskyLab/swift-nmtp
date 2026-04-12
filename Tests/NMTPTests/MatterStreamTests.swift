import XCTest
@testable import NMTP

final class MatterStreamTests: XCTestCase {

    func testIterationYieldsAllElements() async {
        var cont: AsyncStream<Matter>.Continuation!
        let stream = AsyncStream<Matter> { cont = $0 }
        let matterStream = MatterStream(stream)

        let m1 = Matter(type: .command, payload: Data("a".utf8))
        let m2 = Matter(type: .reply, payload: Data("b".utf8))
        cont.yield(m1)
        cont.yield(m2)
        cont.finish()

        var collected: [Matter] = []
        for await m in matterStream {
            collected.append(m)
        }

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[0].matterID, m1.matterID)
        XCTAssertEqual(collected[1].matterID, m2.matterID)
    }

    func testStreamTerminatesOnFinish() async {
        var cont: AsyncStream<Matter>.Continuation!
        let stream = AsyncStream<Matter> { cont = $0 }
        let matterStream = MatterStream(stream)

        cont.finish()

        var count = 0
        for await _ in matterStream { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
