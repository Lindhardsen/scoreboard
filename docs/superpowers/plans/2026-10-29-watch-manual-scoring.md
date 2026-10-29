# Apple Watch Manual Scoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone watchOS app that does manual volleyball scoring (points, sets, team names) against the existing scoreboard server, plus the small server changes it needs, shipped to TestFlight by 2026-10-30.

**Architecture:** Server gains a token endpoint and makes `upload.php` also write `scoreboard.json` and report a running scraper via a response header. The watch app reads `GET /<user>/scoreboard.xml`, keeps a `Scoreboard` value model with the web's scoring rules, and uploads a regenerated `#scoreboard` XML fragment to `upload.php` with the token, exactly as `html/scoreboard.js` does.

**Tech Stack:** Python 3 / Flask / `unittest`; Swift 6, SwiftUI, watchOS 11+, XcodeGen (`/opt/homebrew/bin/xcodegen`), XCTest, `URLSession`, Keychain (Security framework). No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-29-watch-manual-scoring-design.md`

## Global Constraints

- Web page (`html/scoreboard.html`, `html/scoreboard.js`) and overlay (`html/index.html`) are not modified.
- `upload.php` keeps returning body `OK` / status 200 on success.
- Token endpoint: `POST /<username>/api/token`, field `password` (form or JSON) → `{"token": "..."}`; 401 wrong password; 429 rate-limited; 404 invalid/unknown user. Shares `check_rate_limit` / `record_login_attempt` with `/login`.
- Scraper header: `X-Scraper-Running: 1` on upload responses when a scraper process is live for that user.
- `scoreboard.json` shape: `{"home": {"name", "sets", "points"}, "away": {...}, "matchEnded": false}` — written via `scraper.write_scoreboard_json`.
- Server tests use `unittest`, run with `python3 -m unittest discover -s tests -v`.
- Watch app: standalone (no iPhone app), minimum watchOS 11, SwiftUI, Swift 6, no third-party deps, lives in `watch/`.
- Bundle ID `org.lindhardsen.scoreboard.watchkitapp`; team ID is Jan's own, confirmed at Task 7 (do not reuse Tubeist's `D77T8B2FR2` without asking).
- Keychain holds server URL, username, token. Password is never stored.
- Scoring rules (mirror `score()` / `reset()` in `html/scoreboard.js`): point +1 → that side serves; point −1 → serve unchanged, floor 0; set +1 → optional reset of both points to 0; set −1 → floor 0, points unchanged; reset → sets and points 0. Name edit: trimmed; empty or unchanged ignored.
- Unsent local change wins over server state on re-activation; otherwise adopt server state.
- Info.plist: `ITSAppUsesNonExemptEncryption = NO`.

## Review Focus

1. Team names with `&`, `<`, `"` or non-ASCII ("Eksjö") — must round-trip through XML read and write without breaking the overlay. Pinned in Task 4 (`testEscapesSpecialCharactersInNames`, `testParsesEntitiesAndUnicode`).
2. XML written by the scraper (outer `<div xmlns>` wrapper, `&nbsp;`-as-U+00A0 content, ended-set columns, missing `*_score` after match end, `highlight` sibling) — watch must still read it. Pinned in Task 4 (`testParsesScraperOutputWithWrapperAndMissingScores`).
3. Server URL typed with trailing slash or without scheme (`volley.lindhardsen.org/`) — should still work. Pinned in Task 5 (`testNormalizesServerURL`).
4. Upload returns 403 (token changed in `users.json`) — app must go back to config, not retry forever. Pinned in Task 5 (`testForbiddenUploadSignsOut`).
5. Rapid taps while an upload is in flight — the final server state must equal the final local state (latest-wins, no out-of-order overwrite). Pinned in Task 5 (`testRapidChangesEndWithLatestStateUploaded`).

---

### Task 1: Server — token endpoint

**Files:**
- Modify: `server.py` (add route after `user_score`, ~line 409)
- Test: `tests/test_watch_api.py` (new)

**Interfaces:**
- Produces: `POST /<username>/api/token` as in Global Constraints. `users.json` user entry already has `token`.

