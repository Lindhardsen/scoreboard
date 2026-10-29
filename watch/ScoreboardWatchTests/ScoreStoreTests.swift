import XCTest
@testable import ScoreboardWatch

@MainActor
final class ScoreStoreTests: XCTestCase {
    private let creds = Credentials(server: URL(string: "https://example.test")!, username: "jan", token: "tok")

    private func makeStore(api: FakeAPI, signedIn: Bool = true) -> (ScoreStore, InMemoryCredentials) {
        let storage = InMemoryCredentials(signedIn ? creds : nil)
        return (ScoreStore(api: api, credentials: storage, retryDelays: [.milliseconds(1)]), storage)
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
        await api.setRemote(remote)
        await api.setUploadError(.unreachable)
        let (store, _) = makeStore(api: api)
        XCTAssertTrue(store.apply { $0.addPoint(.away); return true })
        for _ in 0..<100 where store.status != .offline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.status, .offline)
        await store.refresh()
        XCTAssertEqual(store.board.away.points, 1)
        XCTAssertEqual(store.board.home.points, 0)
        XCTAssertTrue(store.hasUnsentChanges)

        await api.setUploadError(nil)
        await settle(store)
        let uploads = await api.uploads
        XCTAssertEqual(uploads.last?.away.points, 1)
        XCTAssertEqual(store.status, .synced)
    }

    func testRapidChangesEndWithLatestStateUploaded() async {
        let api = FakeAPI()
        let (store, _) = makeStore(api: api)
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
        let (store, _) = makeStore(api: api)
        XCTAssertFalse(store.apply { $0.removePoint(.home) })
        XCTAssertFalse(store.hasUnsentChanges)
        let uploads = await api.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testForbiddenUploadSignsOut() async {
        let api = FakeAPI()
        await api.setUploadError(.forbidden)
        let (store, storage) = makeStore(api: api)
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
        let (store, _) = makeStore(api: api)
        store.apply { $0.addPoint(.home); return true }
        await settle(store)
        XCTAssertTrue(store.scraperRunning)
        await api.setScraperRunning(false)
        store.apply { $0.addPoint(.home); return true }
        await settle(store)
        XCTAssertFalse(store.scraperRunning)
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

    func setRemote(_ board: Scoreboard?) { remote = board }
    func setUploadError(_ error: ClientError?) { uploadError = error }
    func setTokenError(_ error: ClientError?) { tokenError = error }
    func setScraperRunning(_ running: Bool) { scraperRunning = running }

    func fetchToken(server: URL, username: String, password: String) async throws -> String {
        tokenPasswords.append(password)
        if let tokenError { throw tokenError }
        return "tok"
    }

    func fetchScoreboard(_ c: Credentials) async throws -> Scoreboard? { remote }

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
