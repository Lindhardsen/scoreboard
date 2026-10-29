import XCTest
@testable import ScoreboardWatch

final class TeamColorTests: XCTestCase {
    func testParsesRGBBackground() {
        XCTAssertEqual(TeamColor.rgb(from: "background: rgb(0, 0, 255);"), TeamColor.RGB(red: 0, green: 0, blue: 255))
        XCTAssertEqual(TeamColor.rgb(from: "background:rgb(12,34,56)"), TeamColor.RGB(red: 12, green: 34, blue: 56))
    }

    func testIgnoresMissingOrUnknownStyles() {
        XCTAssertNil(TeamColor.rgb(from: nil))
        XCTAssertNil(TeamColor.rgb(from: "background: red;"))
        XCTAssertNil(TeamColor.rgb(from: "background: rgb(300, 0, 0);"))
    }
}
