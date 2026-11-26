import Foundation
import AVFAudio
import CryptoKit
import notify
import WebKit
import CarLyricsCore

/// YouTube Music's song clock, built from what iOS lets an app see of another app's playback. Apple's
/// own entitlement guards MediaRemote's reads (tried on iOS 27.2, 2026-11-26: every read came back
/// empty), so instead:
/// - **When** playback changes: MediaRemote's Darwin notifications, to the millisecond, no data.
/// - **Which song**: the newest entry in YouTube Music's history, 1–20 s after the song starts.
/// - **Whether** anything plays: AVAudioSession's other-audio flag.
/// A new song is timed from the signal before it reached history, and pauses and resumes from their
/// signals. A drag inside YouTube Music shows up as an unexplained "playing changed" signal (or not
/// at all), never as a position. The position is then unknown until a lyric line is tapped (which
/// jumps the song there) or the next song starts.
struct YTMTimeline: Codable, Equatable {
    struct Song: Codable, Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var durationMs: Int?
        var artworkURL: String?
    }

    private(set) var song: Song?
    private(set) var playing = false
    /// Position 0 in wall time while playing; the position while paused. nil = unknown.
    private(set) var start: Date?
    private(set) var pausedMs: Int?
    /// The latest playback signal; `.distantPast` until one arrives after launch.
    private(set) var lastSignal = Date.distantPast
    /// When `song` became the song.
    private var acceptedAt = Date.distantPast
    /// Songs played just before this one. History flips back to them for up to ~25 s after a change
    /// (2026-11-26 tests), so returning to one needs a fresh signal (a "previous" tap sends one).
    private var recent: [String] = []
    /// A "playing changed" signal that a pause, a resume or a new song may still explain.
    private var suspect: Date?
    private var ownSeekAt = Date.distantPast
    /// The first history answer after launch may change the song without a signal.
    private var fresh = true

    var positionKnown: Bool { song != nil && (playing ? start != nil : pausedMs != nil) }

    func positionMs(at now: Date) -> Int? {
        playing ? start.map { Int(now.timeIntervalSince($0) * 1000) } : pausedMs
    }

    /// `playState`: MediaRemote's "is playing changed" (play, pause, skip, a drag that rebuffers);
    /// else "lock screen controls changed" (also every skip, and the next song starting on its own).
    mutating func signal(at t: Date, playState: Bool) {
        lastSignal = t
        if playState, t.timeIntervalSince(ownSeekAt) > 2 { suspect = t } // our own jump is no drag
    }

    mutating func setPlaying(_ now: Bool, at t: Date) {
        guard now != playing else { return }
        // A signal just before is the exact moment. None since launch: it happened while Car Lyrics
        // wasn't running, so the position is unknown.
        let seen = lastSignal != .distantPast
        let at = t.timeIntervalSince(lastSignal) < 3 ? lastSignal : t
        if now {
            start = seen ? pausedMs.map { at.addingTimeInterval(-Double($0) / 1000) } : nil
            pausedMs = nil
        } else {
            pausedMs = seen ? start.map { Int(at.timeIntervalSince($0) * 1000) } : nil
            start = nil
        }
        playing = now
        suspect = nil
    }

    /// The newest history entry. True when it became the song.
    mutating func history(_ top: Song, at now: Date) -> Bool {
        defer { fresh = false }
        guard top.id != song?.id else { return false }
        if !fresh, recent.contains(top.id), lastSignal <= acceptedAt { return false } // a flip back
        if let old = song?.id { recent = Array(([old] + recent.filter { $0 != top.id }).prefix(5)) }
        let timed = !fresh && now.timeIntervalSince(lastSignal) < 45
        song = top
        acceptedAt = now
        suspect = nil
        start = playing && timed ? lastSignal : nil
        pausedMs = nil
        return true
    }

    /// 4 s after an unexplained signal: the song was dragged or restarted, so its position is unknown.
    mutating func settle(at now: Date) {
        guard let s = suspect, now.timeIntervalSince(s) >= 4 else { return }
        suspect = nil
        start = nil
        pausedMs = nil
    }

    /// Car Lyrics jumped the song (a tapped line).
    mutating func seeked(toMs ms: Int, at now: Date) {
        ownSeekAt = now
        suspect = nil
        if playing { start = now.addingTimeInterval(-Double(ms) / 1000) } else { pausedMs = ms }
    }

    /// Stop Car Lyrics runs as CarPlay disconnects, which pauses the music too: keep where it stopped.
    mutating func stopped(at now: Date) {
        guard playing else { return }
        pausedMs = positionMs(at: now)
        start = nil
        playing = false
    }

    /// After a relaunch, nothing seen before it counts as a signal.
    mutating func relaunched() {
        fresh = true
        lastSignal = .distantPast
        acceptedAt = .distantPast
        suspect = nil
        ownSeekAt = .distantPast
    }
}

