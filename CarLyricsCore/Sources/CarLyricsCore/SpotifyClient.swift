import Foundation
import CryptoKit

/// Spotify Web API access for reading the user's currently-playing track.
///
/// There is no push/webhook API — polling `GET /me/player/currently-playing` is the only
/// option (spotify/web-api#492). Auth is Authorization Code + PKCE (no client secret on
/// device). For personal use we ship our own client ID, so we never hit the shared-quota
/// problem that forces the commercial apps into "bring your own client ID" mode.
public struct SpotifyAuth: Sendable {
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    public init(
        clientID: String,
        redirectURI: String,
        scopes: [String] = ["user-read-currently-playing", "user-read-playback-state"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    // MARK: PKCE

    /// A PKCE verifier/challenge pair. Verifier is 43–128 chars of the unreserved set.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String
    }

    /// Generate a PKCE pair. `randomBytes` is injectable for deterministic tests.
    public static func makePKCE(randomBytes: [UInt8]? = nil) -> PKCE {
        let bytes = randomBytes ?? (0..<64).map { _ in UInt8.random(in: 0...255) }
        let verifier = base64URL(Data(bytes))
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(hash))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    /// Base64-URL without padding, per RFC 7636.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL to open in ASWebAuthenticationSession. `state` guards against CSRF.
    public func authorizationURL(pkce: PKCE, state: String) -> URL {
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return comps.url!
    }
}

/// OAuth token bundle. `expiresAt` is computed so callers can check `isExpired`.
public struct SpotifyTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

public struct SpotifyClient: Sendable {
    let auth: SpotifyAuth
    let session: URLSession
    let tokenEndpoint: URL
    let apiBase: URL

    /// The coordinator's 1s tick awaits these calls, so a stalled request must fail in seconds,
    /// not URLSession's 60s default (which froze Apple Music + the Live Activity in Auto mode).
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    public init(
        auth: SpotifyAuth,
        session: URLSession = SpotifyClient.defaultSession,
        tokenEndpoint: URL = URL(string: "https://accounts.spotify.com/api/token")!,
        apiBase: URL = URL(string: "https://api.spotify.com/v1")!
    ) {
        self.auth = auth
        self.session = session
        self.tokenEndpoint = tokenEndpoint
        self.apiBase = apiBase
    }

    public enum SpotifyError: Error, Equatable {
        case notPlaying          // 204 No Content
        case rateLimited(retryAfter: Int)
        case unauthorized
        case badResponse(status: Int)
    }

    // MARK: Token exchange

    private struct TokenResponse: Codable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Int
    }

    public func exchangeCode(_ code: String, verifier: String, now: Date = Date()) async throws -> SpotifyTokens {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": auth.redirectURI,
            "client_id": auth.clientID,
            "code_verifier": verifier,
        ]
        let tr = try await postToken(form: form)
        return SpotifyTokens(accessToken: tr.access_token, refreshToken: tr.refresh_token, expiresAt: now.addingTimeInterval(TimeInterval(tr.expires_in)))
    }

    public func refresh(_ tokens: SpotifyTokens, now: Date = Date()) async throws -> SpotifyTokens {
        guard let refresh = tokens.refreshToken else { throw SpotifyError.unauthorized }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": auth.clientID,
        ]
        let tr = try await postToken(form: form)
        // Spotify may omit a new refresh token; keep the old one if so.
        return SpotifyTokens(accessToken: tr.access_token, refreshToken: tr.refresh_token ?? refresh, expiresAt: now.addingTimeInterval(TimeInterval(tr.expires_in)))
    }

    private func postToken(form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyError.badResponse(status: -1) }
        guard http.statusCode == 200 else {
            // The token endpoint answers a revoked/expired refresh token with 400 invalid_grant.
            if http.statusCode == 400 || http.statusCode == 401 { throw SpotifyError.unauthorized }
            throw SpotifyError.badResponse(status: http.statusCode)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Now playing

    /// Raw shape of `/me/player/currently-playing`. Only the fields we use are modeled.
    struct CurrentlyPlaying: Codable {
        struct Item: Codable {
            struct Artist: Codable { var name: String }
            struct Album: Codable { var name: String? }
            var name: String
            var artists: [Artist]
            var album: Album?
            var duration_ms: Int?
        }
        var is_playing: Bool
        var progress_ms: Int?
        var item: Item?
    }

    /// Fetch the currently-playing track. Refreshes tokens caller-side; pass a valid access
    /// token. Throws `.notPlaying` on 204, `.rateLimited` on 429, `.unauthorized` on 401.
    public func currentlyPlaying(accessToken: String, now: Date = Date()) async throws -> PlaybackState {
        var req = URLRequest(url: apiBase.appendingPathComponent("me/player/currently-playing"))
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyError.badResponse(status: -1) }
        switch http.statusCode {
        case 204: throw SpotifyError.notPlaying
        case 401: throw SpotifyError.unauthorized
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            throw SpotifyError.rateLimited(retryAfter: retry)
        case 200: break
        default: throw SpotifyError.badResponse(status: http.statusCode)
        }
        return try Self.decodePlayback(data, now: now)
    }

    /// Decode a currently-playing payload into a `PlaybackState`. Exposed for testing.
    public static func decodePlayback(_ data: Data, now: Date = Date()) throws -> PlaybackState {
        let cp = try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
        guard let item = cp.item else { throw SpotifyError.notPlaying }
        let track = NowPlayingTrack(
            title: item.name,
            artist: item.artists.map(\.name).joined(separator: ", "),
            album: item.album?.name,
            durationMs: item.duration_ms,
            source: .spotify
        )
        return PlaybackState(track: track, positionMs: cp.progress_ms ?? 0, isPlaying: cp.is_playing, sampledAt: now)
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
