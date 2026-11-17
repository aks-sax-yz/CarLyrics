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

    /// LRCLIB's uploads of one song are timed by different people. On popular songs they disagree by
    /// -220…+1060ms overall and, line by line, the upload LRCLIB picks strays 250–880ms from the rest
    /// at p90 (2026-11-17, 10 songs × 13–20 uploads). So each line takes the median of its own time
    /// across the comparable uploads: synced, within 2s of the track's length, sharing 5+ lines,
    /// overall shift under 2s (more is a different cut). A line's match in an upload is the same text
    /// nearest to where that upload's overall shift puts it (±1.5s), so repeated chorus lines don't
    /// cross-match; each upload line is used once, in order. Lines with fewer than 3 votes take the
    /// overall median shift. A line never lands on or before the previous one: it keeps at least its
    /// original gap (up to 250ms), so two different lines can't end up with the same time.
    /// Needs 3+ comparable uploads; returns the lyrics unchanged and shift 0 otherwise.
    /// ponytail: majority timing, not ground truth. Copies of one upload count as separate votes.
    static func consensusTimed(_ chosen: TimedLyrics, versions: [Response], durationMs: Int?) -> (lyrics: TimedLyrics, shiftMs: Int) {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let uploads: [(lines: [(key: String, ms: Int)], shift: Int)] = versions.compactMap { r in
            guard let synced = r.syncedLyrics, !synced.isEmpty else { return nil }
            if let durationMs, let d = r.duration, abs(d - Double(durationMs) / 1000) > 2 { return nil }
            let u = LRCParser.parse(synced)
            guard let shift = lineShiftMs(from: chosen, to: u), abs(shift) <= 2_000 else { return nil }
            return (u.lines.map { (key($0.text), $0.timeMs - u.offsetMs) }, shift)
        }
        guard uploads.count >= 3 else { return (chosen, 0) }
        let overall = median(uploads.map(\.shift))
        var out = chosen
        var previous: Int?
        var used = Array(repeating: -1, count: uploads.count) // last line taken from each upload
        for i in out.lines.indices {
            let mine = chosen.lines[i].timeMs - chosen.offsetMs
            let k = key(chosen.lines[i].text)
            var votes: [Int] = []
            if !k.isEmpty {
                for (u, upload) in uploads.enumerated() {
                    // In order and never reused, so a repeated line can't borrow its twin's time.
                    let target = mine + upload.shift
                    let candidates = upload.lines.indices.filter { $0 > used[u] && upload.lines[$0].key == k }
                    if let j = candidates.min(by: { abs(upload.lines[$0].ms - target) < abs(upload.lines[$1].ms - target) }),
                       abs(upload.lines[j].ms - target) <= 1_500 {
                        votes.append(upload.lines[j].ms)
                        used[u] = j
                    }
                }
            }
            var t = votes.count >= 3 ? median(votes) : mine + overall
            if let previous {
                // Never on top of (or before) the previous line: keep at least this line's original
                // gap, up to 250ms. Lines the uploader timed together stay together.
                let originalGap = max(0, mine - (chosen.lines[i - 1].timeMs - chosen.offsetMs))
                t = max(t, previous + min(originalGap, 250))
            }
            previous = t
            let delta = t - mine
            out.lines[i].timeMs += delta
            out.lines[i].words = out.lines[i].words?.map { var w = $0; w.timeMs += delta; return w }
        }
        return (out, overall)
    }

    /// Lines written "original / translation" (Tennu Le: "Tennu le ke jaana apne naal / I will take
    /// you with me"). When most lines have that shape, keep only the original: the translation isn't
    /// sung, and the long-line split showed it as its own timed part.
    static func strippingTranslations(_ lyrics: TimedLyrics) -> TimedLyrics {
        let sung = lyrics.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sung.isEmpty, sung.filter({ $0.text.contains(" / ") }).count * 10 >= sung.count * 4 else { return lyrics }
        var out = lyrics
        out.lines = lyrics.lines.map { line in
            guard let cut = line.text.range(of: " / ") else { return line }
            var l = line
            l.text = String(line.text[..<cut.lowerBound]).trimmingCharacters(in: .whitespaces)
            return l
        }
        return out
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
        let source = lyrics.source
        lyrics = Self.strippingTranslations(lyrics)
        if lyrics.isSynced {
            let (timed, shift) = Self.consensusTimed(lyrics, versions: results, durationMs: track.durationMs)
            lyrics = timed
            lyrics.source = "\(source ?? "?") uploads=\(results.count) consensus=\(shift)ms per-line"
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
