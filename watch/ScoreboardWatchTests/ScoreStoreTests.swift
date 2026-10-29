import XCTest
@testable import ScoreboardWatch

@MainActor
final class ScoreStoreTests: XCTestCase {
    private let creds = Credentials(server: URL(string: "https://example.test")!, username: "jan", token: "tok")

    private func makeStore(api: FakeAPI, signedIn: Bool = true,
                           persistence: InMemoryBoardStore = InMemoryBoardStore()) -> (ScoreStore, InMemoryCredentials) {
        let storage = InMemoryCredentials(signedIn ? creds : nil)
        return (ScoreStore(api: api, credentials: storage, persistence: persistence, retryDelays: [.milliseconds(1)]), storage)
    }

    /// A signed-in store that has loaded the server's board, ready to score.
    private func makeLoadedStore(api: FakeAPI) async -> ScoreStore {
        let (store, _) = makeStore(api: api)
        await store.refresh()
        XCTAssertTrue(store.loaded)
        return store
    }

    /// Lets the store's upload task run until it goes idle.
    private func settle(_ store: ScoreStore) async {
        for _ in 0..<500 where store.hasUnsentChanges {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testSignInStoresTokenNotPassword() async throws {
        let api = FakeAPI()
        let (store, storage) = makeStore(api: api, signedIn: false)
        XCTAssertNil(store.credentials)
        try await store.signIn(server: "example.test/", username: " Jan ", password: "secret-pw")
        let saved = try XCTUnwrap(storage.stored)
        XCTAssertEqual(saved, creds)
        XCTAssertEqual(store.credentials, creds)
        XCTAssertFalse(String(describing: saved).contains("secret-pw"))
        let passwords = await api.tokenPasswords
        XCTAssertEqual(passwords, ["secret-pw"])
    }

    func testSignInRejectsBlankServer() async {
        let (store, _) = makeStore(api: FakeAPI(), signedIn: false)
        do {
            try await store.signIn(server: " ", username: "jan", password: "pw")
            XCTFail("expected invalidServer")
        } catch {
            XCTAssertEqual(error, .invalidServer)
        }
    }

    func testSignInPropagatesWrongPassword() async {
        let api = FakeAPI()
        await api.setTokenError(.wrongPassword)
        let (store, storage) = makeStore(api: api, signedIn: false)
        do {
            try await store.signIn(server: "example.test", username: "jan", password: "pw")
            XCTFail("expected wrongPassword")
        } catch {
            XCTAssertEqual(error, .wrongPassword)
        }
        XCTAssertNil(storage.stored)
        XCTAssertNil(store.credentials)
    }

    func testRefreshAdoptsServerStateWhenNoUnsentChanges() async {
        let api = FakeAPI()
        var remote = Scoreboard.empty
        remote.home.points = 11
        await api.setRemote(remote)
        let (store, _) = makeStore(api: api)
        await store.refresh()
        XCTAssertEqual(store.board, remote)
        XCTAssertEqual(store.status, .synced)
    }

    func testRefreshWith404StartsEmpty() async {
        let api = FakeAPI()
        await api.setRemote(nil)
        let (store, _) = makeStore(api: api)
        await store.refresh()
        XCTAssertEqual(store.board, .empty)
    }

    func testRefreshKeepsLocalStateWhenUnsentChanges() async {
        let api = FakeAPI()
        var remote = Scoreboard.empty
        remote.home.points = 20
        let store = await makeLoadedStore(api: api)
        await api.setRemote(remote)
        await api.setUploadError(.unreachable)
        XCTAssertTrue(store.apply { $0.addPoint(.away); return true })
        for _ in 0..<100 where store.status != .offline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.status, .offline)
        await store.refresh()
        XCTAssertEqual(store.board.away.points, 1)
        XCTAssertEqual(store.board.home.points, 0)  // server's 20 not adopted
        XCTAssertTrue(store.hasUnsentChanges)

        await api.setUploadError(nil)
        await settle(store)
        let uploads = await api.uploads
        XCTAssertEqual(uploads.last?.away.points, 1)
        XCTAssertEqual(store.status, .synced)
    }

    func testRapidChangesEndWithLatestStateUploaded() async {
        let api = FakeAPI()
        let store = await makeLoadedStore(api: api)
        for _ in 0..<5 {
            store.apply { $0.addPoint(.home); return true }
        }
        await settle(store)
        let uploads = await api.uploads
        XCTAssertEqual(uploads.last?.home.points, 5)
        XCTAssertFalse(store.hasUnsentChanges)
        XCTAssertEqual(store.status, .synced)
    }

    func testRejectedChangeDoesNotUpload() async {
        let api = FakeAPI()
        let store = await makeLoadedStore(api: api)
        XCTAssertFalse(store.apply { $0.removePoint(.home) })
        XCTAssertFalse(store.hasUnsentChanges)
        let uploads = await api.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testForbiddenUploadSignsOut() async {
        let api = FakeAPI()
        let (store, storage) = makeStore(api: api)
        await store.refresh()
        await api.setUploadError(.forbidden)
        store.apply { $0.addPoint(.home); return true }
        for _ in 0..<100 where store.credentials != nil { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(store.credentials)
        XCTAssertNil(storage.stored)
        try? await Task.sleep(for: .milliseconds(20))
        let attempts = await api.uploadAttempts
        XCTAssertEqual(attempts, 1)
    }

    func testScraperRunningFlagFollowsUploadResult() async {
        let api = FakeAPI()
        await api.setScraperRunning(true)
        let store = await makeLoadedStore(api: api)
        store.apply { $0.addPoint(.home); return true }
        await settle(store)
        XCTAssertTrue(store.scraperRunning)
        await api.setScraperRunning(false)
        store.apply { $0.addPoint(.home); return true }
        await settle(store)
        XCTAssertFalse(store.scraperRunning)
    }

    func testScoringDisabledUntilBoardLoaded() async {
        let api = FakeAPI()
        var remote = Scoreboard.empty
        remote.home = TeamState(name: "Eksjö", sets: 2, points: 14, colorStyle: "background: rgb(0, 0, 255);")
        await api.setRemote(remote)
        await api.setFetchError(.unreachable)
        let (store, _) = makeStore(api: api)
        await store.refresh()
        XCTAssertFalse(store.loaded)
        XCTAssertFalse(store.apply { $0.addPoint(.home); return true })
        let uploads = await api.uploads
        XCTAssertTrue(uploads.isEmpty)

        await api.setFetchError(nil)
        await store.refresh()
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.board, remote)
    }

    func testTapDuringSlowFirstLoadIsIgnored() async {
        let api = FakeAPI()
        var remote = Scoreboard.empty
        remote.home.points = 14
        await api.setRemote(remote)
        await api.setFetchDelay(.milliseconds(100))
        let (store, _) = makeStore(api: api)
        let loading = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(store.apply { $0.addPoint(.home); return true })
        await loading.value
        XCTAssertEqual(store.board, remote)
        let uploads = await api.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testStaleFetchDoesNotOverwriteNewerLocalChange() async {
        let api = FakeAPI()
        let store = await makeLoadedStore(api: api)
        await api.setFetchDelay(.milliseconds(100))
        let refreshing = Task { await store.refresh() }  // captures the pre-tap server board
        try? await Task.sleep(for: .milliseconds(10))
        store.apply { $0.addPoint(.home); return true }
        await settle(store)
        XCTAssertFalse(store.hasUnsentChanges)
        await refreshing.value
        XCTAssertEqual(store.board.home.points, 1)
    }

    func testUnsentChangesSurviveRelaunch() async {
        let api = FakeAPI()
        // What a terminated app left behind: a point the server never confirmed.
        var killed = Scoreboard.empty
        killed.addPoint(.away)
        let persistence = InMemoryBoardStore()
        persistence.state = PersistedBoard(board: killed, unsent: true)

        let (second, _) = makeStore(api: api, persistence: persistence)
        XCTAssertTrue(second.loaded)
        XCTAssertTrue(second.hasUnsentChanges)
        XCTAssertEqual(second.board.away.points, 1)
        await api.setUploadError(nil)
        await second.refresh()
        await settle(second)
        let uploads = await api.uploads
        XCTAssertEqual(uploads.last?.away.points, 1)
    }

    func testBoardSavedOnEveryChange() async {
        let api = FakeAPI()
        let persistence = InMemoryBoardStore()
        let (store, _) = makeStore(api: api, persistence: persistence)
        await store.refresh()
        await api.setUploadError(.unreachable)
        store.apply { $0.addPoint(.home); return true }
        XCTAssertEqual(persistence.state?.board.home.points, 1)
        XCTAssertEqual(persistence.state?.unsent, true)
    }

    func testForbiddenKeepsUnsentPointsForNextSignIn() async throws {
        let api = FakeAPI()
        let (store, _) = makeStore(api: api)
        await store.refresh()
        await api.setUploadError(.forbidden)
        store.apply { $0.addPoint(.home); return true }
        for _ in 0..<100 where store.credentials != nil { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(store.credentials)
        XCTAssertEqual(store.notice, "Session expired — sign in again")
        XCTAssertEqual(store.lastSignIn?.server, "https://example.test")
        XCTAssertEqual(store.lastSignIn?.username, "jan")

        await api.setUploadError(nil)
        try await store.signIn(server: "example.test", username: "jan", password: "pw")
        await settle(store)
        XCTAssertEqual(store.board.home.points, 1)
        let uploads = await api.uploads
        XCTAssertEqual(uploads.last?.home.points, 1)
        XCTAssertNil(store.notice)
    }

    func testSignOutClearsCredentials() {
        let (store, storage) = makeStore(api: FakeAPI())
        store.signOut()
        XCTAssertNil(store.credentials)
        XCTAssertNil(storage.stored)
    }
}

actor FakeAPI: ScoreboardAPI {
    private(set) var uploads: [Scoreboard] = []
    private(set) var uploadAttempts = 0
    private(set) var tokenPasswords: [String] = []
    private var remote: Scoreboard? = .empty
    private var uploadError: ClientError?
    private var tokenError: ClientError?
    private var scraperRunning = false
    private var fetchError: ClientError?
    private var fetchDelay: Duration?

    func setRemote(_ board: Scoreboard?) { remote = board }
    func setUploadError(_ error: ClientError?) { uploadError = error }
    func setTokenError(_ error: ClientError?) { tokenError = error }
    func setScraperRunning(_ running: Bool) { scraperRunning = running }
    func setFetchError(_ error: ClientError?) { fetchError = error }
    func setFetchDelay(_ delay: Duration?) { fetchDelay = delay }

    func fetchToken(server: URL, username: String, password: String) async throws -> String {
        tokenPasswords.append(password)
        if let tokenError { throw tokenError }
        return "tok"
    }

    func fetchScoreboard(_ c: Credentials) async throws -> Scoreboard? {
        if let fetchError { throw fetchError }
        let snapshot = remote  // what the server had when the request arrived
        if let fetchDelay { try? await Task.sleep(for: fetchDelay) }
        return snapshot
    }

    func upload(_ board: Scoreboard, _ c: Credentials) async throws -> UploadResult {
        uploadAttempts += 1
        if let uploadError { throw uploadError }
        uploads.append(board)
        remote = board
        return UploadResult(scraperRunning: scraperRunning)
    }
}

final class InMemoryCredentials: CredentialsStoring, @unchecked Sendable {
    var stored: Credentials?
    init(_ stored: Credentials?) { self.stored = stored }
    func load() -> Credentials? { stored }
    func save(_ c: Credentials) throws { stored = c }
    func clear() { stored = nil }
}

final class InMemoryBoardStore: BoardPersisting, @unchecked Sendable {
    var state: PersistedBoard?
    func load() -> PersistedBoard? { state }
    func save(_ state: PersistedBoard?) { self.state = state }
}
