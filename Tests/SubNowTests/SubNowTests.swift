import XCTest
@testable import SubNow

final class SubNowTests: XCTestCase {
    func testPathsLayout() {
        XCTAssertTrue(Paths.appSupport.path.hasSuffix("SubNow"))
        XCTAssertTrue(Paths.logFile.path.hasSuffix("SubNow.log"))
        XCTAssertEqual(Paths.stateFile.lastPathComponent, "state.json")
    }

    func testSocketCandidatesContainDefault() {
        XCTAssertTrue(Paths.socketCandidates.contains("/tmp/subnow-mpv.sock"))
    }
}
