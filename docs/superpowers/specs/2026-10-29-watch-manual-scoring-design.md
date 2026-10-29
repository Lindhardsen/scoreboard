# Apple Watch manual scoring — design

Date: 2026-10-29
Status: approved 2026-10-29

## Intent

Manual scoring today happens on the web page `https://<server>/<username>/scoreboard.html`
(e.g. `https://volley.lindhardsen.org/jan/scoreboard.html`). Jan wants to do the same
from an Apple Watch while standing courtside: tap to give a team a point, long-press
to take one back, and manage sets on a second page. It is a miniature of the web
controller, laid out for the wrist, not a new scoring model.

It is a **new, separate app**. It does not go into Tubeist: Tubeist is usable without
the scoreboard server, and its maintainer wants to keep it that way.

## Goals

- Score a volleyball match from the watch without touching a phone or the web page.
- Changes appear on the overlay (OBS/vMix reading `scoreboard.xml`) just as web changes do.
- One-time setup on the watch: server URL, username, password.

## Non-goals (for this version)

- iPhone app. A phone app that replaces the web page and handles config is a good
  follow-up project, but is deliberately out of scope here *(Claude's call: ship the
  watch app first, prove it in a real match, then do the phone app)*.
- Editing jersey colours from the watch. They are set on the web page beforehand; the
  watch preserves them untouched. (Team names *are* editable — see page 3.)
- Undo/redo history, Profixio scraper control, stats, lineup mode.
- Concurrent scoring from web and watch. Jan confirmed it is one or the other during a
  match, never both, so last-write-wins is acceptable.

## Anti-goals

- Changing how the web page or overlay behaves. The existing web flow must keep working
  exactly as today.
- Tap targets that are easy to miss or mis-hit. Spacing and size matter more than
  showing everything.
- A point that silently doesn't reach the server. The user must be able to tell at a
  glance whether the watch is in sync.

## How it works today (relevant facts)

- `html/scoreboard.js` keeps the whole scoreboard as an XHTML fragment and uploads the
  **entire** fragment on every change: `POST /<username>/upload.php` with form fields
  `token`, `filename=scoreboard.xml`, `filedata=<xml>`. The token is a per-user secret
  from `users.json`, injected into `scoreboard.html` after web login (`server.py`, `user_scoreboard`).
- Current state is readable without auth at `GET /<username>/scoreboard.xml`.
- XML shape (see `html/scoreboard.xml`):
  ```xml
  <div xmlns="http://www.w3.org/1999/xhtml" id="scoreboard" class="scoreboard">
      <div class="home">
          <div id="home_set" class="set">1</div>
          <div id="home_color" class="color" style="background: rgb(0, 0, 255);"> </div>
          <div id="home_team" class="team" contenteditable="true">Eksjö Volleyboll IK</div>
          <div id="home_serve" class="serve"> </div>
          <div id="home_score" class="score">12</div>
      </div>
      <div class="away"> … same with away_ ids … </div>
  </div>
  ```
  The `serving` class on `*_serve` marks the serving team. The colour `style` may be
  absent (overlay theme decides). Scraper-written XML may lack `*_score` elements after
  a match ends; treat missing as 0 (the web does the same in `replace_scoreboard`).
- `GET /<username>/api/score` serves `scoreboard.json`, but only the Profixio scraper
  writes it (`scraper.write_scoreboard_json`). In manual mode it goes stale.
- Web scoring rules to mirror (`score()` in `scoreboard.js`):
  - Point +1 → that team becomes the server (rally scoring).
  - Point −1 → serve unchanged; never below 0.
  - Set +1 → asks "Start next set at 0–0?"; if yes, both points reset to 0.
  - Set −1 → never below 0; points unchanged.
  - Reset → all sets and points to 0, behind a confirmation.

## Server changes

1. **Token endpoint.** `POST /<username>/api/token` with form or JSON field `password`.
   On success returns `{"token": "<user token>"}`; on failure 401. Uses the same
   per-IP rate limiting as `/login` (`check_rate_limit` / `record_login_attempt`,
   5-minute window), returning 429 when limited. Unknown/invalid username → 404, same as
   other per-user routes. The watch never stores the password after it has the token
   *(Claude's call: store token, not password, in the Keychain; on a 403 from
   upload the app sends the user back to the config page)*.
2. **Keep `scoreboard.json` fresh in manual mode.** In `user_upload`, after writing
   `scoreboard.xml`, parse it and write `scoreboard.json` in the same shape the scraper
   writes (`home/away: name, sets, points`, `matchEnded: false`), atomically. A parse
   failure must not fail the upload (log and continue). Prefer reusing
   `write_scoreboard_json` from `scraper.py` rather than duplicating the payload shape.
3. **Tell the watch when the Profixio scraper is running.** The scraper rewrites
   `scoreboard.xml` on every poll, so manual uploads would be overwritten within
   seconds while the watch shows "synced". `upload.php` keeps returning `OK` (the web
   ignores the body) but adds a response header `X-Scraper-Running: 1` when a scraper is
   active for that user. The watch shows a clear warning banner while that is set.
   It does not stop the scraper. *(Claude's call: cheap, invisible to the web page,
   avoids a confusing "my points vanish" failure.)*
