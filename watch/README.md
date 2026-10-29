# Scoreboard Watch

A standalone Apple Watch app for manual scoring against the scoreboard server.
No iPhone app is needed.

- **Page 1, points:** tap a team to add a point (that team serves next), hold to remove one.
- **Page 2, sets:** `+` / `−` per team. `+` asks "Start next set at 0–0?". Reset match. The gear opens sign-out.
- **Page 3, names:** tap a name to change it with the keyboard, Scribble or dictation.

Swipe up/down or turn the Digital Crown to move between pages. The dot in the top
corner is green when the server has your latest score, grey while sending, and red
while offline (the watch keeps retrying, and points scored offline are never lost).
A red banner means the Profixio scraper is running for your user and will overwrite
manual points; stop it from the Control Panel.

Team names and jersey colours set on the web page are shown on the watch. Web and
watch can be used one after the other (the watch picks up web changes whenever you
raise your wrist), but not both during the same rally.

## Signing in

Server (e.g. `volley.lindhardsen.org`; `https://` is added if you leave it out),
username and password. The watch exchanges the password for your upload token via
`POST /<username>/api/token` and keeps only the token, in the Keychain. If the token
in `users.json` changes, the watch signs out and asks again.

The server must include the watch API (token endpoint, JSON feed on manual
uploads, `X-Scraper-Running` header) — deploy and restart it before signing in.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml`; the generated project is committed, so XcodeGen is only needed
after editing `project.yml`.

```bash
cd watch
xcodegen generate     # after changing project.yml
open ScoreboardWatch.xcodeproj
```

Tests:

```bash
# Unit tests
xcodebuild test -project ScoreboardWatch.xcodeproj -scheme ScoreboardWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)'

# End-to-end UI test: needs a local server on port 8091 with user demo / demo-pw
# (skipped otherwise)
xcodebuild test -project ScoreboardWatch.xcodeproj -scheme ScoreboardWatchUITests \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)'
```

## TestFlight

One-time, in [App Store Connect](https://appstoreconnect.apple.com):

1. Apps → `+` → New App: platform watchOS, name e.g. "Scoreboard Watch",
   bundle ID `org.lindhardsen.scoreboard.watchkitapp` (register it under
   Certificates, Identifiers & Profiles first if it isn't offered).
2. TestFlight → Internal Testing → add yourself as a tester.

Each build (bump `CURRENT_PROJECT_VERSION` in `project.yml` first):

```bash
cd watch
xcodegen generate
xcodebuild -project ScoreboardWatch.xcodeproj -scheme ScoreboardWatch \
  -destination 'generic/platform=watchOS' \
  -archivePath build/ScoreboardWatch.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/ScoreboardWatch.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

If the command-line upload can't authenticate, open the archive in Xcode
(Window → Organizer → Distribute App → TestFlight & App Store) instead.
Install from the TestFlight app on the iPhone paired with the watch.