- [ ] **Step 1: Write the failing tests** in `tests/test_watch_api.py`, class `WatchApiTests(unittest.TestCase)`. `setUp` copies `server.py`, `password_support.py`, `scraper.py` into a temp dir (same pattern as `tests/test_password_support.py:setUp`), writes `users.json` with `test-user` (`password_hash=generate_password_hash('pw', method='pbkdf2:sha256:600000')`, `token='tok-123'`), loads `runpy.run_path(server.py)`, keeps `self.ns`, `self.client`.
  - `test_token_returned_for_correct_password`: `POST /test-user/api/token data={'password':'pw'}` → 200, `json == {'token':'tok-123'}`; also with `json={'password':'pw'}` → 200.
  - `test_token_rejects_wrong_password_and_records_attempt`: → 401, `len(self.ns['LOGIN_ATTEMPTS']['127.0.0.1']) == 1`, body has no `token`.
  - `test_token_rate_limited`: pre-fill `LOGIN_ATTEMPTS['127.0.0.1']` with 5 × `time.time()` → correct password still gets 429.
  - `test_token_unknown_user_404`: `/nobody/api/token` → 404; `/Bad_User/api/token` → 404.
- [ ] **Step 2:** Run `python3 -m unittest tests.test_watch_api -v` → FAIL (404/405 on route).
- [ ] **Step 3: Implement `user_token(username)`** in `server.py`: validate user (404), `check_rate_limit(request.remote_addr)` → 429 JSON `{'error': ...}`, read password from `request.get_json(silent=True)` or `request.values`, `validate_password` → on fail `record_login_attempt` + 401, on success clear attempts like `/login` does and return `jsonify({'token': user.get('token', '')})`.
- [ ] **Step 4:** Run `python3 -m unittest discover -s tests -v` → all pass.
- [ ] **Step 5: Commit** `git add server.py tests/test_watch_api.py && git commit -m "Add token endpoint for watch clients"`

### Task 2: Server — upload writes JSON + scraper header

**Files:**
- Modify: `server.py` `user_upload` (~line 362), add helper `_scoreboard_state_from_xml(xml_text) -> dict | None`
- Test: `tests/test_watch_api.py`

**Interfaces:**
- Consumes: `scraper.write_scoreboard_json(state, output_path)` (state dict: `home`/`away` each `{name, sets, points}`, `matchEnded`).
- Produces: `data/<user>/scoreboard.json` after every valid upload; header `X-Scraper-Running: 1` when scraper live.

- [ ] **Step 1: Write the failing tests:**
  - `test_upload_writes_json_sidecar`: upload `html/scoreboard.xml`'s content (read from repo root) with `token='tok-123'` → 200, body `b'OK'`; `data/test-user/scoreboard.json` equals `{'home':{'name':'Eksjö Volleyboll IK','sets':1,'points':12},'away':{'name':'Gislaveds VBK C','sets':0,'points':7},'matchEnded':False}`; then `GET /test-user/api/score` returns the same JSON.
  - `test_upload_with_unparseable_xml_still_ok`: `filedata='<div>broken'` → 200 `OK`, xml file written, no json file created.
  - `test_upload_escaped_name_round_trips`: XML with `home_team` text `A &amp; B` → json home name `'A & B'`.
  - `test_upload_reports_running_scraper`: set `self.ns['_get_user_state']('test-user')['process'] = Mock(poll=Mock(return_value=None))` → response header `X-Scraper-Running == '1'`; without process → header absent.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement.** `_scoreboard_state_from_xml` parses with `xml.etree.ElementTree.fromstring`, finds elements by `id` attribute regardless of namespace (iterate `root.iter()`), reads `home_team/home_set/home_score` etc. (`int(text.strip() or 0)`, missing score → 0), returns the state dict with `matchEnded: False`, or `None` on `ParseError`/missing ids. In `user_upload`, after writing the XML, `import scraper` at module top and call `scraper.write_scoreboard_json(state, filepath)` when state is not None (log on failure, never fail the request). Build the response with `make_response('OK', 200)` and set the header when `_is_scraper_running_unlocked(_get_user_state(username))` (under `SCRAPER_LOCK`).
