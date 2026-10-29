import Foundation

/// The board as last shown, kept on the watch so a relaunch neither loses unsent
/// points nor starts scoring from a blank board.
struct PersistedBoard: Codable, Equatable, Sendable {
    var board: Scoreboard
    /// The server has not confirmed this board yet.
    var unsent: Bool
}

protocol BoardPersisting: Sendable {
    func load() -> PersistedBoard?
    /// nil forgets the saved board.
    func save(_ state: PersistedBoard?)
}

struct UserDefaultsBoardStore: BoardPersisting {
    private let key = "persistedBoard"

    func load() -> PersistedBoard? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedBoard.self, from: data)
    }

    func save(_ state: PersistedBoard?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
