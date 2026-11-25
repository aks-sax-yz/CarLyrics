# Car Lyrics (clone)

Detects the song playing on your iPhone and shows time-synced lyrics on the **CarPlay**
screen — a clone of the "Car Lyrics" / "Dynamic Lyrics" App Store category, built for
personal use. Supports **Apple Music** and **Spotify**.

## How it actually works (the important part)

There is no CarPlay *app* here, and **no CarPlay entitlement is needed**. Apple has no
CarPlay template that can render scrolling lyrics, and no entitlement category fits a lyrics
app. Instead, on **iOS 26**, WidgetKit widgets and **Live Activities** appear on the CarPlay
widgets page for every vehicle. This app:

1. **Detects the track** — Apple Music via `MediaPlayer` (`systemMusicPlayer`, on-device);
   Spotify via the official Web API (`/me/player/currently-playing`, OAuth PKCE polling).
   *(No system-wide "now playing" API exists for App Store apps — detection is per-source.)*
2. **Fetches lyrics**, the song's own service first, then [LRCLIB](https://lrclib.net)
   (free, no key, LRC synced lyrics), and caches them on disk:
   - **Apple Music songs:** Apple's own word-timed lyrics (the TTML music.apple.com's web player
     shows), via its private `amp-api` service with the web player's developer token and a user
     token minted from the Apple Music account already on the phone (StoreKit), so there is no
     sign-in. If Apple refuses that token, Settings › Apple Music offers music.apple.com's own
     sign-in instead (password + code; passkeys can't work inside apps). Line-timed when Apple
     has no word timing.
   - **Spotify songs:** Spotify's own lyrics (Musixmatch's, mostly line-timed), after a separate
     *Sign In for Spotify Lyrics* on Spotify's web page (it presents as Safari so Google sign-in
     works). The page's own requests carry the tokens; a small script reports them.
   - Both are **private and unofficial** (likely against Apple's/Spotify's terms; personal use).
     Any failure falls back to LRCLIB; a song a service has no lyrics for is remembered.
3. **Runs the sync engine** every second to find the current line from the playback position.
4. **Pushes a Live Activity** (`ActivityKit`) whose small presentation renders on CarPlay.

### The sync ceiling (shared by every app in this category)

ActivityKit applies opaque update budgets, especially while the display is off. Local lyric-line
updates may be delayed or frozen even when the app still has background runtime; Apple does not
publish a guaranteed interval. The **sync offset** knob (±3s) corrects playback-position drift, but
cannot override ActivityKit throttling. This is a platform limit, not a bug you can fully fix.

## Project layout

```
CarLyricsCore/     SwiftPM package — ALL testable logic, runs on macOS (swift test)
  LRCParser        parse standard + enhanced (word-level) LRC
  SyncEngine       position → current line (binary search, offset handling)
  LRCLibClient     LRCLIB fetch (get + search fallback)
  AppleTTML        Apple's lyrics TTML → lines + words (syllables joined, bg vocals dropped)
  AppleMusicLyrics / SpotifyLyrics   the services' lyrics requests + error mapping
  SpotifyClient    PKCE auth-URL/token/now-playing (pure, network-injected)
  LyricsStore      on-disk lyrics cache
App/               the iOS app (MusicKit, Spotify auth UI, coordinator, Live Activity push)
Widget/            WidgetKit extension — the Live Activity that renders on CarPlay
Support/           LyricsActivityAttributes.swift (shared by app + widget)
project.yml        xcodegen project definition
```

## Setup (one time)

1. **Install xcodegen** (already present on this machine): `brew install xcodegen`
2. **Generate the Xcode project** (`CarLyrics.xcodeproj` and `Generated/` are build outputs of
   `project.yml` and are gitignored — regenerate after every pull or source-tree change):
   ```
   cd CarLyricsClone && xcodegen generate && open CarLyrics.xcodeproj
   ```
