import Foundation
import UIKit
import AuthenticationServices
import CarLyricsCore

/// Spotify config: Akshat's own dev app (developer.spotify.com/dashboard, redirect URI
/// `carlyrics://spotify-callback`, Web API). A PKCE client ID isn't a secret. Dev mode needs a
/// Premium owner and lists at most 5 users (User Management).
enum SpotifyConfig {
    static let clientID = "02a46e46125948ddae76419842bee2a2"
    static let redirectURI = "carlyrics://spotify-callback"
    static var isConfigured: Bool { clientID != "PUT_YOUR_SPOTIFY_CLIENT_ID_HERE" && !clientID.isEmpty }
}

/// Owns Spotify auth (PKCE via ASWebAuthenticationSession) and token lifecycle, and exposes
/// a single `poll()` that returns the current `PlaybackState`. Tokens live in the Keychain.
@MainActor
final class SpotifyController: NSObject, ObservableObject {
    @Published private(set) var isLoggedIn = false

    private let auth = SpotifyAuth(clientID: SpotifyConfig.clientID, redirectURI: SpotifyConfig.redirectURI)
    private lazy var client = SpotifyClient(auth: auth)
    private var tokens: SpotifyTokens? { didSet { isLoggedIn = tokens != nil; persist() } }
    private var webSession: ASWebAuthenticationSession?

    private static let keychainService = "carlyrics.spotify"
    private static let oldDefaultsKey = "spotify.tokens" // before 2026-11-25

    override init() {
        super.init()
        load()
    }

    // MARK: Auth

    func login() async throws {
        let pkce = SpotifyAuth.makePKCE()
        let state = UUID().uuidString
        let url = auth.authorizationURL(pkce: pkce, state: state)
        let code = try await presentAuth(url: url, state: state)
        tokens = try await client.exchangeCode(code, verifier: pkce.verifier)
    }

    func logout() {
        tokens = nil
    }

    private func presentAuth(url: URL, state: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let scheme = URL(string: SpotifyConfig.redirectURI)?.scheme
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error { cont.resume(throwing: error); return }
                guard let callback,
                      let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                      let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value,
                      returnedState == state,
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(throwing: AuthError.invalidCallback); return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            // If start() fails (e.g. a presentation is already in progress or the anchor is
            // unavailable) the completion handler never fires — resume here or login() hangs.
            if !session.start() {
                cont.resume(throwing: AuthError.invalidCallback)
            }
        }
    }

    enum AuthError: Error { case invalidCallback, notLoggedIn }

    // MARK: Polling

    /// Returns the current playback, refreshing the access token if needed. Throws
    /// `SpotifyClient.SpotifyError.notPlaying` when nothing is playing.
    func poll() async throws -> PlaybackState {
        guard var current = tokens else { throw AuthError.notLoggedIn }
        if current.isExpired(now: Date()) {
            current = try await refreshed(current)
        }
        do {
            return try await client.currentlyPlaying(accessToken: current.accessToken)
        } catch SpotifyClient.SpotifyError.unauthorized {
            // Access token rejected — refresh once and retry.
            let fresh = try await refreshed(current)
            return try await client.currentlyPlaying(accessToken: fresh.accessToken)
        }
    }

    /// A rejected refresh token means the login is gone: drop it so the UI offers "Connect
    /// Spotify" again, instead of retrying a dead token every poll while showing the last song.
    private func refreshed(_ current: SpotifyTokens) async throws -> SpotifyTokens {
        do {
            let fresh = try await client.refresh(current)
            tokens = fresh
            return fresh
        } catch SpotifyClient.SpotifyError.unauthorized {
            tokens = nil
            throw SpotifyClient.SpotifyError.unauthorized
        }
    }

    // MARK: Persistence

    private func persist() {
        Keychain.set(tokens.flatMap { try? JSONEncoder().encode($0) }, Self.keychainService)
    }

    private func load() {
        // One-time move from UserDefaults (setting `tokens` persists to the Keychain).
        let defaults = UserDefaults.standard
        let data = Keychain.data(Self.keychainService) ?? defaults.data(forKey: Self.oldDefaultsKey)
        defaults.removeObject(forKey: Self.oldDefaultsKey)
        guard let data, let saved = try? JSONDecoder().decode(SpotifyTokens.self, from: data) else { return }
        tokens = saved
    }
}

extension SpotifyController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The app's real key window; a detached `ASPresentationAnchor()` has no scene on iOS 26+.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
