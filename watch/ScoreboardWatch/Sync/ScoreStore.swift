import Foundation
import Combine

enum SyncStatus: Equatable {
    case synced, sending, offline
}

/// Holds the scoreboard the watch shows and keeps the server in step with it.
/// Every upload carries the whole scoreboard, so only the latest state ever needs sending.
@MainActor
final class ScoreStore: ObservableObject {
    @Published private(set) var board: Scoreboard = .empty
    @Published private(set) var status: SyncStatus = .synced
    @Published private(set) var scraperRunning = false
    /// nil means the app should show the sign-in screen.
    @Published private(set) var credentials: Credentials?
    /// False until the server's board has been read (or unsent local points restored).
    /// Scoring is refused until then so a blank board can never overwrite the match.
    @Published private(set) var loaded = false
    /// Shown on the sign-in screen, e.g. after the server rejected the token.
    @Published private(set) var notice: String?
    /// Server and username of the session that just ended, to prefill sign-in.
    @Published private(set) var lastSignIn: (server: String, username: String)?

    private let api: ScoreboardAPI
    private let credentialStore: CredentialsStoring
    private let persistence: BoardPersisting
    private let retryDelays: [Duration]
    @Published private var dirty = false
    @Published private var uploadTask: Task<Void, Never>?
    /// Bumped on every local change, so a fetch that started earlier can't replace it.
    private var revision = 0

    init(api: ScoreboardAPI,
         credentials: CredentialsStoring,
         persistence: BoardPersisting = UserDefaultsBoardStore(),
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]) {
        self.api = api
        self.credentialStore = credentials
        self.persistence = persistence
        self.retryDelays = retryDelays
        self.credentials = credentials.load()
        if let saved = persistence.load() {
            board = saved.board
            // Unsent points win over the server, so they can be scored on straight away.
            // A confirmed board may be stale (the web may have been used), so reload it first.
            dirty = saved.unsent
            loaded = saved.unsent
        }
    }

    /// True until the server has confirmed the latest local change.
    var hasUnsentChanges: Bool { dirty || uploadTask != nil }

    func signIn(server: String, username: String, password: String) async throws(ClientError) {
        guard let url = ServerURL.normalize(server) else { throw .invalidServer }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token: String
        do {
            token = try await api.fetchToken(server: url, username: user, password: password)
        } catch let error as ClientError {
            throw error
        } catch {
            throw .unreachable
        }
        let creds = Credentials(server: url, username: user, token: token)
        try? credentialStore.save(creds)
        credentials = creds
        notice = nil
        await refresh()
    }

    /// Sign-out chosen by the user: forgets the board and anything unsent.
    func signOut() {
        endSession()
        dirty = false
        loaded = false
        board = .empty
        persistence.save(nil)
        status = .synced
    }

    /// The server rejected the token: ask for a new sign-in but keep unsent points,
    /// which are pushed as soon as the next sign-in succeeds.
    private func tokenRejected() {
        endSession()
        notice = "Session expired — sign in again"
    }

    private func endSession() {
        uploadTask?.cancel()
        uploadTask = nil
        if let credentials {
            lastSignIn = (credentials.server.absoluteString, credentials.username)
        }
        credentialStore.clear()
        credentials = nil
        scraperRunning = false
    }

    /// Picks up changes made elsewhere (e.g. the web page) unless the watch has
    /// changes the server hasn't confirmed; those win and keep being pushed.
    func refresh() async {
        guard let creds = credentials else { return }
        if hasUnsentChanges {
            startUploading()
            return
        }
        let startRevision = revision
        do {
            let remote = try await api.fetchScoreboard(creds)
            guard revision == startRevision, !hasUnsentChanges, credentials == creds else { return }
            board = remote ?? .empty
            loaded = true
            persistence.save(PersistedBoard(board: board, unsent: false))
            status = .synced
        } catch {
            if !hasUnsentChanges { status = .offline }
        }
    }

    /// Applies a scoring change; returns false (and sends nothing) when the change was
    /// rejected or the server's board hasn't been loaded yet.
    @discardableResult
    func apply(_ change: (inout Scoreboard) -> Bool) -> Bool {
        guard loaded else { return false }
        var updated = board
        guard change(&updated) else { return false }
        board = updated
        revision += 1
        dirty = true
        persistence.save(PersistedBoard(board: board, unsent: true))
        startUploading()
        return true
    }

    private func startUploading() {
        guard uploadTask == nil, credentials != nil else { return }
        uploadTask = Task { [weak self] in
            await self?.uploadLatest()
        }
    }

    private func uploadLatest() async {
        var failures = 0
        while dirty, let creds = credentials, !Task.isCancelled {
            let snapshot = board
            dirty = false
            if failures == 0 { status = .sending }
            do {
                let result = try await api.upload(snapshot, creds)
                guard !Task.isCancelled else { return }
                scraperRunning = result.scraperRunning
                failures = 0
            } catch ClientError.forbidden {
                // A cancelled upload's late 403 belongs to a session that has already ended.
                guard !Task.isCancelled else { return }
                // The token no longer matches users.json: the snapshot was not stored.
                dirty = true
                tokenRejected()
                return
            } catch {
                guard !Task.isCancelled else { return }
                dirty = true
                status = .offline
                try? await Task.sleep(for: retryDelays[min(failures, retryDelays.count - 1)])
                failures += 1
            }
        }
        guard !Task.isCancelled else { return }
        uploadTask = nil
        if !dirty {
            persistence.save(PersistedBoard(board: board, unsent: false))
        }
        status = .synced
    }
}
