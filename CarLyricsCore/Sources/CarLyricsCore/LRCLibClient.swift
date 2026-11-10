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
        return try toLyrics(response)
    }

    /// Fuzzy search fallback when exact `get` misses. Picks the best result (see `bestMatch`).
    public func search(track: String, artist: String, durationMs: Int? = nil) async throws -> TimedLyrics {
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
        let results = try JSONDecoder().decode([Response].self, from: data)
        guard let best = Self.bestMatch(results, durationMs: durationMs) else { throw LRCLibError.notFound }
        return try toLyrics(best)
    }

    /// Synced beats plain (plain can't drive the Live Activity), then closest duration (a live or
    /// remix cut has different timings). Ties keep LRCLIB's order.
    static func bestMatch(_ results: [Response], durationMs: Int?) -> Response? {
        func rank(_ r: Response) -> (Int, Double) {
            let synced = r.syncedLyrics?.isEmpty == false ? 0 : 1
            guard let durationMs, let d = r.duration else { return (synced, 0) }
            return (synced, abs(d - Double(durationMs) / 1000))
        }
        return results
            .filter { $0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false }
            .min { rank($0) < rank($1) }
    }

    /// Try exact get, then fall back to search. The path the app actually calls.
    public func lyrics(for track: NowPlayingTrack) async throws -> TimedLyrics {
        do {
            // Album deliberately omitted: Apple Music appends "- Single"/"(Deluxe)" etc., so an
            // exact album match nearly always 404s and forces the slow search fallback. Track +
            // artist + duration is LRCLIB's effective signature and hits on the first request.
            return try await get(track: track.title, artist: track.artist, durationMs: track.durationMs)
        } catch {
            return try await search(track: track.title, artist: track.artist, durationMs: track.durationMs)
        }
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
