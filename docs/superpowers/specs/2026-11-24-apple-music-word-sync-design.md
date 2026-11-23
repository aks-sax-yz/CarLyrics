# Apple Music sign-in, word-by-word sync, Spotify sign-in

2026-11-24. Approved in chat by Akshat ("yes go ahead"). Built on `clocked-lyrics`. Nothing ships
to `main` (that publishes a release) until he says so.

## Goal

1. Apple Music songs use Apple's own lyrics, timed word by word (syllable by syllable). The app
   highlights each word as it's sung, and long-held words get Apple Music's swell and glow.
2. The CarPlay Live Activity sweeps per word within the iOS limits measured earlier: the 4 KB
   payload, the CPU cap that killed it on the 2026-11-14 drive, and the timer views that are the
   only thing that animates.
3. Spotify works: Akshat has Premium, so his own Spotify developer app can sign in.

Not in scope:
- YouTube. iOS gives an app no now-playing or position for YouTube, and Google blocks sign-in in
  embedded web views.
- Apple's background-vocal lines. CarPlay has no room. The parser keeps them, so the app can show
  them later.

## 1. Apple Music sign-in

**UI.** Settings › Apple Music shows "Connect Apple Music" (or "Connected · <country>", with
"Disconnect"; or "Reconnect" once the login expires). Connect opens a sheet with a `WKWebView` on
`https://music.apple.com/` and a Done button. Akshat signs in on Apple's page, including the
two-factor code. The app never reads or fills the form.

**Token capture.**
- **User token:** poll `WKHTTPCookieStore` every 1 s for the `media-user-token` cookie on
  `.music.apple.com`. It isn't HttpOnly and lasts about 6 months. When it appears, dismiss the sheet.
- **Developer token:** read `MusicKit.getInstance().developerToken` with `evaluateJavaScript`
  once the page has loaded. It's a JWT with `kid: WebPlayKid` and `iss: AMPWebPlay`, valid about
  70 days.
- **Popups:** the web view needs `javaScriptCanOpenWindowsAutomatically = true` and a
  `WKUIDelegate` that opens Apple's sign-in popup (`createWebViewWith`) in a second web view on
  the same configuration.

**Storage.** Both tokens go in the Keychain (`kSecClassGenericPassword`, service
`carlyrics.apple`, `AfterFirstUnlock`, so a locked phone in the car can still read them). The
storefront goes in the Keychain too. Tokens are never logged; logs show `token=<n chars>` at most.

**Storefront.** After capture, call `GET https://amp-api.music.apple.com/v1/me/storefront`. Store
`data[0].id` (e.g. `in`). Every lyrics request uses it, because a wrong storefront gives 404 on
every song.

**Expiry and refresh.**
- 401 means the developer token is stale. Reload `music.apple.com` in an off-screen web view that
  shares the cookie store, re-read `developerToken`, and retry once.
- If the request still fails with 401 or 403, the user token is dead. Mark it "Reconnect" and fall
  back to LRCLIB.
- Error code 40403 means no subscription. Show "Apple Music subscription needed" and fall back.

**Disconnect.** Delete the Keychain items and clear the web view's data store
(`WKWebsiteDataStore.default().removeData`).

## 2. Getting lyrics

**Which song.** `AppleMusicSource.sampleNow()` adds `item.playbackStoreID` (the catalog ID, empty
for local files) to `NowPlayingTrack` as `catalogID: String?`. The field is optional, so old cache
JSON still decodes.

**The request.**

```
GET https://amp-api.music.apple.com/v1/catalog/{sf}/songs/{id}/syllable-lyrics
    ?l[lyrics]=en-US&l[script]=en-Latn&extend=ttmlLocalizations
Authorization: Bearer <developer token>
media-user-token: <user token>
Origin: https://music.apple.com
Referer: https://music.apple.com/
```

- The TTML is at `data[0].attributes.ttmlLocalizations ?? data[0].attributes.ttml`.
- On 404 or empty, try `/lyrics` (line-timed only) with the same headers.

**Order for an Apple Music song with a catalog ID while connected:**
1. Apple `syllable-lyrics`;
2. Apple `lyrics`;
3. LRCLIB, unchanged (consensus shift included).

Spotify songs, local files and the not-connected state go straight to LRCLIB, as today.

**Parsing (`AppleTTMLParser`, CarLyricsCore, no dependencies, `XMLParser`).**
- **Lines and words.** Each `<p begin end itunes:key ttm:agent>` is a line. Each timed `<span>` is
  a syllable. Adjacent spans with no whitespace between them are one word. Whitespace text nodes
  are word breaks.