/// The YouTube Music source: signals, history polling, and jumping (MediaRemote's seek command reaches
/// the now-playing app without the entitlement). Needs the YouTube Music login (Settings) and history on.
@MainActor
final class YouTubeMusicSource: ObservableObject {
    static let shared = YouTubeMusicSource()

    @Published private(set) var isSignedIn = false
    /// False after a drag inside YouTube Music (or a song joined midway): the lyrics ask for a tap.
    @Published private(set) var positionKnown = true

    private var timeline: YTMTimeline {
        didSet { if timeline != oldValue { save() } }
    }
    private var observing = false
    private var polling = false
    private var lastPoll = Date.distantPast
    private var burstUntil = Date.distantPast
    private var lastError: String?

    private static let stateKey = "youtubeMusic.timeline"
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!
    private static let origin = "https://music.youtube.com"
    private static let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    private init() {
        var saved = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(YTMTimeline.self, from: $0) } ?? YTMTimeline()
        saved.relaunched()
        timeline = saved
        Task { await refreshSignIn() }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(timeline), forKey: Self.stateKey)
    }

    func refreshSignIn() async {
        isSignedIn = await Self.cookies().contains { $0.name == "SAPISID" }
    }

    func signOut() async {
        await WebCookies.clear(domain: "youtube.com")
        await WebCookies.clear(domain: "google.com")
        timeline = YTMTimeline()
        isSignedIn = false
    }

    /// MediaRemote posts these for every app's playback (names from iOS's MediaRemote binary).
    func start() {
        guard !observing else { return }
        observing = true
        for (name, playState) in [("com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange", true),
                                  ("com.apple.MediaRemote.lockScreenControlsDidChange", false)] {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { _ in
                MainActor.assumeIsolated { YouTubeMusicSource.shared.signal(playState: playState) }
            }
        }
    }

    private func signal(playState: Bool) {
        let now = Date()
        timeline.signal(at: now, playState: playState)
        burstUntil = now.addingTimeInterval(30) // a new song reaches history within seconds: look every second
        lastPoll = .distantPast
    }

    /// Read every tick while YouTube Music may be what's playing. Nil until a song is known.
    func sampleNow() -> PlaybackState? {
        guard isSignedIn else { return nil }
        let now = Date()
        timeline.setPlaying(AVAudioSession.sharedInstance().isOtherAudioPlaying, at: now)
        timeline.settle(at: now)
        let interval: TimeInterval = now < burstUntil ? 1 : 10
        if !polling, timeline.playing || now < burstUntil, now.timeIntervalSince(lastPoll) >= interval { poll() }
        if positionKnown != timeline.positionKnown { positionKnown = timeline.positionKnown }
        guard let song = timeline.song else { return nil }
        let track = NowPlayingTrack(title: song.title, artist: song.artist, album: song.album, durationMs: song.durationMs,
                                    source: .youtubeMusic, catalogID: song.id, artworkURL: song.artworkURL)
        return PlaybackState(track: track, positionMs: max(0, timeline.positionMs(at: now) ?? 0),
                             isPlaying: timeline.playing, sampledAt: now)
    }

    /// Jump YouTube Music to `ms` (MediaRemote's SeekToPlaybackPosition, command 24, which iOS hands to
    /// the now-playing app). The song's clock is then known again.
    func seek(toMs ms: Int) {
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        guard let mr = Self.mediaRemote, let fn = dlsym(mr, "MRMediaRemoteSendCommand"),
              let key = dlsym(mr, "kMRMediaRemoteOptionPlaybackPosition")?.assumingMemoryBound(to: CFString.self).pointee else {
            EventLog.log("youtube music seek: MediaRemote missing")
            return
        }
        let sent = unsafeBitCast(fn, to: Send.self)(24, [key: Double(max(0, ms)) / 1000] as CFDictionary)
        timeline.seeked(toMs: ms, at: Date())
        positionKnown = timeline.positionKnown
        EventLog.log("youtube music seek to \(ms / 1000)s sent=\(sent)")
    }

    func stopped() { timeline.stopped(at: Date()) }

    private func poll() {
        polling = true
        lastPoll = Date()
        Task {
            defer { polling = false }
            do {
                guard let top = try await Self.historyTop() else { return }
                if timeline.history(top, at: Date()) {
                    EventLog.log("youtube music song \"\(top.title)\" \(timeline.positionKnown ? "timed from its start signal" : "position unknown")")
                }
                lastError = nil
            } catch {
                let text = "\(error)"
                if text != lastError { lastError = text; EventLog.log("youtube music history failed: \(text)") }
                if (error as? HistoryError) == .signedOut { isSignedIn = false }
            }
        }
    }

    // MARK: History

    enum HistoryError: Error, Equatable { case signedOut, http(Int) }

    private static func cookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    /// The newest song in YouTube Music's history, the way music.youtube.com asks for it (InnerTube
    /// `FEmusic_history`, signed with the login's SAPISID cookie).
    private static func historyTop() async throws -> YTMTimeline.Song? {
        let jar = await cookies()
        guard let sapisid = (jar.first { $0.name == "__Secure-3PAPISID" } ?? jar.first { $0.name == "SAPISID" })?.value else {
            throw HistoryError.signedOut
        }
        let ts = Int(Date().timeIntervalSince1970)
        let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        var r = URLRequest(url: URL(string: "\(origin)/youtubei/v1/browse?prettyPrint=false")!, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.httpShouldHandleCookies = false
        r.setValue("SAPISIDHASH \(ts)_\(hash)", forHTTPHeaderField: "Authorization")
        r.setValue(jar.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(origin, forHTTPHeaderField: "Origin")
        r.setValue(origin, forHTTPHeaderField: "X-Origin")
        r.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        r.setValue(SignInWebView.safariUserAgent, forHTTPHeaderField: "User-Agent")
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = .gmt
        let version = "1.\(f.string(from: Date().addingTimeInterval(-86_400))).01.00" // the web client's own scheme
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "browseId": "FEmusic_history",
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en"]],
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: r)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return song(fromHistory: try JSONSerialization.jsonObject(with: data))
        case 401, 403: throw HistoryError.signedOut
        case let status: throw HistoryError.http(status)
        }
    }

    /// The first list item: title (column 1), linked artists (column 2), album (column 3), length,
    /// video ID and the largest thumbnail.
    nonisolated static func song(fromHistory json: Any) -> YTMTimeline.Song? {
        guard let item = first("musicResponsiveListItemRenderer", in: json) else { return nil }
        let columns: [[[String: Any]]] = (item["flexColumns"] as? [[String: Any]] ?? []).map { column in
            let text = (column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any]
            return text?["runs"] as? [[String: Any]] ?? []
        }
        let texts = { (runs: [[String: Any]]) in runs.compactMap { $0["text"] as? String } }
        guard let title = columns.first.map({ texts($0).joined() }), !title.isEmpty,
              let id = ((item["playlistItemData"] as? [String: Any])?["videoId"] as? String) ?? (first("watchEndpoint", in: item)?["videoId"] as? String)
        else { return nil }
        let byline = columns.count > 1 ? columns[1] : []
        let linked = byline.filter { $0["navigationEndpoint"] != nil }
        let artist = texts(linked.isEmpty ? Array(byline.prefix(1)) : linked).joined(separator: ", ")
        let album = columns.count > 2 ? texts(columns[2]).joined() : nil
        let fixed = (item["fixedColumns"] as? [[String: Any]])?.first
            .flatMap { (($0["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] }
            .map { texts($0).joined() }
        let art = (first("musicThumbnailRenderer", in: item)?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let artURL = (art?.last?["url"] as? String)?
            .replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w544-h544", options: .regularExpression)
        return .init(id: id, title: title, artist: artist, album: album?.isEmpty == false ? album : nil,
                     durationMs: fixed.flatMap(durationMs), artworkURL: artURL)
    }

    /// "3:30" / "1:02:03" in milliseconds.
    nonisolated static func durationMs(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.count == text.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 } * 1000
    }

    /// Depth-first, arrays in order.
    nonisolated private static func first(_ key: String, in node: Any) -> [String: Any]? {
        if let d = node as? [String: Any] {
            if let hit = d[key] as? [String: Any] { return hit }
            for v in d.values { if let hit = first(key, in: v) { return hit } }
        } else if let a = node as? [Any] {
            for v in a { if let hit = first(key, in: v) { return hit } }
        }
        return nil
    }
}
