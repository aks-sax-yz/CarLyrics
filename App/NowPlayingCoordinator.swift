import Foundation
import CoreImage
import os
import notify
import AVFAudio
import SwiftUI
import WidgetKit
import CarLyricsCore

/// The brain: samples the active source, fetches + caches lyrics on song change, runs the
/// SyncEngine every tick, publishes state for the in-app UI, and pushes the Live Activity
/// that renders on CarPlay.
@MainActor
final class NowPlayingCoordinator: ObservableObject {
    /// One instance for the app UI and `StartLyricsIntent`: a Shortcuts run can launch the app in
    /// the background, where no scene (and no `onAppear`) exists to create or start one.
    static let shared = NowPlayingCoordinator()
    enum SourceMode: String, CaseIterable, Identifiable {
        case auto, appleMusic, spotify
        #if targetEnvironment(simulator)
        case demo
        #endif
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .appleMusic: "Apple Music"
            case .spotify: "Spotify"
            #if targetEnvironment(simulator)
            case .demo: "Demo"
            #endif
            }
        }
    }

    @Published var sourceMode: SourceMode = .auto {
        didSet {
            guard oldValue != sourceMode else { return }
            EventLog.log("mode \(sourceMode.rawValue)")
        }
    }
    /// What the widget draws behind the lyrics.
    enum LyricsBackground: String, CaseIterable, Identifiable {
        case solid, albumArt, glass
        var id: String { rawValue }
        var label: String {
            switch self {
            case .solid: "Solid"
            case .albumArt: "Album"
            case .glass: "Glass"
            }
        }
    }

    @Published var lyricsBackground: LyricsBackground {
        didSet { UserDefaults.standard.set(lyricsBackground.rawValue, forKey: Self.backgroundKey) }
    }
    @Published var solidColor: LyricsActivityAttributes.RGB {
        didSet { UserDefaults.standard.set([solidColor.r, solidColor.g, solidColor.b], forKey: Self.solidColorKey) }
    }
    @Published var lineTransition: LyricsActivityAttributes.Transition {
        didSet { UserDefaults.standard.set(lineTransition.rawValue, forKey: Self.transitionKey) }
    }
    /// The progress bar in the CarPlay Live Activity; off gives the lyrics their full size.
    @Published var carPlayProgress: Bool {
        didSet { UserDefaults.standard.set(carPlayProgress, forKey: Self.carPlayProgressKey) }
    }
    /// Average colour of the current Apple Music artwork; nil for other sources or no art.
    private var albumColor: LyricsActivityAttributes.RGB?
    @Published private(set) var track: NowPlayingTrack?
    /// Apple Music artwork for the lyrics screen; nil for other sources.
    @Published private(set) var artwork: UIImage?
    @Published private(set) var lyrics: TimedLyrics?
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var status: String = "Idle" {
        didSet { if status != oldValue { EventLog.log("status \(status)") } }
    }
    /// Diagnostics for the background-freeze investigation: the largest gap (seconds) seen
    /// between consecutive ticks. If the app is suspended in the background, the tick after it
    /// resumes records a big gap → proves suspension. Stays ~1s if it never suspended.
    @Published private(set) var maxTickGap: Double = 0
    @Published private(set) var keepAliveStatus: BackgroundKeepAlive.Status = .starting
    /// Not published: it changes every location callback and would redraw the lyrics each second.
    var lastLocationUpdate: Date? { keepAlive.lastLocationUpdate }
    /// When each lyric line starts, for the in-app lyrics: a TimelineView switches lines exactly
    /// on these instead of on the 1s tick. Empty when paused or unsynced (the view then falls back
    /// to `currentLineIndex`). Published only when it actually changes (anchor/offset/song).
    @Published private(set) var lineDates: [Date] = []
    /// Pre-blurred artwork for the lyrics background (blurred once per song, not live per frame).
    @Published private(set) var artworkBackdrop: UIImage?
    @Published private(set) var isCarPlayConnected = false
    @Published private(set) var activityUpdateAttempts = 0
    @Published private(set) var lastActivityUpdateAttempt: Date?
    @Published private(set) var activityHealth = ""
    @Published private(set) var tickGapEvents: [TickGapEvent] = []
    private var lastTickWallClock: Date?

    struct TickGapEvent: Codable, Identifiable {
        let timestamp: Date
        let gap: Double
        var id: Date { timestamp }
    }

    func resetDiagnostics() {
        maxTickGap = 0
        tickGapEvents = []
        UserDefaults.standard.removeObject(forKey: Self.tickGapsKey)
        liveActivity.resetDiagnostics()
        refreshActivityDiagnostics()
    }
    /// The sync offset in effect: this song's saved one, else the default (Settings › Sync).
    /// LRCLIB timings come from different uploaders, so each song can need its own.
    @Published private(set) var userOffsetMs: Int {
        didSet { engine.userOffsetMs = userOffsetMs }
    }
    private var songOffsets: [String: Int]

    /// The default sync for every song without its own (Settings › Sync).
    @Published private(set) var defaultOffsetMs: Int
    /// Whether the playing song has its own saved sync (set with the lyrics screen's Sync pill).
    @Published private(set) var currentSongHasOwnOffset = false

    /// The Sync pill: this song only, remembered for it. The default is untouched (it used to follow
    /// the latest adjustment, so fixing one odd song moved every other song too).
    func setOffsetForCurrentSong(_ ms: Int) {
        userOffsetMs = ms
        refreshLineDates() // the highlight moves now, not on the next tick
        guard let key = track?.identityKey else { return }
        songOffsets[key] = ms
        currentSongHasOwnOffset = true
        UserDefaults.standard.set(songOffsets, forKey: Self.songOffsetsKey)
    }

    /// Settings › Sync default: applies now unless the playing song has its own.
    func setDefaultOffset(_ ms: Int) {
        defaultOffsetMs = ms
        UserDefaults.standard.set(ms, forKey: Self.offsetKey)
        if !currentSongHasOwnOffset {
            userOffsetMs = ms
            refreshLineDates()
        }
    }

    /// Drop the playing song's own sync and go back to the default.
    func resetCurrentSongOffset() {
        guard let key = track?.identityKey else { return }
        songOffsets[key] = nil
        currentSongHasOwnOffset = false
        UserDefaults.standard.set(songOffsets, forKey: Self.songOffsetsKey)
        userOffsetMs = defaultOffsetMs
        refreshLineDates()
    }

    let appleMusic = AppleMusicSource()
    let spotify = SpotifyController()
    let appleAccount = AppleMusicAccount()
    let spotifyLyrics = SpotifyLyricsAccount()
    private let keepAlive = BackgroundKeepAlive()
    #if targetEnvironment(simulator)
    private let demoSource = DemoSource()
    #endif

    private let lrclib = LRCLibClient()
    private let store: LyricsStore = {
        let store = LyricsStore.caches()
        store.pruneExpired() // lyrics not played for 30 days
        return store
    }()
    private let liveActivity = LiveActivityController()
    private var engine = SyncEngine()

    private var lastPlayback: PlaybackState?
    /// Consecutive ticks with nothing playing. Debounces `clear()` so a 1-2s track-change gap
    /// (Apple Music briefly reports no item between songs) doesn't tear down the Live Activity.
    private var missCount = 0
    private var lastSpotifyPoll: Date?
    private var spotifyAnchor: PlaybackState?
    private var loopTask: Task<Void, Never>?
    private var observingRoutes = false
    private var lyricsFetchToken = UUID()
    /// Set after a network/HTTP failure so the current song's lyrics are retried, not given up on.
    private var lyricsRetryAt: Date?
    private var wasInBackground = false
    private var lastHeartbeat = Date.distantPast
    private var songStartAnchor: Date?
    private var anchorTrack: NowPlayingTrack?

    private static let offsetKey = "sync.userOffsetMs"
    private static let songOffsetsKey = "sync.songOffsetsMs"
    private static let backgroundKey = "lyrics.background"
    private static let solidColorKey = "lyrics.solidColor"
    private static let transitionKey = "lyrics.transition"
    private static let carPlayProgressKey = "lyrics.carPlayProgress"
    private static let tickGapsKey = "diagnostics.tickGaps"
    private static let carPlayKey = "diagnostics.carPlayConnected"
    private static let spotifyPollInterval: TimeInterval = 3
    private static let significantTickGap: TimeInterval = 3
    private static let maxStoredTickGaps = 8
    private static let lyricsRetryDelay: TimeInterval = 15
    private static let heartbeatInterval: TimeInterval = 30

    init() {
        defaultOffsetMs = UserDefaults.standard.integer(forKey: Self.offsetKey)
        userOffsetMs = UserDefaults.standard.integer(forKey: Self.offsetKey)
        songOffsets = UserDefaults.standard.dictionary(forKey: Self.songOffsetsKey) as? [String: Int] ?? [:]
        lyricsBackground = UserDefaults.standard.string(forKey: Self.backgroundKey)
            .flatMap(LyricsBackground.init(rawValue:)) ?? .solid
        let rgb = UserDefaults.standard.array(forKey: Self.solidColorKey) as? [Double] ?? []
        solidColor = rgb.count == 3 ? .init(r: rgb[0], g: rgb[1], b: rgb[2]) : .black
        lineTransition = UserDefaults.standard.string(forKey: Self.transitionKey)
            .flatMap(LyricsActivityAttributes.Transition.init(rawValue:)) ?? .instant
        carPlayProgress = UserDefaults.standard.object(forKey: Self.carPlayProgressKey) as? Bool ?? true
        engine.userOffsetMs = userOffsetMs
        if let data = UserDefaults.standard.data(forKey: Self.tickGapsKey),
           let stored = try? JSONDecoder().decode([TickGapEvent].self, from: data) {
            tickGapEvents = stored
            maxTickGap = stored.map(\.gap).max() ?? 0
        }
        isCarPlayConnected = Self.currentRouteHasCarPlay
        UserDefaults.standard.set(isCarPlayConnected, forKey: Self.carPlayKey)
        refreshActivityDiagnostics()
        #if targetEnvironment(simulator)
        sourceMode = .demo // no Music app on the simulator — start in the demo pipeline
        #endif
    }

    func start() {
        appleMusic.start()
        keepAlive.start() // location keep-alive runs in every mode
        handleCarPlayRouteChange()
        guard loopTask == nil else { return }
        EventLog.log("app start state=\(Self.appState) widgetGroup=\(AppGroup.url != nil) build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?") mode=\(sourceMode.rawValue) carplay=\(isCarPlayConnected)")
        // Observer only once — start() can re-run from SwiftUI onAppear without meaning "restart".
        // Block observer on the main queue: AVAudioSession can post route changes off the main
        // thread, and a selector into this @MainActor class would trip Swift 6's isolation check.
        if !observingRoutes { // the loop can restart after Stop Car Lyrics; the observers stay
            observingRoutes = true
            // System pressure that could explain a frozen widget, for the event log.
            let center = NotificationCenter.default
            for (name, label) in [(UIApplication.didReceiveMemoryWarningNotification, "memory warning"),
                                  (UIApplication.willTerminateNotification, "will terminate"),
                                  (ProcessInfo.thermalStateDidChangeNotification, "thermal changed"),
                                  (Notification.Name.NSProcessInfoPowerStateDidChange, "power mode changed")] {
                _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        EventLog.log("system \(label): thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) mem=\(os_proc_available_memory() / 1_048_576)MBfree")
                    }
                }
            }
            // Screen off/on, to test whether freezes start when the display goes fully dark
            // (Akshat's lead, 2026-11-19). ponytail: SpringBoard's Darwin notification, not public
            // API; if a future iOS stops posting it, these lines just stop appearing.
            var screenToken: Int32 = 0
            notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &screenToken, .main) { token in
                var blanked: UInt64 = 0
                notify_get_state(token, &blanked)
                MainActor.assumeIsolated {
                    EventLog.log("screen \(blanked == 1 ? "off" : "on") locked=\(!UIApplication.shared.isProtectedDataAvailable)")
                }
            }
            _ = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleCarPlayRouteChange() }
            }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// `StartLyricsIntent` entry point. Starts the loop if a background launch skipped `onAppear`,
    /// then requests the activity right away: the intent's run is what lets iOS grant it from the
    /// background, so it can't wait for the next tick (and nothing may be playing yet).
    func startFromIntent() async {
        EventLog.log("intent: start lyrics (activity \(liveActivity.healthSummary))")
        start()
        await liveActivity.ensureActivity(songId: track?.identityKey ?? "idle", initial: idleState)
        refreshActivityDiagnostics()
    }

    /// Tapping a lyric line jumps Apple Music to where that line shows (the other sources can't seek).
    var canSeek: Bool { track?.source == .appleMusic && lyrics?.isSynced == true }

    func seek(toLine index: Int) {
        guard canSeek, let lyrics, lyrics.lines.indices.contains(index) else { return }
        // A line shows when position + user offset + file offset reaches its time (see SyncEngine).
        let positionMs = lyrics.lines[index].timeMs - lyrics.offsetMs - userOffsetMs
        appleMusic.seek(toMs: positionMs)
        songStartAnchor = Date().addingTimeInterval(-Double(max(0, positionMs)) / 1000) // highlight jumps now
        refreshLineDates()
        EventLog.log("seek to line \(index + 1) by tap")
    }

    /// "Car Lyrics froze" (Siri / Shortcuts): a marked snapshot in the log at the moment the user
    /// saw the widget stuck, to line up with the push log and the system's jetsam reports.
    func markFreeze() {
        let session = AVAudioSession.sharedInstance()
        let am = appleMusic.sampleNow().map { "\($0.isPlaying ? "playing" : "paused")@\($0.positionMs / 1000)s" } ?? "none"
        let line = currentLineIndex.map { "\($0 + 1)/\(lyrics?.lines.count ?? 0)" } ?? "-"
        EventLog.log("FREEZE REPORTED state=\(Self.appState) song=\"\(track?.title ?? "-")\" line=\(line) act=[\(liveActivity.healthSummary)] lastPush=\(liveActivity.lastUpdateAttempt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never") am=\(am) other=\(session.isOtherAudioPlaying) carplay=\(isCarPlayConnected) loop=\(loopTask != nil) keepalive=\(keepAliveStatus) mem=\(os_proc_available_memory() / 1_048_576)MBfree thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "fg"
        case .inactive: "inactive"
        case .background: "bg"
        @unknown default: "?"
        }
    }

    /// `StopLyricsIntent` entry point: end every lyrics activity, stop the loop and the
    /// location keep-alive, and clear the song, so nothing keeps the app awake. Opening the app
    /// (or the Start intent) brings it all back via `start()`.
    func stopFromIntent() async {
        EventLog.log("intent: stop lyrics")
        loopTask?.cancel()
        loopTask = nil
        keepAlive.stop()
        await liveActivity.endAll()
        lastPlayback = nil
        track = nil
        artwork = nil
        artworkBackdrop = nil
        lyrics = nil
        currentLineIndex = nil
        lineDates = []
        status = "Stopped"
        refreshActivityDiagnostics()
    }

    /// Becoming active swaps in a fresh Live Activity if the current one is a leftover or has
    /// been through the background — so a frozen widget recovers just by opening the app (no
    /// clearing it, no force-quit). See `LiveActivityController.restart()`.
    func scenePhaseChanged(_ phase: ScenePhase) {
        EventLog.log("phase \(phase)")
        switch phase {
        case .active:
            start() // idempotent; restarts the loop after a Stop Car Lyrics run
            keepAlive.appBecameActive()
            Task { await liveActivity.restart(); refreshActivityDiagnostics() }
            wasInBackground = false
        case .background:
            wasInBackground = true
            liveActivity.appEnteredBackground()
        default:
            break
        }
    }

    nonisolated static func shouldEndActivity(wasCarPlayConnected: Bool, isCarPlayConnected: Bool) -> Bool {
        wasCarPlayConnected && !isCarPlayConnected
    }

    private static var currentRouteHasCarPlay: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    private func handleCarPlayRouteChange() {
        let connected = Self.currentRouteHasCarPlay
        let shouldEnd = Self.shouldEndActivity(
            wasCarPlayConnected: isCarPlayConnected,
            isCarPlayConnected: connected
        )
        if connected != isCarPlayConnected { EventLog.log("carplay \(connected ? "connected" : "disconnected")") }
        isCarPlayConnected = connected
        UserDefaults.standard.set(connected, forKey: Self.carPlayKey)
        if shouldEnd {
            Task { await liveActivity.endCurrent(); refreshActivityDiagnostics() }
        }
    }

    // MARK: Tick loop

    private func tick() async {
        let now = Date()
        if let last = lastTickWallClock {
            let gap = now.timeIntervalSince(last)
            if gap > maxTickGap { maxTickGap = gap }
            if gap > Self.significantTickGap { recordTickGap(gap, at: now) }
        }
        lastTickWallClock = now
        let keepAliveNow = keepAlive.status
        if keepAliveNow != keepAliveStatus {
            EventLog.log("keep-alive \(keepAliveNow)")
            keepAliveStatus = keepAliveNow
        }
        refreshActivityDiagnostics()
        heartbeatIfDue(now)

        guard let playback = await resolvePlayback() else {
            missCount += 1
            if missCount >= 3, lastPlayback != nil { clear() } // debounce brief track-change gaps
            return
        }
        missCount = 0

        if playback.track.isDifferentSong(from: track) {
            track = playback.track
            currentSongHasOwnOffset = songOffsets[playback.track.identityKey] != nil
            userOffsetMs = songOffsets[playback.track.identityKey] ?? defaultOffsetMs
            albumColor = playback.track.source == .appleMusic ? appleMusic.artworkColor() : nil
            artwork = playback.track.source == .appleMusic ? appleMusic.artworkImage() : nil
            artworkBackdrop = Self.backdrop(from: artwork)
            #if targetEnvironment(simulator)
            if sourceMode == .demo { artwork = DemoSource.artwork; artworkBackdrop = Self.backdrop(from: artwork) }
            #endif
            EventLog.log("song \"\(playback.track.title)\" — \(playback.track.artist) [\(playback.track.source.rawValue)]")
            loadLyrics(for: playback.track) // non-blocking: fetch runs async, loop keeps ticking
        } else if let retryAt = lyricsRetryAt, now >= retryAt {
            loadLyrics(for: playback.track)
        }
        lastPlayback = playback

        let posNow = playback.extrapolatedPositionMs(now: Date())
        await updateSync(positionMs: posNow, playback: playback)
    }

    /// Choose the source to read this tick.
    private func resolvePlayback() async -> PlaybackState? {
        switch sourceMode {
        case .appleMusic:
            return appleMusic.sampleNow()
        case .spotify:
            return await spotifyPlayback()
        case .auto:
            // Local Apple Music read is cheap; prefer it when actually playing.
            if let am = appleMusic.sampleNow(), am.isPlaying { return am }
            if spotify.isLoggedIn, let sp = await spotifyPlayback() { return sp }
            return appleMusic.sampleNow()
        #if targetEnvironment(simulator)
        case .demo:
            return demoSource.sampleNow()
        #endif
        }
    }

    /// Poll Spotify at most every `spotifyPollInterval`; extrapolate from the anchor between
    /// polls to respect the API's rate limits.
    private func spotifyPlayback() async -> PlaybackState? {
        guard spotify.isLoggedIn else { return nil }
        let now = Date()
        if let last = lastSpotifyPoll, now.timeIntervalSince(last) < Self.spotifyPollInterval {
            return spotifyAnchor
        }
        lastSpotifyPoll = now
        do {
            let state = try await spotify.poll()
            spotifyAnchor = state
            return state
        } catch SpotifyClient.SpotifyError.notPlaying {
            spotifyAnchor = nil
            return nil
        } catch SpotifyClient.SpotifyError.unauthorized {
            // Login is gone (the controller already dropped it) — stop replaying the last song.
            spotifyAnchor = nil
            return nil
        } catch SpotifyClient.SpotifyError.rateLimited(let retry) {
            // Back off: skip polling until Retry-After elapses.
            lastSpotifyPoll = now.addingTimeInterval(TimeInterval(retry))
            return spotifyAnchor
        } catch {
            return spotifyAnchor // network blip: keep extrapolating the last anchor
        }
    }

    // MARK: Lyrics

    /// Load lyrics for a newly-detected song. Cached lyrics resolve synchronously (instant); a
    /// network lookup runs in a separate task so it never blocks the 1s tick loop — the
    /// current song's activity keeps advancing while the next song's lyrics download.
    /// Order: the song's own service (Apple Music's word-timed lyrics / Spotify's), then LRCLIB.
    private func loadLyrics(for track: NowPlayingTrack) {
        // New token FIRST, so a still-running fetch for the previous song can't land on this one
        // (it used to overwrite a cached song's lyrics when you skipped quickly).
        let token = UUID()
        lyricsFetchToken = token
        lyricsRetryAt = nil
        currentLineIndex = nil
        let cached = store.load(for: track)
        if let cached {
            // The cache keeps the original script; romanize on load so converter fixes apply.
            lyrics = Transliterator.romanized(cached)
            status = cached.isSynced ? "Synced lyrics (cached)" : "Plain lyrics (cached)"
            // A cached LRCLIB copy is upgraded once, in the background, when the service can do better.
            guard service(for: track, cached: cached) != nil else { return }
        } else {
            status = "Fetching lyrics…"
            lyrics = nil
        }
        Task { [weak self] in await self?.fetchLyrics(for: track, token: token, cached: cached) }
    }

    /// The service whose own lyrics to ask for ("apple" / "spotify"), or nil: not set up, no ID
    /// (local files), or the cache already holds a service's lyrics or knows this one has none.
    private func service(for track: NowPlayingTrack, cached: TimedLyrics?) -> String? {
        guard let id = track.catalogID, !id.isEmpty else { return nil }
        let name: String
        switch track.source {
        case .appleMusic:
            guard appleAccount.enabled else { return nil }
            name = "apple"
        case .spotify:
            guard spotifyLyrics.isConnected else { return nil }
            name = "spotify"
        }
        if let source = cached?.source,
           source.hasPrefix("apple") || source.hasPrefix("spotify") || source.contains(" \(name)=none") { return nil }
        return name
    }

    private func fetchLyrics(for track: NowPlayingTrack, token: UUID, cached: TimedLyrics?) async {
        var missed: String? // the service said it has no lyrics: remember, so it isn't asked again
        if let name = service(for: track, cached: cached), let id = track.catalogID {
            do {
                let fetched = name == "apple" ? try await appleAccount.lyrics(songID: id)
                                              : try await spotifyLyrics.lyrics(trackID: id)
                guard lyricsFetchToken == token else { return }
                show(fetched, for: track)
                return
            } catch {
                let none = (error as? AppleMusicLyrics.Failure) == .notFound || (error as? SpotifyLyrics.Failure) == .notFound
                EventLog.log("lyrics \"\(track.title)\" \(name) \(none ? "has none" : "failed: \(error)")")
                guard lyricsFetchToken == token else { return }
                if none { missed = name }
                if var cached {
                    if let missed { cached.source = (cached.source ?? "lrclib") + " \(missed)=none"; store.save(cached, for: track) }
                    return // keep showing the cached copy
                }
            }
        }
        do {
            var fetched = try await lrclib.lyrics(for: track)
            guard lyricsFetchToken == token else { return } // superseded by a newer song
            if let missed { fetched.source = (fetched.source ?? "lrclib") + " \(missed)=none" }
            show(fetched, for: track)
        } catch let LRCLibClient.LRCLibError.badResponse(code) {
            guard lyricsFetchToken == token else { return }
            lyrics = nil
            status = "Lyrics HTTP error \(code), retrying"
            lyricsRetryAt = Date().addingTimeInterval(Self.lyricsRetryDelay)
        } catch is LRCLibClient.LRCLibError {
            guard lyricsFetchToken == token else { return }
            lyrics = nil
            status = "No lyrics found"
        } catch {
            guard lyricsFetchToken == token else { return }
            lyrics = nil
            status = "Lyrics fetch failed: \((error as NSError).localizedDescription), retrying"
            lyricsRetryAt = Date().addingTimeInterval(Self.lyricsRetryDelay)
        }
    }

    private func show(_ fetched: TimedLyrics, for track: NowPlayingTrack) {
        let display = Transliterator.romanized(fetched)
        EventLog.log("lyrics \"\(track.title)\" \(fetched.source ?? "?") lines=\(fetched.lines.count) synced=\(fetched.isSynced) words=\(fetched.lines.contains { $0.words != nil }) offset=\(fetched.offsetMs)ms")
        lyrics = display
        store.save(fetched, for: track) // original script, so romanizer fixes reach cached songs
        status = display.isSynced ? "Synced lyrics" : "Plain lyrics (no timing)"
    }

    // MARK: Sync + Live Activity

    private func updateSync(positionMs: Int, playback: PlaybackState) async {
        guard let lyrics, lyrics.isSynced else {
            // No synced lyrics yet (still fetching) or none exist. Keep the ONE activity alive and
            // just retitle it to this song — don't end it. Ending + re-requesting can't restart a
            // Live Activity from the background, which is what made song changes drop the widget.
            if currentLineIndex != nil { currentLineIndex = nil }
            let state = activityState(playback, positionMs: positionMs, current: "", next: nil)
            refreshLineDates()
            publishWidgetFeed()
            await liveActivity.ensureActivity(songId: playback.track.identityKey, initial: state)
            await liveActivity.update(state)
            return
        }
        let idx = engine.currentIndex(in: lyrics, positionMs: positionMs)
        if idx != currentLineIndex { currentLineIndex = idx }

        let current = idx.map { lyrics.lines[$0].text } ?? ""
        let next: String? = {
            if let idx, idx + 1 < lyrics.lines.count { return lyrics.lines[idx + 1].text }
            if idx == nil { return lyrics.lines.first?.text } // pre-song: show first line as upcoming
            return nil
        }()

        var state = activityState(playback, positionMs: positionMs, current: current, next: next)
        refreshLineDates()
        if let start = state.songStart, lineTransition != .morph { // morph needs a push per line
            // Playing: hand iOS the upcoming lines with start times and let its clock switch them.
            // The state then changes once per window, not once per line (2026-11-14 drive: per-line
            // pushes reached the CarPlay widget only every 10–30s).
            state.currentLine = ""
            state.nextLine = nil
            state.lines = Self.lyricWindow(lyrics, index: idx, songStart: start, userOffsetMs: engine.userOffsetMs)
            // ActivityKit drops content over 4KB; long romanized lines can get there.
            while (state.lines?.count ?? 0) > 1, ((try? JSONEncoder().encode(state))?.count ?? 0) > 3_500 {
                state.lines?.removeLast()
            }
        }
        publishWidgetFeed()
        await liveActivity.ensureActivity(songId: playback.track.identityKey, initial: state)
        await liveActivity.update(state)
    }

    // MARK: CarPlay lyrics widget

    private var widgetFeed: WidgetFeed?
    private var widgetReload: Task<Void, Never>?

    /// Hands the lyrics widget the song (see WidgetFeed). iOS budgets widget reloads, so this
    /// reloads only when the feed changes, 2s after the last change: a song change, its lyrics
    /// landing and the anchor settling ~1s in then cost one reload, not three.
    private func publishWidgetFeed() {
        let feed = makeWidgetFeed()
        guard feed != widgetFeed else { return }
        widgetFeed = feed
        guard feed.save() else { return }
        widgetReload?.cancel()
        widgetReload = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetFeed.kind)
            EventLog.log("widget reload \"\(feed.title)\" lines=\(feed.lines.count) playing=\(feed.isPlaying)")
        }
    }

    private func makeWidgetFeed() -> WidgetFeed {
        guard let track else { return .idle }
        var feed = WidgetFeed(title: track.title, artist: track.artist, background: activityBackground,
                              isPlaying: lastPlayback?.isPlaying == true)
        if let lyrics, lyrics.isSynced {
            if let start = songStartAnchor, !lineDates.isEmpty {
                feed.lines = [.init(text: "", at: start)] + zip(lyrics.lines, lineDates).map { .init(text: $0.text, at: $1) }
            } else { // paused
                feed.currentLine = currentLineIndex.map { lyrics.lines[$0].text } ?? ""
                feed.nextLines = lyrics.lines.dropFirst((currentLineIndex ?? -1) + 1).prefix(2).map(\.text)
            }
        }
        return feed
    }

    /// The lines the widget switches on its own: from the start of the current block of 4, 12 long,
    /// so the window moves every 4 lines and a push that lands up to ~8 lines late is still right.
    /// Kept small because every line is a stack of timer masks drawn in every presentation: on the
    /// 2026-11-16 drive a 47-line window (24 + split parts) took the widget extension to 90% CPU for
    /// 18s (cpu_resource report) and iOS dismissed the activity 20s after it started.
    /// Line i shows at songStart + its time, shifted earlier by the LRC + user offsets (see SyncEngine).
    /// A leading "" (♪) covers the intro before the first line. Long lines go whole: the widget cuts
    /// them to fit its own width (LyricFit), so they never shrink.
    nonisolated static func lyricWindow(_ lyrics: TimedLyrics, index: Int?, songStart: Date, userOffsetMs: Int)
        -> [LyricsActivityAttributes.TimedLine] {
        let lines = lyrics.lines
        let from = (index ?? 0) / 4 * 4
        let shiftMs = Double(userOffsetMs + lyrics.offsetMs)
        let at = { (ms: Int) in songStart.addingTimeInterval((Double(ms) - shiftMs) / 1000) }
        var window: [LyricsActivityAttributes.TimedLine] = from == 0 ? [.init(text: "", at: songStart)] : []
        for i in from..<min(from + 12, lines.count) {
            window.append(.init(text: lines[i].text, at: at(lines[i].timeMs)))
        }
        return window
    }

    /// The pushed state, including the song clock. `songStart` is held steady across ticks so
    /// the widget's live timer never turns into a push per second (see `steadySongStart`).
    private func activityState(_ playback: PlaybackState, positionMs: Int, current: String, next: String?)
        -> LyricsActivityAttributes.ContentState {
        let duration = playback.track.durationMs
        var start: Date?
        if playback.isPlaying, duration != nil {
            let steady = Self.steadySongStart(previous: songStartAnchor,
                                              candidate: Date().addingTimeInterval(-Double(positionMs) / 1000))
            if let old = songStartAnchor, steady != old, !playback.track.isDifferentSong(from: anchorTrack) {
                EventLog.log("anchor moved \(Int(steady.timeIntervalSince(old) * 1000))ms")
            }
            start = steady
            songStartAnchor = steady
            anchorTrack = playback.track
        }
        return LyricsActivityAttributes.ContentState(
            title: playback.track.title,
            artist: playback.track.artist,
            currentLine: current,
            nextLine: next,
            isPlaying: playback.isPlaying,
            durationMs: duration,
            songStart: start,
            pausedPositionMs: !playback.isPlaying && duration != nil ? positionMs / 1000 * 1000 : nil,
            background: activityBackground,
            transition: lineTransition,
            showsProgress: carPlayProgress
        )
    }

    /// The widget background for the current setting. Album art falls back to the solid colour for
    /// sources without artwork here (Spotify).
    private var activityBackground: LyricsActivityAttributes.RGB? {
        switch lyricsBackground {
        case .solid: solidColor
        case .albumArt: albumColor ?? solidColor
        case .glass: nil
        }
    }

    /// Keep the previous song-start anchor unless the new estimate moved by more than 0.25s. Each
    /// tick's estimate jitters by a few ms; without a threshold every tick would re-push the Live
    /// Activity. It was 1.5s, but the clocked lyric window schedules every line from this anchor,
    /// so a stale first reading (Apple Music still buffering at song start) stuck for the whole song
    /// as a per-song delay of up to 1.5s. `anchor moved` lines in events.log show how often it corrects.
    nonisolated static func steadySongStart(previous: Date?, candidate: Date) -> Date {
        if let previous, abs(previous.timeIntervalSince(candidate)) < 0.25 { return previous }
        return candidate
    }

    private func clear() {
        lastPlayback = nil
        spotifyAnchor = nil
        track = nil
        artwork = nil
        artworkBackdrop = nil
        lyrics = nil
        currentLineIndex = nil
        lineDates = []
        status = "Nothing playing"
        publishWidgetFeed()
        let idle = idleState
        Task { await liveActivity.update(idle); refreshActivityDiagnostics() }
    }

    private var idleState: LyricsActivityAttributes.ContentState {
        LyricsActivityAttributes.ContentState(
            title: "Nothing playing",
            artist: "Car Lyrics",
            currentLine: "",
            nextLine: nil,
            isPlaying: false,
            background: activityBackground,
            transition: lineTransition,
            showsProgress: carPlayProgress
        )
    }

    /// Every 30s while the loop runs. A missing heartbeat in the log = the app wasn't ticking.
    private func heartbeatIfDue(_ now: Date) {
        guard now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = now
        let line = currentLineIndex.map { "\($0 + 1)/\(lyrics?.lines.count ?? 0)" } ?? "-"
        let loc = lastLocationUpdate.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "never"
        // Audio output delay iOS reports for the current route (CarPlay / Bluetooth / speaker).
        // Logged, not applied yet: unproven that it matches Apple Music's audible lag.
        let session = AVAudioSession.sharedInstance()
        let out = "\(session.currentRoute.outputs.first?.portType.rawValue ?? "-") lat=\(Int(session.outputLatency * 1000))ms"
        // Freeze triage (2026-11-16 drive: stuck 15 min on a song Apple Music reported as paused while
        // "other audio" played): what Apple Music claims vs whether anything is audible at all.
        let am = appleMusic.sampleNow().map { "\($0.isPlaying ? "playing" : "paused")@\($0.positionMs / 1000)s" } ?? "none"
        EventLog.log("hb \(Self.appState) mem=\(os_proc_available_memory() / 1_048_576)MBfree thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) mode=\(sourceMode.rawValue) song=\"\(track?.title ?? "-")\" line=\(line) act=[\(liveActivity.healthSummary)] pushes=\(liveActivity.updateAttempts) loc=\(loc) auth=\(keepAlive.authorizationLabel) carplay=\(isCarPlayConnected) out=\(out) sync=\(userOffsetMs)ms am=\(am) other=\(session.isOtherAudioPlaying)")
    }

    private func recordTickGap(_ gap: TimeInterval, at timestamp: Date) {
        EventLog.log("tick gap \(String(format: "%.1f", gap))s (loop was suspended or blocked)")
        tickGapEvents.append(TickGapEvent(timestamp: timestamp, gap: gap))
        tickGapEvents = Array(tickGapEvents.suffix(Self.maxStoredTickGaps))
        if let data = try? JSONEncoder().encode(tickGapEvents) {
            UserDefaults.standard.set(data, forKey: Self.tickGapsKey)
        }
    }

    /// Assign only on change: every @Published write redraws every view observing the coordinator.
    private func refreshActivityDiagnostics() {
        if activityUpdateAttempts != liveActivity.updateAttempts { activityUpdateAttempts = liveActivity.updateAttempts }
        if lastActivityUpdateAttempt != liveActivity.lastUpdateAttempt { lastActivityUpdateAttempt = liveActivity.lastUpdateAttempt }
        if activityHealth != liveActivity.healthSummary { activityHealth = liveActivity.healthSummary }
    }

    private func refreshLineDates() {
        var dates: [Date] = []
        if let start = songStartAnchor, let lyrics, lyrics.isSynced, lastPlayback?.isPlaying == true {
            let shiftMs = Double(engine.userOffsetMs + lyrics.offsetMs)
            dates = lyrics.lines.map { start.addingTimeInterval((Double($0.timeMs) - shiftMs) / 1000) }
        }
        if dates != lineDates { lineDates = dates }
    }

    /// Small, heavily blurred copy of the artwork, made once per song: drawing it is free, unlike a
    /// live full-screen SwiftUI blur.
    nonisolated static func backdrop(from image: UIImage?) -> UIImage? {
        guard let image, let input = CIImage(image: image) else { return nil }
        let small = input.transformed(by: CGAffineTransform(scaleX: 160 / input.extent.width, y: 160 / input.extent.height))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
        guard let cg = CIContext().createCGImage(blurred, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
