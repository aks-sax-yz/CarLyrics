import Foundation

/// Client for LRCLIB (https://lrclib.net) — free, no-API-key synced-lyrics database.
/// LRCLIB asks clients to send an identifying User-Agent; we comply.
public struct LRCLibClient: Sendable {
    public struct Response: Codable, Sendable {
        public var id: Int?
        public var trackName: String?
        public var artistName: String?
        public var albumName: String?
        public var duration: Double?
        public var instrumental: Bool?
        public var plainLyrics: String?
        public var syncedLyrics: String?
    }

    public enum LRCLibError: Error, Equatable {
        case notFound
        case badResponse(status: Int)
        case emptyLyrics
    }

    let baseURL: URL
    let userAgent: String
    let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        userAgent: String = "CarLyrics/1.0 (https://github.com/aks-sax-yz/CarLyrics)",
        session: URLSession = LRCLibClient.defaultSession
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.session = session
    }

    /// Short per-request timeout so a stalled lookup fails fast to the search fallback instead
    /// of hanging on URLSession's 60s default (the "lyrics show up half the song later" bug).
    /// `waitsForConnectivity` rides out a tunnel; the resource cap makes it eventually fail so the
    /// coordinator's retry can take over (the default cap is 7 days).
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Exact lookup. Best hit rate — pass album + duration when known.
    /// `durationMs` is rounded to whole seconds as LRCLIB expects.
    public func get(track: String, artist: String, album: String? = nil, durationMs: Int? = nil) async throws -> TimedLyrics {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let durationMs { items.append(URLQueryItem(name: "duration", value: String(durationMs / 1000))) }
        comps.queryItems = items

        let response = try await fetch(url: comps.url!)
        var lyrics = try toLyrics(response)
        lyrics.source = "get id=\(response.id.map(String.init) ?? "?")"
        return lyrics
    }

    /// Fuzzy search fallback when exact `get` misses. Picks the best result (see `bestMatch`).
    public func search(track: String, artist: String, durationMs: Int? = nil, preferLatin: Bool = false) async throws -> TimedLyrics {
        let results = try await searchResults(track: track, artist: artist)
        guard let best = Self.bestMatch(results, durationMs: durationMs, preferLatin: preferLatin) else { throw LRCLibError.notFound }
        var lyrics = try toLyrics(best)
        lyrics.source = "search id=\(best.id.map(String.init) ?? "?")"
        return lyrics
    }

    /// Every upload LRCLIB has for the track (popular songs have 10–20, timed by different people).
    func searchResults(track: String, artist: String) async throws -> [Response] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LRCLibError.badResponse(status: -1) }
        guard http.statusCode == 200 else { throw LRCLibError.badResponse(status: http.statusCode) }
        return try JSONDecoder().decode([Response].self, from: data)
    }

    /// LRCLIB's uploads of one song are timed by different people and spread by -220…+1060ms on
    /// popular songs (2026-11-16, 7 songs × 13–20 uploads), which is why each song needed its own
    /// Sync. Returns what to add to `chosen.offsetMs` (positive = sooner) to move it to the median
    /// timing of the synced uploads within 2s of the track's length. Each upload's shift is the
    /// median gap over lines with identical text; shifts over 2s are a different cut and ignored.
    /// Needs 3+ comparable uploads, else 0. ponytail: majority timing, not ground truth.
    static func consensusOffsetMs(_ chosen: TimedLyrics, versions: [Response], durationMs: Int?) -> Int {
        let shifts = versions.compactMap { r -> Int? in
            guard let synced = r.syncedLyrics, !synced.isEmpty else { return nil }
            if let durationMs, let d = r.duration, abs(d - Double(durationMs) / 1000) > 2 { return nil }
            return lineShiftMs(from: chosen, to: LRCParser.parse(synced))
        }.filter { abs($0) <= 2_000 }
        guard shifts.count >= 3 else { return 0 }
        return -median(shifts) // uploads are later than ours by +m ms → show ours m ms later
    }

    /// Median of `to - from` effective line times over lines with the same text, matched in order;
    /// nil with fewer than 5 matches (different language/script, or too little in common).
    static func lineShiftMs(from a: TimedLyrics, to b: TimedLyrics) -> Int? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var diffs: [Int] = []
        var j = 0
        for line in a.lines where !key(line.text).isEmpty {
            guard let k = b.lines[j...].firstIndex(where: { key($0.text) == key(line.text) }) else { continue }
            diffs.append((b.lines[k].timeMs - b.offsetMs) - (line.timeMs - a.offsetMs))
            j = k + 1
            if j == b.lines.count { break }
        }
        return diffs.count >= 5 ? median(diffs) : nil
    }

    static func median(_ xs: [Int]) -> Int {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Synced beats plain (plain can't drive the Live Activity), then closest duration (a live or
    /// remix cut has different timings). With `preferLatin`, a version already typed in Latin
    /// script within 2s of the track's length wins over a closer one we'd have to romanize. Ties
    /// keep LRCLIB's order.
    static func bestMatch(_ results: [Response], durationMs: Int?, preferLatin: Bool = false) -> Response? {
        func rank(_ r: Response) -> (Int, Int, Double) {
            let synced = r.syncedLyrics?.isEmpty == false ? 0 : 1
            let diff = durationMs.flatMap { ms in r.duration.map { abs($0 - Double(ms) / 1000) } } ?? 0
            let latin = preferLatin && diff <= 2
                && !Transliterator.needsRomanization(r.syncedLyrics ?? r.plainLyrics ?? "") ? 0 : 1
            return (synced, latin, diff)
        }
        return results
            .filter { $0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false }
            .min { rank($0) < rank($1) }
    }

    /// Exact get (with search as the fallback), prefer a hand-typed Latin upload over one we'd
    /// romanize, then shift to the uploads' consensus timing. The path the app actually calls.
    public func lyrics(for track: NowPlayingTrack) async throws -> TimedLyrics {
        // Album deliberately omitted: Apple Music appends "- Single"/"(Deluxe)" etc., so an exact
        // album match nearly always 404s. Track + artist + duration is LRCLIB's effective signature.
        async let exactLookup = try? get(track: track.title, artist: track.artist, durationMs: track.durationMs)
        async let searchLookup = try? searchResults(track: track.title, artist: track.artist)
        let results = await searchLookup ?? []
        let latinBest = Self.bestMatch(results, durationMs: track.durationMs, preferLatin: true)

        var lyrics: TimedLyrics
        if let exact = await exactLookup {
            lyrics = exact
            // LRCLIB's exact pick is often in Devanagari (or another script) while someone has also
            // uploaded it hand-typed in Latin script. A person's Hinglish beats ours.
            if exact.lines.contains(where: { Transliterator.needsRomanization($0.text) }),
               let latinBest, let latin = try? toLyrics(latinBest), latin.isSynced || !exact.isSynced,
               !latin.lines.contains(where: { Transliterator.needsRomanization($0.text) }) {
                lyrics = latin
                lyrics.source = "hand-typed id=\(latinBest.id.map(String.init) ?? "?")"
            }
        } else {
            guard let latinBest else { throw LRCLibError.notFound }
            lyrics = try toLyrics(latinBest)
            lyrics.source = "search id=\(latinBest.id.map(String.init) ?? "?")"
        }
        if lyrics.isSynced {
            let shift = Self.consensusOffsetMs(lyrics, versions: results, durationMs: track.durationMs)
            lyrics.offsetMs += shift
            lyrics.source = "\(lyrics.source ?? "?") uploads=\(results.count) consensus=\(shift)ms"
        }
        return lyrics
    }

    // MARK: - Internals

    private func fetch(url: URL) async throws -> Response {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LRCLibError.badResponse(status: -1) }
        if http.statusCode == 404 { throw LRCLibError.notFound }
        guard http.statusCode == 200 else { throw LRCLibError.badResponse(status: http.statusCode) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// Prefer synced lyrics; fall back to plain. Exposed for testing the decode→parse seam.
    public func toLyrics(_ r: Response) throws -> TimedLyrics {
        if let synced = r.syncedLyrics, !synced.isEmpty {
            return LRCParser.parse(synced)
        }
        if let plain = r.plainLyrics, !plain.isEmpty {
            return LRCParser.parsePlain(plain)
        }
        throw LRCLibError.emptyLyrics
    }
}