- [ ] **Step 4:** Run full suite → pass.
- [ ] **Step 5: Commit** `git commit -m "Keep scoreboard.json fresh on manual uploads and flag running scraper"`

### Task 3: Watch project scaffold + `Scoreboard` model with scoring rules

**Files:**
- Create: `watch/project.yml`, `watch/.gitignore` (`*.xcodeproj/xcuserdata`, `build/`), `watch/ScoreboardWatch/ScoreboardWatchApp.swift` (placeholder `Text`), `watch/ScoreboardWatch/Model/Scoreboard.swift`, `watch/ScoreboardWatch/Assets.xcassets` (empty AppIcon set), `watch/ScoreboardWatchTests/ScoreboardTests.swift`
- Commit the generated `watch/ScoreboardWatch.xcodeproj` too (so Jan can open it without XcodeGen).

**Interfaces:**
- Produces:
  ```swift
  enum Side: String, CaseIterable, Sendable { case home, away }
  struct TeamState: Equatable, Sendable { var name: String; var sets: Int; var points: Int; var colorStyle: String? }  // colorStyle = raw style attr value, e.g. "background: rgb(0, 0, 255);"
  struct Scoreboard: Equatable, Sendable {
      var home: TeamState; var away: TeamState; var serving: Side?
      static let empty: Scoreboard   // "Home"/"Away", 0s, serving nil, no colors
      subscript(side: Side) -> TeamState { get set }
      mutating func addPoint(_ side: Side)
      mutating func removePoint(_ side: Side) -> Bool      // false if already 0 (no change)
      mutating func addSet(_ side: Side, resetPoints: Bool)
      mutating func removeSet(_ side: Side) -> Bool
      mutating func reset()
      mutating func rename(_ side: Side, to name: String) -> Bool  // false if trimmed empty or unchanged
  }
  ```

- [ ] **Step 1: Write `project.yml`**: project `ScoreboardWatch`, `options.deploymentTarget.watchOS: "11.0"`, target `ScoreboardWatch` type `application`, platform `watchOS`, `PRODUCT_BUNDLE_IDENTIFIER: org.lindhardsen.scoreboard.watchkitapp`, `SWIFT_VERSION: 6.0`, `INFOPLIST_KEY_WKApplication: YES`, `INFOPLIST_KEY_WKWatchOnly: YES`, `INFOPLIST_KEY_CFBundleDisplayName: Scoreboard`, `GENERATE_INFOPLIST_FILE: YES`, `ITSAppUsesNonExemptEncryption: NO` via `info.properties`, `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM` left empty for now; test target `ScoreboardWatchTests` type `bundle.unit-test`, platform watchOS, depends on app. Scheme `ScoreboardWatch` with tests.
- [ ] **Step 2:** `cd watch && xcodegen generate` → project created.
- [ ] **Step 3: Write failing tests** `ScoreboardTests`:
  - `testAddPointIncrementsAndGivesServe`: empty; `addPoint(.away)` → away.points 1, serving `.away`.
  - `testRemovePointKeepsServeAndFloorsAtZero`: serving `.home`, away.points 1; `removePoint(.away)` → true, 0, serving still `.home`; again → false, 0.
  - `testAddSetWithAndWithoutReset`: points 25/20; `addSet(.home, resetPoints: true)` → home.sets 1, both points 0; `addSet(.away, resetPoints: false)` → points unchanged.
  - `testRemoveSetFloorsAtZero`.
  - `testResetZeroesSetsAndPointsKeepsNamesAndColors`.
  - `testRenameTrimsAndIgnoresEmptyOrUnchanged`: `rename(.home, to: "  Eksjö  ")` → true, `"Eksjö"`; `"   "` → false; `"Eksjö"` again → false.
