import Foundation
import UIKit
import WebKit
import CarLyricsCore

/// Spotify's own lyrics need the web player's login, separate from "Connect Spotify" (the official
/// API, which only says what's playing). Signing in happens on Spotify's page in a web view that
/// presents itself as Safari, so Google's button works too. The page's own requests carry its access
/// and client tokens; a small script reports them, so Spotify's token scheme (changed often) is
/// never reimplemented here. Tokens last about an hour; a fresh one comes from loading
/// open.spotify.com off screen with the saved login.
@MainActor
final class SpotifyLyricsAccount: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Not signed in"

    private var tokens: SpotifyLyrics.Tokens? {
        didSet { Keychain.set(tokens.flatMap { try? JSONEncoder().encode($0) }, Self.keychainService) }
    }
    private var refreshWeb: WKWebView?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Called when a sign-in captured its first token (closes the sheet).
    var onSignedIn: (() -> Void)?

    private static let keychainService = "carlyrics.spotify.web"
    static let loginURL = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!

    /// Reports the Authorization / client-token headers of the web player's own API requests.
    static let captureScript = """
    (() => {
      const want = u => /spclient|api-partner\\.spotify\\.com|api\\.spotify\\.com/.test(String(u));
      const post = (auth, client) => {
        if (auth && auth.startsWith('Bearer ')) window.webkit.messageHandlers.carlyrics.postMessage({access: auth.slice(7), client: client || ''});
      };
      const pick = (h, k) => {
        if (!h) return null;
        if (typeof Headers !== 'undefined' && h instanceof Headers) return h.get(k);
        if (Array.isArray(h)) { const e = h.find(x => String(x[0]).toLowerCase() === k); return e ? e[1] : null; }
        for (const n in h) if (n.toLowerCase() === k) return h[n];
        return null;
      };
      const f = window.fetch;
      window.fetch = function(input, init) {
        try {
          const url = (input && input.url) || input;
          if (want(url)) { const h = (init && init.headers) || (input && input.headers); post(pick(h, 'authorization'), pick(h, 'client-token')); }
        } catch (e) {}
        return f.apply(this, arguments);
      };
      const open = XMLHttpRequest.prototype.open, set = XMLHttpRequest.prototype.setRequestHeader, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u) { this.__u = u; this.__h = {}; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function(k, v) { if (this.__h) this.__h[String(k).toLowerCase()] = v; return set.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function() { try { if (want(this.__u)) post(this.__h.authorization, this.__h['client-token']); } catch (e) {} return send.apply(this, arguments); };
    })();
    """

    override init() {
        super.init()
        tokens = Keychain.data(Self.keychainService).flatMap { try? JSONDecoder().decode(SpotifyLyrics.Tokens.self, from: $0) }
        isConnected = tokens != nil
        if isConnected { status = "Signed in" }
    }

    /// The sign-in page for the Settings sheet.
    func signInPage() -> SignInWebView {
        SignInWebView(url: Self.loginURL, userAgent: SignInWebView.safariUserAgent, script: Self.captureScript) { [weak self] body in
            self?.received(body)
        }
    }

    func lyrics(trackID: String) async throws -> TimedLyrics {
        guard isConnected else { throw SpotifyLyrics.Failure.tokenRejected }
        if (tokens?.expires ?? .distantPast) < Date() { await refresh() }
        guard let current = tokens else { throw SpotifyLyrics.Failure.tokenRejected }
        do {
            return try await SpotifyLyrics.fetch(trackID: trackID, tokens: current)
        } catch SpotifyLyrics.Failure.tokenRejected {
            tokens?.expires = .distantPast
            await refresh()
            guard let fresh = tokens, fresh.access != current.access else {
                status = "Spotify signed out: sign in again"
                throw SpotifyLyrics.Failure.tokenRejected
            }
            return try await SpotifyLyrics.fetch(trackID: trackID, tokens: fresh)
        }
    }

    /// Spotify's lyrics of an Apple Music song's twin (same recording by ISRC, same length).
    func lyrics(isrc: String, durationMs: Int?) async throws -> TimedLyrics {
        guard isConnected else { throw SpotifyLyrics.Failure.tokenRejected }
        if (tokens?.expires ?? .distantPast) < Date() { await refresh() }
        guard let current = tokens else { throw SpotifyLyrics.Failure.tokenRejected }
        guard let id = try await SpotifyLyrics.trackID(isrc: isrc, durationMs: durationMs, tokens: current) else {
            throw SpotifyLyrics.Failure.notFound // not on Spotify, or not the same length
        }
        var lyrics = try await self.lyrics(trackID: id)
        lyrics.source = (lyrics.source ?? "spotify") + " isrc=\(isrc)"
        return lyrics
    }

    func signOut() async {
        tokens = nil
        isConnected = false
        status = "Not signed in"
        await WebCookies.clear(domain: "spotify.com")
    }

    // MARK: Tokens

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: String]
        MainActor.assumeIsolated { received(body as Any) }
    }

    private func received(_ body: Any) {
        guard let dict = body as? [String: String], let access = dict["access"], access != tokens?.access else { return }
        let client = dict["client"].flatMap { $0.isEmpty ? nil : $0 } ?? tokens?.client
        Task {
            // Logged out, the web player still gets an anonymous token: lyrics need the login.
            guard await WebCookies.value("sp_dc", domain: "spotify.com") != nil else { return }
            let first = !isConnected
            // ponytail: ~1h tokens, assumed fresh (the page just got it); a 401 refreshes early anyway.
            tokens = .init(access: access, client: client, expires: Date().addingTimeInterval(45 * 60))
            isConnected = true
            status = "Signed in"
            releaseWaiters()
            if first {
                EventLog.log("spotify lyrics signed in")
                onSignedIn?()
            }
        }
    }

    private func releaseWaiters() {
        waiters.forEach { $0.resume() }
        waiters = []
    }

    /// Load the web player off screen with the saved login; wait up to 20s for a fresh token.
    private func refresh() async {
        if refreshWeb == nil {
            let web = SignInWebView.makeWebView(script: Self.captureScript, userAgent: SignInWebView.safariUserAgent, handler: self)
            // In a window (invisible), so iOS doesn't pause its scripts.
            web.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
            web.alpha = 0.01
            web.isUserInteractionEnabled = false
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.addSubview(web)
            web.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
            refreshWeb = web
        }
        let before = tokens?.access
        let timeout = Task { try? await Task.sleep(for: .seconds(20)); self.releaseWaiters() }
        await withCheckedContinuation { waiters.append($0) }
        timeout.cancel()
        if let web = refreshWeb {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "carlyrics")
            web.removeFromSuperview()
            refreshWeb = nil
        }
        EventLog.log("spotify lyrics token \(tokens?.access != before ? "refreshed" : "refresh failed")")
    }
}