- **Model changes.** `LyricsLine.Word` gains `endMs: Int?`, and `LyricsLine` gains `endMs: Int?`.
  Both are optional, so old cache JSON still decodes. A word's `timeMs` is its first syllable's
  begin and its `endMs` is its last syllable's end. Syllable times inside a word aren't kept,
  because neither the sweep nor the swell uses them.
- **Background vocals.** Spans with `ttm:role="x-bg"` are dropped from the line text and words.
- **Line-timed TTML.** If there are no spans, `<p>` begin and end give the line only.
- **Times.** Times come as `ss.fff`, `m:ss.fff`, or `h:mm:ss.fff`. Some files use a trailing `s`.
  Parse all four.
- **Transliteration.** If `<head>` holds `<transliterations>` keyed by `itunes:key`, use them for
  the line text and spans. The `l[script]` param asks Apple for them.
- **Romanization.** Lines that are still non-Latin go through the existing
  `Transliterator.romanized`, as today.
- **Offset.** `TimedLyrics.source = "apple syllable id=<id>"` (or `apple line`), and
  `offsetMs = 0`. There is no consensus shift (Apple's timing is for Apple's audio). The per-song
  Sync offset still applies.

**Cache.**
- Apple results are saved with `LyricsStore` under the same key as today.
- A cached LRCLIB copy of an Apple Music song is upgraded once when Apple is connected. It keeps
  showing while Apple is asked in the background, then is replaced if Apple has lyrics.
- An Apple miss is remembered by saving the LRCLIB copy with `source` suffixed ` apple=none`, so it
  isn't asked again.

**Rate.** Apple requests go one at a time (a single `Task` in flight; a new song cancels the old
one), with no retries beyond the one developer-token refresh. Errors log the HTTP code and Apple's
error code, never headers.

## 3. In the app: word by word

The active line only (other lines stay as today: opacity, scale 0.96, spring). The active line
gets a `TimelineView(.animation)`, which runs at display rate only while it's on screen, and a
`TextRenderer` that draws each word's glyph runs. Word runs are found by matching character
ranges.

**Sweep.**
- Each word goes from 0.4 to 1.0 opacity as a soft edge crosses it left to right. The gradient
  edge is ±0.45 em, and its progress is (now − word.start) / (word.end − word.start).
- Words without `endMs` (LRCLIB enhanced LRC) end at the next word's start.
- Lines without words (plain LRCLIB) keep today's whole-line highlight.
- While a word is being sung, it lifts by 0.05 em and settles over its duration.

**Held word (Apple's swell).**
- **Trigger:** duration D ≥ 1.0 s, 2–7 letters (graphemes), not background vocals.
- **Per letter i of n:**
  - Start: delay = i · min(0.4·D/n, 0.4 s).
  - Envelope: rise over 2·D/n, then a smooth return over min(D, 3) s.
  - Strength: k = clamp(D − 1, 0, 1).
  - Scale: 1 + 0.1·k·env. Spread: ±0.05 em·k·env from the word's centre. Lift: −0.05 em·k·env.
  - Glow: white shadow, radius 0.18 em, opacity 0.45·clamp((D − 1)/0.5, 0, 1)·env.
- These numbers are from the published measurements (AMLL, YouLy+, Spicy Lyrics agree). The code
  is written fresh; nothing is copied from those projects (AMLL and others are GPL/AGPL).

**Cost.** One line redraws per frame. The rest of the list only changes on line change (today's
`TimelineView(.explicit(lineDates))`). Low Power Mode drops to the sweep without the swell.

## 4. CarPlay Live Activity

Facts this is built on, from the 2026-11-14 and 2026-11-23 drives:
- Only timer views animate.
- The CarPlay box is 227 × 90 pt.
- The extension was killed for CPU when it built three archives per push.
- The 4 KB payload limit.

**Payload.**
- `TimedLine` gains `w: String?`: words as `chars.startMs[.endMs]` joined by spaces, times
  relative to the line's `at`. Example: `5.0.420 3.480.1900 6.1950`.
- About 700 bytes more per window. The existing trim loop (`NowPlayingCoordinator` ~552) still
  drops lines until the state fits 4 KB.
- Logged per push: bytes, lines, words.

**Segments (`WordSweep.segments`, Support, unit-tested).**
- The CarPlay row is one line (`LyricFit.split` part).
- Words merge into piecewise-linear segments: a word joins the current segment if its x/time slope
  is within 100 ms of the segment's straight line. A gap over 150 ms between words starts a new
  segment.
- Typical result: 1–2 segments per row, at most 4 (more than 4 merges the smallest-error pair
  until 4).
- Each segment is one timer `ProgressView` (the existing `Step` bar):
  - It runs over [t0 − 0.05·d, t1 + 0.05·d] to cover the bar's overscan.
  - It is clipped to the segment's x-range [x0, x1].
  - x comes from `CTLineGetOffsetForStringIndex` on the row's `CTLine` (the font from
    `LyricFit.font`).

