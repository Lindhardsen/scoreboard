import XCTest
@testable import ScoreboardWatch

final class ScoreboardXMLTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "xml"))
        return try Data(contentsOf: url)
    }

    func testParsesWebFixture() throws {
        let board = try ScoreboardXML.parse(fixture("web"))
        XCTAssertEqual(board.home, TeamState(name: "Eksjö Volleyboll IK", sets: 1, points: 12,
                                             colorStyle: "background: rgb(0, 0, 255);"))
        XCTAssertEqual(board.away, TeamState(name: "Gislaveds VBK C", sets: 0, points: 7,
                                             colorStyle: "background: rgb(0, 0, 128);"))
        XCTAssertEqual(board.serving, .away)
    }

    func testParsesScraperOutputWithWrapperAndMissingScores() throws {
        let board = try ScoreboardXML.parse(fixture("scraper"))
        XCTAssertEqual(board.home, TeamState(name: "Sollentuna VK C", sets: 3, points: 0,
                                             colorStyle: "background: rgb(0, 0, 255);"))
        XCTAssertEqual(board.away, TeamState(name: "Vallentuna VBK B", sets: 1, points: 0, colorStyle: nil))
        XCTAssertEqual(board.serving, .home)
    }

    func testParsesEntitiesAndUnicode() throws {
        let xml = """
        <div xmlns="http://www.w3.org/1999/xhtml" id="scoreboard" class="scoreboard">
          <div class="home"><div id="home_team" class="team">A &amp; B ö</div></div>
          <div class="away"><div id="away_team" class="team">&lt;C&gt;</div></div>
        </div>
        """
        let board = try ScoreboardXML.parse(Data(xml.utf8))
        XCTAssertEqual(board.home.name, "A & B ö")
        XCTAssertEqual(board.away.name, "<C>")
        XCTAssertEqual(board.home.points, 0)
        XCTAssertNil(board.serving)
    }

    func testThrowsWithoutScoreboardElement() {
        XCTAssertThrowsError(try ScoreboardXML.parse(Data("<div><div id=\"x\">1</div></div>".utf8)))
        XCTAssertThrowsError(try ScoreboardXML.parse(Data("<div>broken".utf8)))
    }

    func testRoundTripPreservesEverything() throws {
        let boards = [
            Scoreboard(home: TeamState(name: "Eksjö", sets: 2, points: 14, colorStyle: "background: rgb(0, 0, 255);"),
                       away: TeamState(name: "Gislaved", sets: 1, points: 9, colorStyle: "background: rgb(255, 0, 0);"),
                       serving: .home),
            Scoreboard(home: TeamState(name: "Home", sets: 0, points: 0, colorStyle: nil),
                       away: TeamState(name: "Away", sets: 0, points: 3, colorStyle: "background: rgb(1, 2, 3);"),
                       serving: nil),
        ]
        for board in boards {
            XCTAssertEqual(try ScoreboardXML.parse(Data(ScoreboardXML.serialize(board).utf8)), board)
        }
    }

    func testEscapesSpecialCharactersInNames() throws {
        var board = Scoreboard.empty
        board.home.name = #"R&D <"Lag">"#
        board.home.colorStyle = #"background: url("a&b");"#
        let xml = ScoreboardXML.serialize(board)
        XCTAssertTrue(xml.contains("R&amp;D &lt;&quot;Lag&quot;&gt;"), xml)
        XCTAssertEqual(try ScoreboardXML.parse(Data(xml.utf8)), board)
    }

    func testSerializedMatchesWebStructure() throws {
        let xml = ScoreboardXML.serialize(try ScoreboardXML.parse(fixture("web")))
        XCTAssertTrue(xml.hasPrefix(#"<div xmlns="http://www.w3.org/1999/xhtml" id="scoreboard" class="scoreboard">"#), xml)
        let collector = IDCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        XCTAssertTrue(parser.parse())
        XCTAssertEqual(collector.ids, ["scoreboard",
                                       "home_set", "home_color", "home_team", "home_serve", "home_score",
                                       "away_set", "away_color", "away_team", "away_serve", "away_score"])
        XCTAssertEqual(collector.classes["home_team"], "team")
        XCTAssertEqual(collector.classes["away_serve"], "serve serving")
        XCTAssertEqual(collector.classes["home_serve"], "serve")
    }
}

private final class IDCollector: NSObject, XMLParserDelegate {
    var ids: [String] = []
    var classes: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard let id = attributeDict["id"] else { return }
        ids.append(id)
        classes[id] = attributeDict["class"]
    }
}
