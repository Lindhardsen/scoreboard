import XCTest

/// End-to-end check against a locally running scoreboard server.
/// Start one with a user `demo` / password `demo-pw` on port 8091, then run the
/// ScoreboardWatchUITests scheme. Skipped when no server is reachable.
/// The app signs in from launch arguments (debug builds only) because UI tests
/// can't type on the watch keyboard.
final class ScoringFlowUITests: XCTestCase {
    private let server = "http://127.0.0.1:8091"

    /// Current points for a side, as the server's JSON feed reports them.
    private static func points(_ side: String, server: String) async throws -> Int {
        try await count("points", side, server: server)
    }

    private static func count(_ key: String, _ side: String, server: String) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "\(server)/demo/api/score")!)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return 0 }  // nothing uploaded yet
        let score = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let team = score?[side] as? [String: Any]
        return try XCTUnwrap(team?[key] as? Int)
    }

    @MainActor
    func testSignInAndScore() async throws {
        do {
            _ = try await URLSession.shared.data(from: URL(string: "\(server)/demo/")!)
        } catch {
            throw XCTSkip("No local scoreboard server on \(server)")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-uitestServer", server, "-uitestUsername", "demo", "-uitestPassword", "demo-pw"]
        app.launch()

        let home = app.descendants(matching: .any)["points-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        let start = try await Self.points("home", server: server)

        home.tap()
        home.tap()
        try await Task.sleep(for: .seconds(2))
        let afterTaps = try await Self.points("home", server: server)
        XCTAssertEqual(afterTaps, start + 2)

        home.press(forDuration: 1.0)
        try await Task.sleep(for: .seconds(2))
        let afterHold = try await Self.points("home", server: server)
        XCTAssertEqual(afterHold, start + 1)

        // Page 2: add a set to home and start the next set at 0-0.
        app.swipeUp()
        let addSet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add set to'")).firstMatch
        XCTAssertTrue(addSet.waitForExistence(timeout: 5), app.debugDescription)
        let setsBefore = try await Self.count("sets", "home", server: server)
        addSet.tap()
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), app.debugDescription)
        yes.tap()
        try await Task.sleep(for: .seconds(2))
        let setsAfter = try await Self.count("sets", "home", server: server)
        XCTAssertEqual(setsAfter, setsBefore + 1)
        let pointsAfterSet = try await Self.points("home", server: server)
        XCTAssertEqual(pointsAfterSet, 0)
        XCTAssertTrue(app.buttons["Reset match"].exists)

        // Page 3: team names. The sets page scrolls to its end before paging on.
        app.swipeUp()
        if !app.textFields.firstMatch.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }
}
