import XCTest
@testable import ScoreboardWatch

final class ScoreboardTests: XCTestCase {
    func testAddPointIncrementsAndGivesServe() {
        var board = Scoreboard.empty
        board.addPoint(.away)
        XCTAssertEqual(board.away.points, 1)
        XCTAssertEqual(board.serving, .away)
    }

    func testRemovePointKeepsServeAndFloorsAtZero() {
        var board = Scoreboard.empty
        board.serving = .home
        board.away.points = 1
        XCTAssertTrue(board.removePoint(.away))
        XCTAssertEqual(board.away.points, 0)
        XCTAssertEqual(board.serving, .home)
        XCTAssertFalse(board.removePoint(.away))
        XCTAssertEqual(board.away.points, 0)
    }

    func testAddSetWithAndWithoutReset() {
        var board = Scoreboard.empty
        board.home.points = 25
        board.away.points = 20
        board.addSet(.home, resetPoints: true)
        XCTAssertEqual(board.home.sets, 1)
        XCTAssertEqual(board.home.points, 0)
        XCTAssertEqual(board.away.points, 0)
        board.home.points = 3
        board.addSet(.away, resetPoints: false)
        XCTAssertEqual(board.away.sets, 1)
        XCTAssertEqual(board.home.points, 3)
    }

    func testRemoveSetFloorsAtZero() {
        var board = Scoreboard.empty
        board.home.sets = 1
        board.home.points = 4
        XCTAssertTrue(board.removeSet(.home))
        XCTAssertEqual(board.home.sets, 0)
        XCTAssertEqual(board.home.points, 4)
        XCTAssertFalse(board.removeSet(.home))
        XCTAssertEqual(board.home.sets, 0)
    }

    func testResetZeroesSetsAndPointsKeepsNamesAndColors() {
        var board = Scoreboard.empty
        board.home = TeamState(name: "Eksjö", sets: 2, points: 10, colorStyle: "background: rgb(0, 0, 255);")
        board.away = TeamState(name: "Gislaved", sets: 1, points: 8, colorStyle: nil)
        board.reset()
        XCTAssertEqual(board.home, TeamState(name: "Eksjö", sets: 0, points: 0, colorStyle: "background: rgb(0, 0, 255);"))
        XCTAssertEqual(board.away, TeamState(name: "Gislaved", sets: 0, points: 0, colorStyle: nil))
    }

    func testRenameTrimsAndIgnoresEmptyOrUnchanged() {
        var board = Scoreboard.empty
        XCTAssertTrue(board.rename(.home, to: "  Eksjö  "))
        XCTAssertEqual(board.home.name, "Eksjö")
        XCTAssertFalse(board.rename(.home, to: "   "))
        XCTAssertEqual(board.home.name, "Eksjö")
        XCTAssertFalse(board.rename(.home, to: "Eksjö"))
    }

    func testSubscriptReadsAndWritesSide() {
        var board = Scoreboard.empty
        board[.away].points = 9
        XCTAssertEqual(board.away.points, 9)
        XCTAssertEqual(board[.home].name, "Home")
    }
}