3. **Set your Spotify Client ID** (only needed for Spotify support):
   - Create an app at <https://developer.spotify.com/dashboard>
   - Add redirect URI **`carlyrics://spotify-callback`**
   - Put the Client ID in `App/SpotifyController.swift` → `SpotifyConfig.clientID`
     (this build has Akshat's; dev-mode apps need a Premium owner and list ≤5 users)
   - (Apple Music needs no config.)
4. **Signing:** select the CarLyrics target → Signing & Capabilities → your Apple ID team.
   A **free** Apple ID works (7-day re-sign) since there's no special entitlement. Add the
   **Push Notifications** capability is *not* required (we use local Live Activity updates).
5. **Run** on your iPhone (iOS 26). Grant the Apple Music permission when asked; tap
   *Connect Spotify* to link Spotify.

## Getting lyrics onto CarPlay

1. Play a song (Apple Music or Spotify) with the app open once so it starts the Live Activity.
2. On the iPhone: **Settings › General › CarPlay › [your car] › Widgets** → add the **Lyrics**
   widget to a stack.
3. Create the one-time automation: **Shortcuts › Automation › + › CarPlay › Connects ›
   Run Immediately › New Blank Automation › Start Car Lyrics**. That action starts the lyrics
   Live Activity without opening the app, even with the phone locked. iOS has no "music started"
   trigger for apps; "App › Music › Is Opened" works as a second automation with the same action.
4. Connect to CarPlay — the lyrics appear on the widgets screen. Tune the **Sync** slider in
   the app until lines line up in your car.

**Only the Live Activity keeps time on CarPlay.** iOS gives it a fixed 227 × 90 pt box there
(2026-11-20 sysdiagnose: `family=small … width=Fixed<227.33>, height=Fixed<90.22>`), so the CarPlay
view is one row of the current line, one row of the next (dimmed), the progress bar and the song +
time; longer lines are cut into one-row parts. The bar is a Settings switch ("Progress Bar on
CarPlay", on by default): with it the lyrics are 18/14pt, without it 20/16pt. Lines change with a
0.3s bottom → top sweep (Slide, and Karaoke between lines), so both rows read as rolling up.

The **Lyrics widget** (`Widget/CarLyricsWidget.swift`, 18/14pt, fed the whole song through the App
Group by `Support/WidgetFeed.swift`) is there for anyone who wants it, but it can't keep time on
CarPlay: CarPlay draws widgets as still images (`presentation mode will change to static`), its
renderer loaded the widget once per drive, and iOS ran only 5 of 15 reloads (`computedBudget:
2.00`), so it can show an earlier song. `widget reload` lines in events.log show each request.

## Testing on the Simulator

The Simulator has no Music app, so the app defaults to a **Demo** source there (visible only
on the simulator): it feeds "Bohemian Rhapsody" with an advancing position so the full
fetch → parse → sync → scroll → Live Activity pipeline runs without a device.

**Corporate network (Netskope etc.):** the Simulator has its own trust store, so HTTPS to
LRCLIB fails with *"A TLS error caused the secure connection to fail"* until you add the corp
root CA to the booted simulator:
```bash
security find-certificate -a -c "Netskope" -p /Library/Keychains/System.keychain > /tmp/ns.pem
xcrun simctl keychain booted add-root-cert /tmp/ns.pem
```
A real iPhone off the corp Wi-Fi doesn't need this.

## Verifying

```bash
# Pure-logic tests (parser, sync math, PKCE, Spotify decode, cache, search ranking) — runs on macOS
cd CarLyricsCore && swift test

# Full app + widget compile for the simulator
cd .. && xcodebuild -project CarLyrics.xcodeproj -scheme CarLyrics \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```
CarPlay itself is testable in the Simulator via **I/O › External Displays › CarPlay** (no
entitlement required).

## When the widget freezes

Opening the app replaces the Live Activity with a fresh one, so a frozen widget recovers without
clearing it or force-quitting. To see *why* it froze, read the diagnostics row before anything else:

- `live activity: active … sys=ok` while the widget is stuck → iOS accepted every update but
  stopped drawing them.
- `sys=BEHIND` → iOS is dropping the updates.
- `ended` / `dismissed` / `none` → iOS ended the activity, and a backgrounded app can't start a
  new one.
- a new `gaps >3s` entry → the app itself was suspended.

The full timeline (song changes, CarPlay connects, activity state changes, a heartbeat every 30s) is
in `Documents/events.log` on the phone:
```bash
xcrun devicectl device copy from --device <iphone-id> --domain-type appDataContainer \
  --domain-identifier com.akshatsaxena01.carlyrics --source Documents/events.log --destination .
```
A SideStore install signs the app with your team ID appended, so use
`com.akshatsaxena01.carlyrics.<TEAMID>` (e.g. `….3HT9UJ3NF5`) as the domain identifier.

## Limitations & honest notes

- **Background:** the app process must be alive to poll Spotify and submit local ActivityKit
  updates. A Core Location background session keeps the process eligible after the screen locks,
  but ActivityKit can still throttle the visible Live Activity. The CarPlay-connect Shortcuts
  automation above starts the activity via `StartLyricsIntent`; no public API lets the app install
  that automation itself.
- **Tokens** (Spotify, Apple Music) live in the Keychain, readable after first unlock so a
  locked phone in the car can use them; never logged.
- **Lyrics licensing:** LRCLIB is community-contributed and unlicensed — fine for personal
  use, not for a commercial release (that needs a Musixmatch/LyricFind license).
- **Coverage:** LRCLIB can miss regional tracks. `LyricsKit` (NetEase/QQ providers) is the
  planned fallback — see the plan's Milestone 4.

## Word by word

With word-timed lyrics (Apple Music), the app's current line brightens word by word with a soft
edge, and a word held 1s+ (2–7 letters) swells letter by letter and glows, as in Apple Music.
On CarPlay, with Line Transition set to **Karaoke**, the sweep follows the words: words sung at an
even pace share one timer bar, so a row needs 1–2 (at most 4); the lock screen keeps one sweep
from the first word's start to the last word's end, and the Dynamic Island has none. If iOS ends
the Live Activity within a minute of an update with word timings, the app goes back to line
sweeps until CarPlay disconnects (`word sweep OFF` in the log).

The **Album** background is the blurred album art on the lock screen and CarPlay too (a 96px copy
in the App Group, a new file per song). CarPlay ignores `activityBackgroundTint`, so the CarPlay
view paints its background itself.

## Ideas to build next

Apple's background-vocal lines in the app, lyric translation, offline prefetch of a playlist's lyrics.
