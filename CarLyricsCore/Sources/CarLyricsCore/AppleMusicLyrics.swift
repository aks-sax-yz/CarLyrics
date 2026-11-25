import Foundation

/// Apple Music's own lyrics, the way music.apple.com's web player gets them: word-timed TTML from
/// the private `amp-api` service, with the web player's developer token and the listener's Apple
/// Music user token. Private and unofficial: every failure falls back to LRCLIB.
public enum AppleMusicLyrics {
    public struct Tokens: Codable, Sendable, Equatable {
        public var developer: String
        public var user: String
        /// Lowercase ISO country (`in`): must be the account's own store or every song is 404.
        public var storefront: String
        public init(developer: String, user: String, storefront: String) {
            self.developer = developer
            self.user = user
            self.storefront = storefront
        }
    }

    public enum Failure: Error, Equatable {
        case developerTokenRejected   // 401: the web player's token rotated (~70 days)
        case userTokenRejected        // 403: signed out / token expired
        case noSubscription           // 404 code 40403
        case notFound                 // Apple has no lyrics (of this kind) for the song
        case http(Int)
    }

    /// `syllable: true` asks for word-timed lyrics, `false` for line-timed ones.
    public static func request(songID: String, tokens: Tokens, syllable: Bool) -> URLRequest {
        var comps = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(tokens.storefront)/songs/\(songID)/\(syllable ? "syllable-lyrics" : "lyrics")")!
        comps.queryItems = [.init(name: "l[lyrics]", value: "en-US"), .init(name: "l[script]", value: "en-Latn"),
                            .init(name: "extend", value: "ttmlLocalizations")]
        var r = URLRequest(url: comps.url!, timeoutInterval: 10)
        r.setValue("Bearer \(tokens.developer)", forHTTPHeaderField: "Authorization")
        r.setValue(tokens.user, forHTTPHeaderField: "media-user-token")
        r.setValue("https://music.apple.com", forHTTPHeaderField: "Origin") // without it: 401/403
        r.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        return r
    }

    public static func outcome(status: Int, body: Data) -> Result<TimedLyrics, Failure> {
        switch status {
        case 200:
            struct Doc: Decodable {
                struct Item: Decodable { struct A: Decodable { var ttml: String?; var ttmlLocalizations: String? }; var attributes: A? }
                var data: [Item]
            }
            let attrs = (try? JSONDecoder().decode(Doc.self, from: body))?.data.first?.attributes
            guard let ttml = attrs?.ttmlLocalizations ?? attrs?.ttml, let lyrics = AppleTTML.parse(ttml) else { return .failure(.notFound) }
            return .success(lyrics)
        case 401: return .failure(.developerTokenRejected)
        case 403: return .failure(.userTokenRejected)
        case 404:
            struct Errs: Decodable { struct E: Decodable { var code: String? }; var errors: [E] }
            let code = (try? JSONDecoder().decode(Errs.self, from: body))?.errors.first?.code
            return .failure(code == "40403" ? .noSubscription : .notFound)
        default: return .failure(.http(status))
        }
    }

    /// Word-timed lyrics, else line-timed ones. Throws `Failure`.
    public static func fetch(songID: String, tokens: Tokens, session: URLSession = .shared) async throws -> TimedLyrics {
        for syllable in [true, false] {
            let (data, response) = try await session.data(for: request(songID: songID, tokens: tokens, syllable: syllable))
            switch outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data) {
            case .success(var lyrics):
                lyrics.source = "apple \(syllable ? "syllable" : "line") id=\(songID)"
                return lyrics
            case .failure(.notFound) where syllable: continue
            case .failure(let failure): throw failure
            }
        }
        throw Failure.notFound
    }

    /// The signed-in account's storefront (`in`), from `/v1/me/storefront`.
    public static func fetchStorefront(developer: String, user: String, session: URLSession = .shared) async throws -> String {
        var r = URLRequest(url: URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!, timeoutInterval: 10)
        r.setValue("Bearer \(developer)", forHTTPHeaderField: "Authorization")
        r.setValue(user, forHTTPHeaderField: "media-user-token")
        r.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        r.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? Failure.developerTokenRejected : status == 403 ? .userTokenRejected : .http(status) }
        struct Doc: Decodable { struct S: Decodable { var id: String }; var data: [S] }
        guard let id = (try? JSONDecoder().decode(Doc.self, from: data))?.data.first?.id else { throw Failure.http(status) }
        return id
    }

    // MARK: Developer token

    /// The web player's developer token (`kid: WebPlayKid`), from its script bundle. No sign-in needed.
    public static func fetchDeveloperToken(session: URLSession = .shared) async throws -> String {
        let page = try await text(URL(string: "https://music.apple.com/us/browse")!, session)
        let scripts = matches(#"/assets/index[^"'\s]*\.js"#, in: page)
        for path in Set(scripts) {
            if let token = developerToken(inScript: try await text(URL(string: "https://music.apple.com" + path)!, session)) {
                return token
            }
        }
        throw Failure.developerTokenRejected
    }

    /// The first unexpired JWT in `js` whose header says `kid: WebPlayKid`.
    public static func developerToken(inScript js: String, now: Date = Date()) -> String? {
        matches(#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, in: js).first { jwt in
            let parts = jwt.split(separator: ".").map(String.init)
            guard let header = json(parts[0]), header["kid"] as? String == "WebPlayKid" else { return false }
            let exp = (json(parts[1])?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture
            return exp > now
        }
    }

    /// When a JWT expires (to refresh the developer token ahead of time).
    public static func expiry(ofJWT jwt: String) -> Date? {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3, let exp = json(parts[1])?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func json(_ base64URL: String) -> [String: Any]? {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func text(_ url: URL, _ session: URLSession) async throws -> String {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                    forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return String(decoding: data, as: UTF8.self)
    }
}