**Rendering (small family only).**
- **Per row:** one flatten (`compositingGroup().contrast(3).luminanceToAlpha()`) over all its
  segments, not one per segment.
- **Solid backgrounds:** the hide Step is dropped (the dim copy shows through). Glass keeps both
  Steps. On Glass that is the same view count as today's Karaoke.
- **Held words:** a second copy of the word at full white with a white shadow, under a timer mask
  that fades it in from the word's start and out at its end. CarPlay can't animate scale, so this
  is the only part of the swell it shows.
- **Lock screen:** keeps the whole-line sweep, but starts at the first word's real start and ends
  at the last word's real end (today it spans the line to the next line).
- **Dynamic Island:** no sweep.

**When it's used.**
- Only when Line Transition is Karaoke and the line has `w`. Otherwise it's today's behaviour.

**Safety net.**
- If ActivityKit ends the activity (state `.dismissed` / `.ended` not caused by us) within 60 s of
  a push that carried `w`, set a flag for the rest of the drive (cleared when CarPlay disconnects)
  and send no more `w`.
- That falls back to today's line sweep.
- Log the event so the drive log shows it.

## 5. Spotify

The sign-in (PKCE in `ASWebAuthenticationSession`) and polling are already built. They need a
Client ID, which needs Akshat:
1. Go to https://developer.spotify.com/dashboard and sign in with the Premium account. Choose
   **Create app**.
2. Name it anything. Set the redirect URI to `carlyrics://spotify-callback`. Tick **Web API**.
   Save.
3. Open **Settings**, copy the **Client ID**, and send it. The Client ID isn't a secret: PKCE has
   no client secret.
4. Dev-mode apps only work for listed users. The owner is listed automatically. Anyone else goes
   under **User Management** (max 5).

Then:
- `SpotifyConfig.clientID` gets the ID.
- The tokens move from UserDefaults to the same Keychain helper as Apple (service
  `carlyrics.spotify`), with a one-time move of any saved tokens.
- Lyrics for Spotify songs stay on LRCLIB, as Akshat asked.

## 6. Files

New:
- `CarLyricsCore/.../AppleTTMLParser.swift`
- `CarLyricsCore/.../AppleMusicLyricsClient.swift` (request building, status and error-code
  mapping; the tokens are passed in)
- `App/AppleMusicAccount.swift` (web view sheet, token capture, Keychain, storefront, refresh)
- `App/Keychain.swift` (about 30 lines)
- `App/WordLineRenderer.swift` (TextRenderer)
- `Support/WordSweep.swift` (segments)

Changed:
- `Models.swift` (`catalogID`, `endMs`)
- `AppleMusicSource.swift` (`playbackStoreID`)
- `NowPlayingCoordinator.swift` (source order, cache upgrade, `w` in `TimedLine`, kill switch)
- `LyricsActivityAttributes.swift` (`w`)
- `LyricsLiveActivityWidget.swift` (segments in the small family; lock screen word bounds)
- `ContentView.swift` (active line renderer)
- `SettingsView.swift` (Apple Music row)
- `SpotifyController.swift` (Client ID, Keychain)
- `README.md`

## 7. Testing

**Core unit tests (`swift test`):**
- TTML fixtures: syllables joined into words, background vocals dropped, line-only TTML, all
  four time formats, transliteration by key, non-Latin falling through to the romanizer.
- Error mapping: 401, 403, 404, 40403.

**App tests:**
- `WordSweep.segments`: even pace gives 1 segment, a held word splits, a gap over 150 ms splits,
  never more than 4.
- The payload with `w` for a dense window stays under 4 KB after trimming.

**Simulator:** the throwaway host app plus `simctl io screenshot`, at the small family's 227 × 90.
Check mid-word sweeps on Glass and on solid backgrounds. ImageRenderer can't draw the timer masks.

**On the phone:** only after Akshat says to install. Run a drive with Karaoke on, then read
`events.log` (push bytes, any kill-switch event) and check for `cpu_resource` reports in the
sysdiagnose.

## Risks

- The `amp-api` lyrics endpoint and the web-player token are private. Apple can change them
  without notice. Every failure falls back to LRCLIB, so the worst case is today's app.
- Using them is likely against Apple Music's terms. This is a personal sideload, not an App Store
  app.
- The developer token comes from Apple's web page. If `MusicKit.getInstance()` is renamed, fall
  back to finding the `WebPlayKid` JWT in the page's JS bundle with a regex, as gamdl does (MIT).