- [ ] **Step 4:** Run `xcodebuild test -project watch/ScoreboardWatch.xcodeproj -scheme ScoreboardWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' -quiet` → FAIL (no `Scoreboard`).
- [ ] **Step 5:** Implement `Scoreboard.swift`. Run tests → pass.
- [ ] **Step 6: Commit** `git add watch && git commit -m "Scaffold watch app with scoreboard scoring model"`

### Task 4: Watch — XML read/write

**Files:**
- Create: `watch/ScoreboardWatch/Model/ScoreboardXML.swift`, `watch/ScoreboardWatchTests/ScoreboardXMLTests.swift`, `watch/ScoreboardWatchTests/Fixtures/` (copy of `html/scoreboard.xml` as `web.xml`, and `scraper.xml` captured from `scraper.write_scoreboard_xml` with a highlight and `matchEnded=True`, ended sets shown)

**Interfaces:**
- Consumes: `Scoreboard`, `TeamState`, `Side` (Task 3)
- Produces:
  ```swift
  enum ScoreboardXML {
      static func parse(_ data: Data) throws -> Scoreboard   // throws ScoreboardXMLError.missingScoreboard if no id="scoreboard"
      static func serialize(_ board: Scoreboard) -> String
  }
  ```

Decision *(plan's call)*: `serialize` regenerates the `#scoreboard` element canonically instead of patching the fetched text. It produces exactly the structure in `html/scoreboard.xml` (root `<div xmlns="http://www.w3.org/1999/xhtml" id="scoreboard" class="scoreboard">`, `.home` then `.away`, children in order set, color, team (`contenteditable="true"`), serve (`class="serve serving"` or `"serve"`, content U+00A0), score; color `style` attribute only when `colorStyle != nil`). Consequence: ended-set columns left over from a scraper session are dropped once the watch scores — acceptable since manual mode never shows them.

- [ ] **Step 1: Write failing tests:**
  - `testParsesWebFixture`: home `Eksjö Volleyboll IK`, sets 1, points 12, colorStyle `background: rgb(0, 0, 255);`; away points 7; serving `.away`.
  - `testParsesScraperOutputWithWrapperAndMissingScores`: scraper fixture parses; missing `*_score` → 0; highlight ignored.
  - `testParsesEntitiesAndUnicode`: `<div id="home_team">A &amp; B ö</div>` → `"A & B ö"`.
  - `testRoundTripPreservesEverything`: `parse(serialize(board)) == board` for a board with both colors, one nil color, serving nil and `.home`.
  - `testEscapesSpecialCharactersInNames`: name `R&D <"Lag">` → serialized contains `R&amp;D &lt;&quot;Lag&quot;&gt;` and round-trips.
  - `testSerializedMatchesWebStructure`: serialize parsed web fixture, then parse with `XMLParser` and assert element id order `scoreboard, home_set, home_color, home_team, home_serve, home_score, away_set, …`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement with Foundation `XMLParser` (delegate collecting `id`, `class`, `style`, text per element; whitespace-only text with U+00A0 ignored). Escape `& < > "` in text and attributes.
- [ ] **Step 4:** Run → pass. **Step 5: Commit** `"Add scoreboard XML parsing and serialization"`

### Task 5: Watch — networking, credentials, sync store

**Files:**
- Create: `watch/ScoreboardWatch/Sync/ScoreboardClient.swift`, `watch/ScoreboardWatch/Sync/Credentials.swift`, `watch/ScoreboardWatch/Sync/ScoreStore.swift`, `watch/ScoreboardWatchTests/ScoreStoreTests.swift`, `watch/ScoreboardWatchTests/ScoreboardClientTests.swift`

**Interfaces:**
- Consumes: `Scoreboard`, `ScoreboardXML` (Tasks 3–4)
- Produces:
  ```swift
  struct Credentials: Equatable, Sendable { var server: URL; var username: String; var token: String }
  enum ServerURL { static func normalize(_ raw: String) -> URL? }   // adds https:// if no scheme, strips trailing "/"
  protocol CredentialsStoring: Sendable { func load() -> Credentials?; func save(_ c: Credentials) throws; func clear() }
  struct KeychainCredentialsStore: CredentialsStoring   // one generic-password item, service "org.lindhardsen.scoreboard", JSON-encoded
  enum ClientError: Error, Equatable { case unreachable, wrongPassword, rateLimited, unknownUser, forbidden, server(Int) }
  struct UploadResult: Equatable, Sendable { var scraperRunning: Bool }
  protocol ScoreboardAPI: Sendable {
      func fetchToken(server: URL, username: String, password: String) async throws -> String
      func fetchScoreboard(_ c: Credentials) async throws -> Scoreboard?   // nil on 404
      func upload(_ board: Scoreboard, _ c: Credentials) async throws -> UploadResult
  }
  struct ScoreboardClient: ScoreboardAPI   // URLSession; URLs: <server>/<user>/api/token, /scoreboard.xml?ts=<epoch>, /upload.php (form-urlencoded token, filename=scoreboard.xml, filedata)
  enum SyncStatus: Equatable { case synced, sending, offline }
  @MainActor @Observable final class ScoreStore {
      init(api: ScoreboardAPI, credentials: CredentialsStoring, retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)])
      private(set) var board: Scoreboard; private(set) var status: SyncStatus; private(set) var scraperRunning: Bool
      private(set) var credentials: Credentials?   // nil → show config
      var hasUnsentChanges: Bool { get }
      func signIn(server: String, username: String, password: String) async throws(ClientError)
      func signOut()
      func refresh() async            // called on launch + scenePhase .active
      func apply(_ change: (inout Scoreboard) -> Bool)  // mutates, if true: haptic hook + schedule upload of latest board
  }
  ```
  Status maps: 401→`wrongPassword`, 429→`rateLimited`, 404 on token→`unknownUser`, 403 on upload→`forbidden`, URLError→`unreachable`.

- [ ] **Step 1: Write failing tests** with a `FakeAPI` actor (records uploads, scripted results) and `InMemoryCredentials`, `retryDelays: [.milliseconds(1)]`:
  - `ScoreboardClientTests.testNormalizesServerURL`: `"volley.lindhardsen.org/"` → `https://volley.lindhardsen.org`; `"http://10.0.0.5:8081"` unchanged; `""` → nil.
  - `testSignInStoresTokenNotPassword`: after `signIn`, saved credentials token `"tok"`, and no stored field equals the password.
  - `testRefreshAdoptsServerStateWhenNoUnsentChanges`.
  - `testRefreshKeepsLocalStateWhenUnsentChanges`: upload fails (unreachable), `apply(addPoint)`, `refresh()` → board unchanged from local, status `.offline`, and upload retried.
  - `testRapidChangesEndWithLatestStateUploaded`: 5 `apply(addPoint(.home))` quickly; after settling, last uploaded board has home.points 5, status `.synced`, `hasUnsentChanges == false`.
  - `testForbiddenUploadSignsOut`: upload throws `.forbidden` → `credentials == nil`, store cleared, no further uploads.
  - `testScraperRunningFlagFollowsUploadResult`.
  - `testRefreshWith404StartsEmpty`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Upload loop: single in-flight `Task`; after each success, if `board` changed since the snapshot sent, send again; on `.unreachable`/`.server` wait next retry delay (last repeats) and resend latest board, status `.offline` after first failure.
- [ ] **Step 4:** Run → pass. **Step 5: Commit** `"Add watch sync store, API client and keychain credentials"`

### Task 6: Watch — UI (points, sets, names, config)

**Files:**
- Create: `watch/ScoreboardWatch/Views/PointsView.swift`, `SetsView.swift`, `NamesView.swift`, `ConfigView.swift`, `SyncBadge.swift`
- Modify: `watch/ScoreboardWatch/ScoreboardWatchApp.swift`

**Interfaces:**
- Consumes: `ScoreStore` (Task 5)

- [ ] **Step 1: App root.** If `store.credentials == nil` → `ConfigView`; else `TabView` with `.tabViewStyle(.verticalPage)` containing Points, Sets, Names. Call `store.refresh()` on `.task` and on `scenePhase == .active`.
- [ ] **Step 2: PointsView.** Two halves (home top, away bottom), each a full-width button: name (1 line, truncated), points large (`.system(size: 44, weight: .bold, design: .rounded)`, monospaced digits), serving dot, colour accent from `colorStyle` (parse `rgb(r, g, b)`; none → default). Tap → `apply { $0.addPoint(side); return true }` + `WKInterfaceDevice.current().play(.click)`; long press (0.5 s) → `removePoint` + `.directionDown` haptic (only if it changed). `SyncBadge` top corner (green synced / grey sending / red offline). Scraper banner text when `scraperRunning`: "Profixio scraper running — manual points will be overwritten".
- [ ] **Step 3: SetsView.** Per team: name, set count, `−` / `+` buttons. `+` shows `.confirmationDialog("Start next set at 0–0?")` with Yes → `addSet(resetPoints: true)`, No → `addSet(resetPoints: false)`. "Reset match" button with confirmation "Reset the match?". Gear button → sheet with server/user and "Sign out".
- [ ] **Step 4: NamesView.** Two `TextField`s bound to local drafts prefilled with names; `.onSubmit` → `apply { $0.rename(side, to: draft) }`; reset draft to current name if rejected.
- [ ] **Step 5: ConfigView.** Fields server (placeholder `volley.lindhardsen.org`), username, password (`SecureField`), "Sign in" button with progress; error messages: unreachable "Can't reach server", wrongPassword "Wrong username or password", rateLimited "Too many attempts — wait 5 minutes", unknownUser "Wrong username or password".
- [ ] **Step 6: Verify in simulator** against a local server: `python3 server.py` (port 8081), sign in with `http://<mac-LAN-IP>:8081`, tap points / long-press / sets / rename, and confirm `data/<user>/scoreboard.xml` and the web page `http://localhost:8081/<user>/scoreboard.html` show the same state. Run full test suite → pass. Note: `http://` needs `NSAllowsLocalNetworking` (`INFOPLIST_KEY_NSAppTransportSecurity` via project.yml `info.properties`) — add it; production is HTTPS.
- [ ] **Step 7: Commit** `"Add watch scoring, sets, names and config screens"`

### Task 7: TestFlight

**Files:**
- Modify: `watch/project.yml` (team, version, build number, icon), `watch/ScoreboardWatch/Assets.xcassets/AppIcon.appiconset` (1024×1024 PNG; derive from `html/volleyball_modern.png`)
- Create: `watch/ExportOptions.plist` (`method: app-store-connect`, `destination: upload`, `signingStyle: automatic`, `teamID`), `watch/README.md` (build + TestFlight steps)
- Modify: `README.md` (short "Apple Watch app" section linking `watch/README.md`)

- [ ] **Step 1: Ask Jan** for his Apple Developer team ID (show the IDs from `security find-identity -v -p codesigning`), set `DEVELOPMENT_TEAM`, `MARKETING_VERSION: 1.0`, `CURRENT_PROJECT_VERSION: 1`, regenerate.
- [ ] **Step 2: Jan's account steps** (list them, wait for confirmation): create App ID / app record in App Store Connect for `org.lindhardsen.scoreboard.watchkitapp` (name "Scoreboard Watch" or similar, platform watchOS); add himself as internal TestFlight tester.
- [ ] **Step 3: Archive & upload:** `xcodebuild -project watch/ScoreboardWatch.xcodeproj -scheme ScoreboardWatch -destination 'generic/platform=watchOS' -archivePath watch/build/ScoreboardWatch.xcarchive archive -allowProvisioningUpdates` then `xcodebuild -exportArchive -archivePath watch/build/ScoreboardWatch.xcarchive -exportOptionsPlist watch/ExportOptions.plist -exportPath watch/build/export -allowProvisioningUpdates` → "Upload succeeded". If the CLI upload fails on auth, fall back to Xcode Organizer (Jan clicks Distribute).
- [ ] **Step 4: Deploy server changes** — tell Jan the server must be updated and restarted before the watch can sign in (production deploy is his action).
- [ ] **Step 5: Commit** `"Prepare watch app for TestFlight"`
