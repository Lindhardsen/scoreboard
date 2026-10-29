import Foundation

enum Side: String, CaseIterable, Sendable {
    case home, away
}

struct TeamState: Equatable, Sendable {
    var name: String
    var sets: Int
    var points: Int
    /// Raw `style` attribute of the colour element, e.g. "background: rgb(0, 0, 255);".
    /// nil means no inline colour, so the overlay theme decides.
    var colorStyle: String?
}

/// The scoreboard as the web controller models it. Scoring rules mirror
/// `score()` and `reset()` in html/scoreboard.js.
struct Scoreboard: Equatable, Sendable {
    var home: TeamState
    var away: TeamState
    var serving: Side?

    static let empty = Scoreboard(
        home: TeamState(name: "Home", sets: 0, points: 0, colorStyle: nil),
        away: TeamState(name: "Away", sets: 0, points: 0, colorStyle: nil),
        serving: nil
    )

    subscript(side: Side) -> TeamState {
        get { side == .home ? home : away }
        set {
            if side == .home { home = newValue } else { away = newValue }
        }
    }

    /// Rally scoring: the team that wins the point serves next.
    mutating func addPoint(_ side: Side) {
        self[side].points += 1
        serving = side
    }

    mutating func removePoint(_ side: Side) -> Bool {
        guard self[side].points > 0 else { return false }
        self[side].points -= 1
        return true
    }

    mutating func addSet(_ side: Side, resetPoints: Bool) {
        self[side].sets += 1
        if resetPoints {
            home.points = 0
            away.points = 0
        }
    }

    mutating func removeSet(_ side: Side) -> Bool {
        guard self[side].sets > 0 else { return false }
        self[side].sets -= 1
        return true
    }

    mutating func reset() {
        for side in Side.allCases {
            self[side].sets = 0
            self[side].points = 0
        }
    }

    mutating func rename(_ side: Side, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self[side].name else { return false }
        self[side].name = trimmed
        return true
    }
}
