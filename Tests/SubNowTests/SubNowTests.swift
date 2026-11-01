import XCTest
@testable import SubNow

final class SubNowTests: XCTestCase {
    func testPathsLayout() {
        XCTAssertTrue(Paths.appSupport.path.hasSuffix("SubNow"))
        XCTAssertTrue(Paths.logFile.path.hasSuffix("SubNow.log"))
        XCTAssertEqual(Paths.stateFile.lastPathComponent, "state.json")
    }

    func testSocketCandidatesContainLegacy() {
        XCTAssertTrue(Paths.socketCandidates.contains("/tmp/poc-mpv.sock"))
        XCTAssertTrue(Paths.socketCandidates.contains("/tmp/subnow-mpv.sock"))
    }
}
