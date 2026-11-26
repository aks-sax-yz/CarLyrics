import Foundation

/// Spotify's own lyrics (Musixmatch's, timed to Spotify's audio), the way open.spotify.com's web
/// player gets them: the private `color-lyrics` service with the web player's access token and
/// client token (captured from a signed-in web view, see SpotifyLyricsAccount). Mostly line-timed.
/// Private and unofficial: every failure falls back to LRCLIB.
public enum SpotifyLyrics {
    public struct Tokens: Codable, Sendable, Equatable {
        public var access: String
        public var client: String?
        public var expires: Date
        public init(access: String, client: String?, expires: Date) {
            self.access = access
            self.client = client
            self.expires = expires
        }
    }

    public enum Failure: Error, Equatable { case tokenRejected, notFound, http(Int) }

    public static func request(trackID: String, tokens: Tokens) -> URLRequest {
        let url = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)?format=json&vocalRemoval=false&market=from_token")!
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        if let client = tokens.client { r.setValue(client, forHTTPHeaderField: "client-token") }
        r.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public static func outcome(status: Int, body: Data) -> Result<TimedLyrics, Failure> {
        switch status {
        case 200: return parse(body).map { .success($0) } ?? .failure(.notFound)
        case 401, 403: return .failure(.tokenRejected)
        case 404: return .failure(.notFound)
        default: return .failure(.http(status))
        }
    }

    /// `{"lyrics": {"syncType": "LINE_SYNCED" | "UNSYNCED" | …, "lines": [{"startTimeMs": "1230",
    /// "words": "…", "endTimeMs": "0"}]}}`. Times are strings; "♪" marks an instrumental gap.
    static func parse(_ data: Data) -> TimedLyrics? {
        struct Doc: Decodable {
            struct L: Decodable {
                struct Line: Decodable { var startTimeMs: String?; var words: String?; var endTimeMs: String? }
                var syncType: String?
                var lines: [Line]
            }
            var lyrics: L
        }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data), !doc.lyrics.lines.isEmpty else { return nil }
        let synced = doc.lyrics.syncType != "UNSYNCED"
        let lines = doc.lyrics.lines.map { line -> LyricsLine in
            let text = (line.words ?? "").trimmingCharacters(in: .whitespaces)
            let end = line.endTimeMs.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            return LyricsLine(timeMs: synced ? Int(line.startTimeMs ?? "") ?? 0 : 0,
                              text: text == "♪" ? "" : text, endMs: synced ? end : nil)
        }
        var lyrics = TimedLyrics(lines: lines.sorted { $0.timeMs < $1.timeMs }, isSynced: synced)
        lyrics.source = "spotify \(doc.lyrics.syncType ?? "?")"
        return lyrics
    }

    /// The Spotify track for a recording's ISRC (an Apple Music song's twin) whose length matches
    /// `durationMs` to the second, or nil. Web API search, with the web player's token.
    public static func trackID(isrc: String, durationMs: Int?, tokens: Tokens, session: URLSession = .shared) async throws -> String? {
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [.init(name: "q", value: "isrc:\(isrc)"), .init(name: "type", value: "track"), .init(name: "limit", value: "5")]
        var r = URLRequest(url: comps.url!, timeoutInterval: 10)
        r.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: r)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return trackID(fromSearch: data, durationMs: durationMs)
        case 401, 403: throw Failure.tokenRejected
        case let status: throw Failure.http(status)
        }
    }

    /// The Spotify track for a song known by title and artist (YouTube Music says nothing else): searched
    /// by title + first artist, kept only with the same title, that artist and a length within `tolerance`.
    public static func trackID(title: String, artist: String, durationMs: Int?, tolerance: Int, tokens: Tokens,
                               session: URLSession = .shared) async throws -> String? {
        let firstArtist = artist.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? artist
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [.init(name: "q", value: "\(cutTitle(title)) \(firstArtist)"), .init(name: "type", value: "track"),
                            .init(name: "limit", value: "10")]
        var r = URLRequest(url: comps.url!, timeoutInterval: 10)
        r.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: r)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return trackID(fromSearch: data, durationMs: durationMs, tolerance: tolerance, title: title, artist: firstArtist)
        case 401, 403: throw Failure.tokenRejected
        case let status: throw Failure.http(status)
        }
    }

    /// The first result of the same length (within `tolerance`), and when `title` is given, the same title
    /// (ignoring "(feat. …)" / "[From …]" / " - Remastered" tails, case, accents) and `artist` among its artists.
    static func trackID(fromSearch data: Data, durationMs: Int?, tolerance: Int = AppleMusicLyrics.durationTolerance,
                        title: String? = nil, artist: String? = nil) -> String? {
        struct Doc: Decodable {
            struct T: Decodable {
                struct I: Decodable { struct A: Decodable { var name: String }; var id: String; var duration_ms: Int?; var name: String?; var artists: [A]? }
                var items: [I]
            }
            var tracks: T
        }
        guard let durationMs, let items = (try? JSONDecoder().decode(Doc.self, from: data))?.tracks.items else { return nil }
        return items.first { item in
            guard let d = item.duration_ms, abs(d - durationMs) <= tolerance else { return false }
            guard let title else { return true }
            return norm(item.name ?? "") == norm(title)
                && (artist.map { a in (item.artists ?? []).contains { norm($0.name) == norm(a) } } ?? true)
        }?.id
    }

    /// A title without its "(feat. …)", "[From …]" or " - Remastered" tail.
    static func cutTitle(_ s: String) -> String {
        var t = s
        for cut in [" (", " [", " - "] { if let r = t.range(of: cut) { t = String(t[..<r.lowerBound]) } }
        return t
    }

    static func norm(_ s: String) -> String {
        cutTitle(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).filter { $0.isLetter || $0.isNumber }
    }

    public static func fetch(trackID: String, tokens: Tokens, session: URLSession = .shared) async throws -> TimedLyrics {
        let (data, response) = try await session.data(for: request(trackID: trackID, tokens: tokens))
        switch outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data) {
        case .success(var lyrics):
            lyrics.source = (lyrics.source ?? "spotify") + " id=\(trackID)"
            return lyrics
        case .failure(let failure): throw failure
        }
    }
}
