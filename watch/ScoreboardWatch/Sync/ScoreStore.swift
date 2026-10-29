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

    private let api: ScoreboardAPI
    private let credentialStore: CredentialsStoring
    private let retryDelays: [Duration]
    @Published private var dirty = false
    @Published private var uploadTask: Task<Void, Never>?

    init(api: ScoreboardAPI,
         credentials: CredentialsStoring,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]) {
        self.api = api
        self.credentialStore = credentials
        self.retryDelays = retryDelays
        self.credentials = credentials.load()
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
        await refresh()
    }

    func signOut() {
        uploadTask?.cancel()
        uploadTask = nil
        dirty = false
        credentialStore.clear()
        credentials = nil
        scraperRunning = false
        status = .synced
    }

    /// Picks up changes made elsewhere (e.g. the web page) unless the watch has
    /// changes the server hasn't confirmed; those win and keep being pushed.
    func refresh() async {
        guard let creds = credentials else { return }
        if hasUnsentChanges {
            startUploading()
            return
        }
        do {
            let remote = try await api.fetchScoreboard(creds)
            guard !hasUnsentChanges, credentials == creds else { return }
            board = remote ?? .empty
            status = .synced
        } catch {
            if !hasUnsentChanges { status = .offline }
        }
    }

    /// Applies a scoring change; returns false (and sends nothing) when the change was rejected.
    @discardableResult
    func apply(_ change: (inout Scoreboard) -> Bool) -> Bool {
        var updated = board
        guard change(&updated) else { return false }
        board = updated
        dirty = true
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
                // The token no longer matches users.json: sign in again.
                uploadTask = nil
                signOut()
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
        status = .synced
    }
}
