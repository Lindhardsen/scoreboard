import Foundation

enum ScoreboardXMLError: Error, Equatable {
    case malformed
    case missingScoreboard
}

/// Reads and writes the scoreboard XHTML fragment that html/scoreboard.js uploads
/// and the overlay renders. Reading accepts both the web's fragment and the
/// scraper's wrapped file; writing always produces the web's structure.
enum ScoreboardXML {
    static func parse(_ data: Data) throws -> Scoreboard {
        let reader = ElementReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw ScoreboardXMLError.malformed }
        guard reader.elements["scoreboard"] != nil else { throw ScoreboardXMLError.missingScoreboard }

        var board = Scoreboard.empty
        board.serving = nil
        for side in Side.allCases {
            let prefix = side.rawValue + "_"
            if let name = reader.text(prefix + "team"), !name.isEmpty {
                board[side].name = name
            }
            // Scraped scoreboards drop the score elements once a match has ended.
            board[side].sets = Int(reader.text(prefix + "set") ?? "") ?? 0
            board[side].points = Int(reader.text(prefix + "score") ?? "") ?? 0
            board[side].colorStyle = reader.elements[prefix + "color"]?.attributes["style"]
            let serveClasses = reader.elements[prefix + "serve"]?.attributes["class"]?.split(separator: " ") ?? []
            if serveClasses.contains("serving") {
                board.serving = side
            }
        }
        return board
    }

    static func serialize(_ board: Scoreboard) -> String {
        var lines = [#"<div xmlns="http://www.w3.org/1999/xhtml" id="scoreboard" class="scoreboard">"#]
        for side in Side.allCases {
            let team = board[side]
            let id = side.rawValue
            let style = team.colorStyle.map { #" style="\#(escape($0))""# } ?? ""
            let serveClass = board.serving == side ? "serve serving" : "serve"
            lines += [
                #"    <div class="\#(id)">"#,
                #"        <div id="\#(id)_set" class="set">\#(team.sets)</div>"#,
                #"        <div id="\#(id)_color" class="color"\#(style)>\#u{00A0}</div>"#,
                #"        <div id="\#(id)_team" class="team" contenteditable="true">\#(escape(team.name))</div>"#,
                #"        <div id="\#(id)_serve" class="\#(serveClass)">\#u{00A0}</div>"#,
                #"        <div id="\#(id)_score" class="score">\#(team.points)</div>"#,
                "    </div>",
            ]
        }
        lines.append("</div>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Collects attributes and direct text of every element that has an id.
private final class ElementReader: NSObject, XMLParserDelegate {
    struct Element {
        var attributes: [String: String]
        var text = ""
    }

    private(set) var elements: [String: Element] = [:]
    private var stack: [String?] = []

    func text(_ id: String) -> String? {
        elements[id]?.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}")))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let id = attributeDict["id"]
        if let id, elements[id] == nil {
            elements[id] = Element(attributes: attributeDict)
        }
        stack.append(id)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let id = stack.last ?? nil else { return }
        elements[id]?.text += string
    }
}