4. Tests in `tests/`, written with `unittest` like the existing test files.

Note: the server runs behind Caddy without ProxyFix, so `request.remote_addr` is always
the proxy and the login rate limit is effectively global; wrong passwords on the watch
and the web share one limit. This is existing `/login` behaviour and is not changed here.

No change to `scoreboard.html` / `scoreboard.js`.

## Watch app

**Platform:** standalone watchOS app (no iPhone companion), SwiftUI, Swift 6, no
third-party dependencies (same posture as Tubeist). Networking directly from the watch
via `URLSession`. *(Claude's calls: minimum watchOS 11; project lives in `watch/` in
this repo so the app and the server API it depends on version together.)*

### Config page

- Fields: server URL, username, password. "Sign in" calls the token endpoint.
- Server URL, username and token are stored in the Keychain; the password is discarded.
- Shown on first launch, and reachable later from a small gear on the sets page so you
  can sign out or change server.
- Clear error messages for: unreachable server, wrong password, rate-limited.

### Page 1 — Points (default page)

- Two large tap targets stacked vertically, home on top, away below, each filling
  roughly half the screen. Each shows the team name (one line, truncated) and the
  current points in a large number. A small dot marks the serving team. If a jersey
  colour is set, show it as a thin stripe/accent on that team's half.
- **Tap** = +1 point for that team (and that team serves).
- **Long press** = −1 point (not below 0).
- Haptic feedback on each change, distinct for + and −, so you can score without
  looking.
- Digital Crown is not used for scoring (too easy to trigger by accident).

### Page 2 — Sets

- Swipe left (vertical `TabView` page style is also fine — builder's choice) to reach it.
- Shows each team's name and set count with explicit **+** and **−** buttons per team.
- Set + asks "Start next set at 0–0?" (Yes / No), mirroring the web.
- "Reset match" button with confirmation, mirroring the web reset.
- Gear button to open config.

### Page 3 — Team names

- A third page (swipe on from the sets page) with two rows, home and away, each showing
  the current team name. Tapping a row opens standard watchOS text input (keyboard,
  Scribble or dictation), prefilled with the current name.
- Mirrors the web `set_team`: trimmed; an empty or unchanged name is ignored; otherwise
  the name is updated and the whole scoreboard uploaded like any other change.
- Names may contain non-ASCII characters (e.g. "Eksjö") and characters that need XML
  escaping (`&`, `<`); serialisation must escape them correctly.

### Sync behaviour

- On launch and every time the app becomes active, fetch `scoreboard.xml` and adopt it
  as the current state (the web may have been used in between) — **unless the watch has
  an unsent change**. In that case the watch's state wins: skip adopting and keep
  pushing the local state until it succeeds. *(Claude's call: wrist-down makes the app
  inactive constantly, often while offline; points scored on the watch must never be
  silently discarded. Since web and watch are never used at the same time, the risk of
  overwriting a web change is negligible.)*
- Every change is applied locally immediately (optimistic UI) and the **whole**
  scoreboard XML is uploaded, exactly as the web does. Because each upload is the full
  state, only the latest state matters: if an upload fails, keep retrying the latest
  state (with backoff) rather than queueing individual changes.
- A small status indicator shows synced / sending / offline. Retrying stops being
  "offline" as soon as an upload succeeds.
- When serialising, preserve colour `style` (and team names, unless edited on page 3)
  exactly as read; the output
  must be the same XML structure the web produces so the overlay and the web page
  both read it correctly.
- If `scoreboard.xml` doesn't exist yet (404), start from 0–0 with names "Home"/"Away".

## Distribution

- **TestFlight first, needed by 2026-10-30.** App Store release is not a priority; skip
  App Store review prep (screenshots, marketing text) for now.
- Needs: an App Store Connect app record, an app icon set, a bundle ID
  *(Claude's call: `org.lindhardsen.scoreboard.watchkitapp`; the Tubeist project uses
  a different team ID that may belong to the Tubeist developer, so confirm Jan's own
  team ID at build time)*, `ITSAppUsesNonExemptEncryption = NO` (only standard HTTPS),
  and a privacy manifest if the archive upload requires one.
- Steps that need Jan's Apple account (creating the App Store Connect record, accepting
  agreements, adding himself as a TestFlight tester) are listed for him to do; the
  build/archive/upload is scripted with `xcodebuild` where signing allows.
- Because of the deadline, order the work so a usable build reaches TestFlight early:
  server changes → watch scoring + config → TestFlight upload → polish.

## Left to the builder

- Exact visual styling, fonts, and how the serve dot and colour accent look.
- XML parsing approach (`XMLParser` or simple targeted parsing), as long as unknown
  content in the colour `style` is preserved.
- How the Xcode project is generated (hand-made `.xcodeproj` vs. XcodeGen), and
  watch-side unit tests for the XML round-trip and scoring rules.
- Retry/backoff timings.
