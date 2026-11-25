import Foundation
import StoreKit
import CarLyricsCore

/// Apple Music's word-timed lyrics need two keys: the web player's developer token (public, read
/// from music.apple.com's script) and an Apple Music user token. The user token comes from the
/// Apple Music account already on the phone (StoreKit), so normally there's nothing to sign in to;
/// if Apple refuses that one, Settings offers the music.apple.com sign-in (`via: .web`) instead.
/// Tokens live in the Keychain and are never logged.
@MainActor
final class AppleMusicAccount: ObservableObject {
    enum Via: String, Codable { case phone, web }
    private struct Saved: Codable { var tokens: AppleMusicLyrics.Tokens; var via: Via }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var status = "Not connected yet"
    /// The phone's account was refused: Settings shows "Sign In to Apple Music".
    @Published private(set) var needsSignIn = false
    @Published private(set) var via: Via?

    private var saved: Saved? {
        didSet {
            Keychain.set(saved.flatMap { try? JSONEncoder().encode($0) }, Self.keychainService)
            via = saved?.via
        }
    }
    private var connecting: Task<AppleMusicLyrics.Tokens?, Never>?

    private static let enabledKey = "lyrics.appleMusic"
    private static let keychainService = "carlyrics.apple"

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        saved = Keychain.data(Self.keychainService).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved { status = "Connected · store \(saved.tokens.storefront.uppercased())" }
    }

    /// Apple's lyrics for a catalog song: word-timed, else line-timed. Throws when Apple can't
    /// (not connected, refused, no lyrics); the caller falls back to LRCLIB.
    func lyrics(songID: String) async throws -> TimedLyrics {
        guard enabled, let current = await tokens() else { throw AppleMusicLyrics.Failure.userTokenRejected }
        do {
            return try await AppleMusicLyrics.fetch(songID: songID, tokens: current)
        } catch AppleMusicLyrics.Failure.developerTokenRejected {
            // The web player's token rotated: fetch the new one and try once more.
            guard let fresh = await tokens(refreshDeveloper: true) else { throw AppleMusicLyrics.Failure.developerTokenRejected }
            return try await handled { try await AppleMusicLyrics.fetch(songID: songID, tokens: fresh) }
        } catch {
            return try await handled { throw error }
        }
    }

    private func handled(_ body: () async throws -> TimedLyrics) async throws -> TimedLyrics {
        do { return try await body() } catch let failure as AppleMusicLyrics.Failure {
            switch failure {
            case .userTokenRejected:
                needsSignIn = true
                status = saved?.via == .web ? "Signed out by Apple: sign in again" : "Apple refused this phone's account: sign in instead"
                saved = nil
            case .noSubscription: status = "Needs an Apple Music subscription"
            case .developerTokenRejected: status = "Apple's web player key changed: will retry"
            case .notFound, .http: break // this song only
            }
            throw failure
        }
    }

    /// Saved tokens, or connect with the phone's account. One connect at a time.
    private func tokens(refreshDeveloper: Bool = false) async -> AppleMusicLyrics.Tokens? {
        if !refreshDeveloper, let t = saved?.tokens,
           (AppleMusicLyrics.expiry(ofJWT: t.developer) ?? .distantFuture) > Date().addingTimeInterval(86_400) {
            return t
        }
        if let connecting { return await connecting.value }
        let task = Task { await connect(keepingUserToken: refreshDeveloper && saved?.via == .web) }
        connecting = task
        defer { connecting = nil }
        return await task.value
    }

    /// Phone path: a user token minted for the web player's developer token. Web path (`keeping…`):
    /// the music.apple.com login's token stays, only the developer token is replaced.
    private func connect(keepingUserToken: Bool) async -> AppleMusicLyrics.Tokens? {
        if needsSignIn && !keepingUserToken { return nil } // the phone's account was refused; wait for the sign-in
        status = "Connecting…"
        do {
            let developer = try await AppleMusicLyrics.fetchDeveloperToken()
            let user: String
            let via: Via
            if keepingUserToken, let old = saved?.tokens.user {
                (user, via) = (old, .web)
            } else {
                guard await Self.authorized() else {
                    status = "Allow Media & Apple Music for Car Lyrics in Settings"
                    return nil
                }
                (user, via) = (try await SKCloudServiceController().requestUserToken(forDeveloperToken: developer), .phone)
            }
            let storefront = try await AppleMusicLyrics.fetchStorefront(developer: developer, user: user)
            let tokens = AppleMusicLyrics.Tokens(developer: developer, user: user, storefront: storefront)
            saved = Saved(tokens: tokens, via: via)
            status = "Connected · store \(storefront.uppercased())"
            EventLog.log("apple music connected via=\(via.rawValue) store=\(storefront) user=\(user.count)chars")
            return tokens
        } catch {
            status = "Couldn't connect: \(Self.describe(error))"
            EventLog.log("apple music connect failed: \(Self.describe(error))")
            if case AppleMusicLyrics.Failure.userTokenRejected = error { needsSignIn = true }
            return nil
        }
    }

    /// From the music.apple.com sign-in sheet: its `media-user-token` cookie replaces the phone's.
    func signedIn(userToken: String) async {
        needsSignIn = false
        saved = nil
        do {
            let developer = try await AppleMusicLyrics.fetchDeveloperToken()
            let storefront = try await AppleMusicLyrics.fetchStorefront(developer: developer, user: userToken)
            saved = Saved(tokens: .init(developer: developer, user: userToken, storefront: storefront), via: .web)
            status = "Signed in · store \(storefront.uppercased())"
            EventLog.log("apple music connected via=web store=\(storefront) user=\(userToken.count)chars")
        } catch {
            status = "Sign-in didn't work: \(Self.describe(error))"
        }
    }

    /// Forget the keys (and the web sign-in). The next Apple Music song connects again.
    func disconnect() async {
        saved = nil
        needsSignIn = false
        status = "Not connected yet"
        await WebCookies.clear(domain: "apple.com")
    }

    private static func authorized() async -> Bool {
        if SKCloudServiceController.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SKCloudServiceController.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? AppleMusicLyrics.Failure {
        case .developerTokenRejected?: "Apple's web player key wasn't found"
        case .userTokenRejected?: "Apple refused the account"
        case .noSubscription?: "no Apple Music subscription"
        case .http(let code)?: "HTTP \(code)"
        case .notFound?: "not found"
        case nil: (error as NSError).localizedDescription
        }
    }
}
