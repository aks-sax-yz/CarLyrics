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
2. **Fetches lyrics** from [LRCLIB](https://lrclib.net) (free, no key, LRC synced lyrics),
   parses the `[mm:ss.xx]` timestamps, and caches them on disk.
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
  SpotifyClient    PKCE auth-URL/token/now-playing (pure, network-injected)
  LyricsStore      on-disk lyrics cache
App/               the iOS app (MusicKit, Spotify auth UI, coordinator, Live Activity push)
Widget/            WidgetKit extension — the Live Activity that renders on CarPlay
Support/           LyricsActivityAttributes.swift (shared by app + widget)
project.yml        xcodegen project definition
```

## Setup (one time)

1. **Install xcodegen** (already present on this machine): `brew install xcodegen`
2. **Generate the Xcode project:**
   ```
   cd CarLyricsClone && xcodegen generate && open CarLyrics.xcodeproj
   ```
3. **Set your Spotify Client ID** (only needed for Spotify support):
   - Create an app at <https://developer.spotify.com/dashboard>
   - Add redirect URI **`carlyrics://spotify-callback`**
   - Put the Client ID in `App/SpotifyController.swift` → `SpotifyConfig.clientID`
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
3. Create the required one-time automation: **Shortcuts › Automation › + › CarPlay › Connects ›
   Run Immediately › New Blank Automation › Open App › Car Lyrics**. iOS provides no API for an
   ordinary app to launch itself when CarPlay connects; the automation is the supported trigger.
4. Connect to CarPlay — the lyrics appear on the widgets screen. Tune the **Sync** slider in
   the app until lines line up in your car.

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
# Pure-logic tests (30 tests: parser, sync math, PKCE, Spotify decode, cache) — runs on macOS
cd CarLyricsCore && swift test

# Full app + widget compile for the simulator
cd .. && xcodebuild -project CarLyrics.xcodeproj -scheme CarLyrics \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```
CarPlay itself is testable in the Simulator via **I/O › External Displays › CarPlay** (no
entitlement required).

## Limitations & honest notes

- **Background:** the app process must be alive to poll Spotify and submit local ActivityKit
  updates. A Core Location background session keeps the process eligible after the screen locks,
  but ActivityKit can still throttle the visible Live Activity. The CarPlay-connect Shortcuts
  automation above launches the app; no public API lets the app install that automation itself.
- **Spotify token storage** uses `UserDefaults` (personal build). Move to Keychain before any
  wider distribution.
- **Lyrics licensing:** LRCLIB is community-contributed and unlicensed — fine for personal
  use, not for a commercial release (that needs a Musixmatch/LyricFind license).
- **Coverage:** LRCLIB can miss regional tracks. `LyricsKit` (NetEase/QQ providers) is the
  planned fallback — see the plan's Milestone 4.

## Ideas to build next (Milestone 5)

Word-level karaoke highlight (the parser already keeps word timings), lyric translation /
transliteration, offline prefetch of a playlist's lyrics, and a ShazamKit mic fallback for
radio / YouTube Music.
