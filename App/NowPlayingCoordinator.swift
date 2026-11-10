import Foundation
import AVFAudio
import SwiftUI
import CarLyricsCore

/// The brain: samples the active source, fetches + caches lyrics on song change, runs the
/// SyncEngine every tick, publishes state for the in-app UI, and pushes the Live Activity
/// that renders on CarPlay.
@MainActor
final class NowPlayingCoordinator: ObservableObject {
    enum SourceMode: String, CaseIterable, Identifiable {
        case auto, appleMusic, spotify, shazam
        #if targetEnvironment(simulator)
        case demo
        #endif
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .appleMusic: "Apple Music"
            case .spotify: "Spotify"
            case .shazam: "Listen"
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
            // Auto may have implicitly turned on the mic — drop that when leaving Auto.
            if oldValue == .auto { setAutoListening(false) }
            // Shazam holds the mic open — only listen while its mode is actually selected.
            // (The keep-alive is location-based and runs independently, so no handoff needed.)
            if sourceMode == .shazam {
                shazamSource.start()
                status = "Listening…"
            } else if oldValue == .shazam {
                shazamSource.stop()
            }
        }
    }
    @Published private(set) var track: NowPlayingTrack?
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
    @Published private(set) var lastLocationUpdate: Date?
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
    @Published var userOffsetMs: Int {
        didSet {
            UserDefaults.standard.set(userOffsetMs, forKey: Self.offsetKey)
            engine.userOffsetMs = userOffsetMs
        }
    }

    let appleMusic = AppleMusicSource()
    let spotify = SpotifyController()
    let shazamSource = ShazamSource()
    private let keepAlive = BackgroundKeepAlive()
    /// In Auto mode, whether we've implicitly fallen back to the mic (an undetectable app
    /// like YouTube Music is playing). Distinct from the user picking `.shazam` outright.
    private var autoListening = false
    #if targetEnvironment(simulator)
    private let demoSource = DemoSource()
    #endif

    private let lrclib = LRCLibClient()
    private let store = LyricsStore.caches()
    private let liveActivity = LiveActivityController()
    private var engine = SyncEngine()

    private var lastPlayback: PlaybackState?
    /// Consecutive ticks with nothing playing. Debounces `clear()` so a 1-2s track-change gap
    /// (Apple Music briefly reports no item between songs) doesn't tear down the Live Activity.
    private var missCount = 0
    private var lastSpotifyPoll: Date?
    private var spotifyAnchor: PlaybackState?
    private var loopTask: Task<Void, Never>?
    private var lyricsFetchToken = UUID()
    /// Set after a network/HTTP failure so the current song's lyrics are retried, not given up on.
    private var lyricsRetryAt: Date?
    private var wasInBackground = false
    private var lastHeartbeat = Date.distantPast
    private var songStartAnchor: Date?

    private static let offsetKey = "sync.userOffsetMs"
    private static let tickGapsKey = "diagnostics.tickGaps"
    private static let carPlayKey = "diagnostics.carPlayConnected"
    private static let spotifyPollInterval: TimeInterval = 3
    private static let significantTickGap: TimeInterval = 3
    private static let maxStoredTickGaps = 8
    private static let lyricsRetryDelay: TimeInterval = 15
    private static let heartbeatInterval: TimeInterval = 30

    init() {
        userOffsetMs = UserDefaults.standard.integer(forKey: Self.offsetKey)
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
        keepAlive.start() // location keep-alive runs in every mode, independent of the mic
        handleCarPlayRouteChange()
        guard loopTask == nil else { return }
        EventLog.log("app start mode=\(sourceMode.rawValue) carplay=\(isCarPlayConnected)")
        // Observer only once — start() can re-run from SwiftUI onAppear without meaning "restart".
        // Block observer on the main queue: AVAudioSession can post route changes off the main
        // thread, and a selector into this @MainActor class would trip Swift 6's isolation check.
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleCarPlayRouteChange() }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Becoming active swaps in a fresh Live Activity if the current one is a leftover or has
    /// been through the background — so a frozen widget recovers just by opening the app (no
    /// clearing it, no force-quit). See `LiveActivityController.restart()`.
    func scenePhaseChanged(_ phase: ScenePhase) {
        EventLog.log("phase \(phase)")
        switch phase {
        case .active:
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
        if keepAliveNow != keepAliveStatus { EventLog.log("keep-alive \(keepAliveNow)") }
        keepAliveStatus = keepAliveNow
        lastLocationUpdate = keepAlive.lastLocationUpdate
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
            EventLog.log("song \"\(playback.track.title)\" — \(playback.track.artist) [\(playback.track.source.rawValue)]")
            loadLyrics(for: playback.track) // non-blocking: fetch runs async, loop keeps ticking
        } else if let retryAt = lyricsRetryAt, now >= retryAt {
            loadLyrics(for: playback.track)
        }
        lastPlayback = playback

        let posNow = playback.extrapolatedPositionMs(now: Date())
        await updateSync(positionMs: posNow, playback: playback)
    }

    /// Toggle Auto's implicit mic fallback — start/stop only the mic; the location keep-alive
    /// runs independently and needs no handoff.
    private func setAutoListening(_ on: Bool) {
        guard on != autoListening else { return }
        autoListening = on
        if on {
            shazamSource.start()
            status = "Listening…"
        } else {
            shazamSource.stop()
        }
    }

    /// Choose the source to read this tick.
    private func resolvePlayback() async -> PlaybackState? {
        switch sourceMode {
        case .appleMusic:
            return appleMusic.sampleNow()
        case .spotify:
            return await spotifyPlayback()
        case .shazam:
            return shazamSource.sampleNow()
        case .auto:
            // Local Apple Music read is cheap; prefer it when actually playing.
            if let am = appleMusic.sampleNow(), am.isPlaying { setAutoListening(false); return am }
            if spotify.isLoggedIn, let sp = await spotifyPlayback() { setAutoListening(false); return sp }
            // No API source. Fall back to the mic when another app (YouTube Music, radio…) is
            // audibly playing. Hysteresis: once listening, stay until the mic goes cold AND
            // nothing is audible, so we don't flap between ticks.
            if autoListening {
                if let s = shazamSource.sampleNow() { return s }          // recent match → keep syncing
                if AVAudioSession.sharedInstance().isOtherAudioPlaying { return nil } // audible, no match yet
                setAutoListening(false)                                   // truly silent → stop
                return nil
            }
            if AVAudioSession.sharedInstance().isOtherAudioPlaying {
                setAutoListening(true)
                return shazamSource.sampleNow()
            }
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
    private func loadLyrics(for track: NowPlayingTrack) {
        // New token FIRST, so a still-running fetch for the previous song can't land on this one
        // (it used to overwrite a cached song's lyrics when you skipped quickly).
        let token = UUID()
        lyricsFetchToken = token
        lyricsRetryAt = nil
        currentLineIndex = nil
        if let cached = store.load(for: track) {
            // Romanize on load too, so caches saved before this feature still show Hinglish.
            lyrics = Transliterator.romanized(cached)
            status = cached.isSynced ? "Synced lyrics (cached)" : "Plain lyrics (cached)"
            return
        }
        status = "Fetching lyrics…"
        lyrics = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await lrclib.lyrics(for: track)
                guard lyricsFetchToken == token else { return } // superseded by a newer song
                let display = Transliterator.romanized(fetched)
                lyrics = display
                store.save(display, for: track) // cache the romanized form
                status = display.isSynced ? "Synced lyrics" : "Plain lyrics (no timing)"
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
    }

    // MARK: Sync + Live Activity

    private func updateSync(positionMs: Int, playback: PlaybackState) async {
        guard let lyrics, lyrics.isSynced else {
            // No synced lyrics yet (still fetching) or none exist. Keep the ONE activity alive and
            // just retitle it to this song — don't end it. Ending + re-requesting can't restart a
            // Live Activity from the background, which is what made song changes drop the widget.
            currentLineIndex = nil
            let state = activityState(playback, positionMs: positionMs, current: "", next: nil)
            await liveActivity.ensureActivity(songId: playback.track.identityKey, initial: state)
            await liveActivity.update(state)
            return
        }
        let idx = engine.currentIndex(in: lyrics, positionMs: positionMs)
        currentLineIndex = idx

        let current = idx.map { lyrics.lines[$0].text } ?? ""
        let next: String? = {
            if let idx, idx + 1 < lyrics.lines.count { return lyrics.lines[idx + 1].text }
            if idx == nil { return lyrics.lines.first?.text } // pre-song: show first line as upcoming
            return nil
        }()

        let state = activityState(playback, positionMs: positionMs, current: current, next: next)
        await liveActivity.ensureActivity(songId: playback.track.identityKey, initial: state)
        await liveActivity.update(state)
    }

    /// The pushed state, including the song clock. `songStart` is held steady across ticks so
    /// the widget's live timer never turns into a push per second (see `steadySongStart`).
    private func activityState(_ playback: PlaybackState, positionMs: Int, current: String, next: String?)
        -> LyricsActivityAttributes.ContentState {
        let duration = playback.track.durationMs
        var start: Date?
        if playback.isPlaying, duration != nil {
            start = Self.steadySongStart(previous: songStartAnchor,
                                         candidate: Date().addingTimeInterval(-Double(positionMs) / 1000))
            songStartAnchor = start
        }
        return LyricsActivityAttributes.ContentState(
            title: playback.track.title,
            artist: playback.track.artist,
            currentLine: current,
            nextLine: next,
            isPlaying: playback.isPlaying,
            durationMs: duration,
            songStart: start,
            pausedPositionMs: !playback.isPlaying && duration != nil ? positionMs / 1000 * 1000 : nil
        )
    }

    /// Keep the previous song-start anchor unless the new estimate moved by more than 1.5s (a
    /// seek, a new song, a resume). Each tick's estimate jitters by a few ms; without this every
    /// tick would differ from the last push and re-push the Live Activity.
    nonisolated static func steadySongStart(previous: Date?, candidate: Date) -> Date {
        if let previous, abs(previous.timeIntervalSince(candidate)) < 1.5 { return previous }
        return candidate
    }

    private func clear() {
        lastPlayback = nil
        spotifyAnchor = nil
        track = nil
        lyrics = nil
        currentLineIndex = nil
        status = "Nothing playing"
        let idle = LyricsActivityAttributes.ContentState(
            title: "Nothing playing",
            artist: "Car Lyrics",
            currentLine: "",
            nextLine: nil,
            isPlaying: false
        )
        Task { await liveActivity.update(idle); refreshActivityDiagnostics() }
    }

    /// Every 30s while the loop runs. A missing heartbeat in the log = the app wasn't ticking.
    private func heartbeatIfDue(_ now: Date) {
        guard now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = now
        let line = currentLineIndex.map { "\($0 + 1)/\(lyrics?.lines.count ?? 0)" } ?? "-"
        let loc = lastLocationUpdate.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "never"
        EventLog.log("hb \(wasInBackground ? "bg" : "fg") mode=\(sourceMode.rawValue) song=\"\(track?.title ?? "-")\" line=\(line) act=[\(liveActivity.healthSummary)] pushes=\(liveActivity.updateAttempts) loc=\(loc) carplay=\(isCarPlayConnected)")
    }

    private func recordTickGap(_ gap: TimeInterval, at timestamp: Date) {
        EventLog.log("tick gap \(String(format: "%.1f", gap))s (loop was suspended or blocked)")
        tickGapEvents.append(TickGapEvent(timestamp: timestamp, gap: gap))
        tickGapEvents = Array(tickGapEvents.suffix(Self.maxStoredTickGaps))
        if let data = try? JSONEncoder().encode(tickGapEvents) {
            UserDefaults.standard.set(data, forKey: Self.tickGapsKey)
        }
    }

    private func refreshActivityDiagnostics() {
        activityUpdateAttempts = liveActivity.updateAttempts
        lastActivityUpdateAttempt = liveActivity.lastUpdateAttempt
        activityHealth = liveActivity.healthSummary
    }
}
