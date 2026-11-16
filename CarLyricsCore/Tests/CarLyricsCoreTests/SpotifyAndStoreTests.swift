import XCTest
@testable import CarLyricsCore

final class SpotifyAuthTests: XCTestCase {

    func testBase64URLNoPadding() {
        // Known vector: base64url of bytes has no +, /, or =.
        let data = Data([0xFB, 0xFF, 0xFE])
        let encoded = SpotifyAuth.base64URL(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(encoded, "-__-")
    }

    func testPKCEDeterministicFromBytes() {
        let bytes = Array(repeating: UInt8(0), count: 32)
        let a = SpotifyAuth.makePKCE(randomBytes: bytes)
        let b = SpotifyAuth.makePKCE(randomBytes: bytes)
        XCTAssertEqual(a, b, "same seed must yield same PKCE pair")
        XCTAssertNotEqual(a.verifier, a.challenge, "challenge is a hash, not the verifier")
        // Verifier length is within RFC 7636 bounds (43..128).
        XCTAssertGreaterThanOrEqual(a.verifier.count, 43)
        XCTAssertLessThanOrEqual(a.verifier.count, 128)
    }

    func testAuthorizationURLShape() {
        let auth = SpotifyAuth(clientID: "CID", redirectURI: "carlyrics://cb")
        let pkce = SpotifyAuth.makePKCE(randomBytes: Array(repeating: 1, count: 32))
        let url = auth.authorizationURL(pkce: pkce, state: "xyz")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(comps.host, "accounts.spotify.com")
        XCTAssertEqual(items["client_id"], "CID")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["state"], "xyz")
        XCTAssertTrue(items["scope"]!.contains("user-read-currently-playing"))
    }

    func testTokenExpiry() {
        let now = Date(timeIntervalSince1970: 0)
        let tokens = SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired(now: now))
        XCTAssertTrue(tokens.isExpired(now: now.addingTimeInterval(3600))) // at expiry, expired
        XCTAssertTrue(tokens.isExpired(now: now.addingTimeInterval(3550)))  // within 60s leeway
    }

    func testDecodeCurrentlyPlaying() throws {
        let json = """
        {
          "is_playing": true,
          "progress_ms": 42000,
          "item": {
            "name": "Bohemian Rhapsody",
            "artists": [{"name": "Queen"}],
            "album": {"name": "A Night at the Opera"},
            "duration_ms": 354000
          }
        }
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 500)
        let state = try SpotifyClient.decodePlayback(json, now: now)
        XCTAssertEqual(state.track.title, "Bohemian Rhapsody")
        XCTAssertEqual(state.track.artist, "Queen")
        XCTAssertEqual(state.track.album, "A Night at the Opera")
        XCTAssertEqual(state.track.durationMs, 354_000)
        XCTAssertEqual(state.track.source, .spotify)
        XCTAssertEqual(state.positionMs, 42_000)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.sampledAt, now)
    }

    func testDecodeMultipleArtistsJoined() throws {
        let json = """
        {"is_playing": false, "progress_ms": 0,
         "item": {"name": "Track", "artists": [{"name": "A"}, {"name": "B"}], "duration_ms": 1000}}
        """.data(using: .utf8)!
        let state = try SpotifyClient.decodePlayback(json)
        XCTAssertEqual(state.track.artist, "A, B")
    }

    func testDecodeNoItemThrowsNotPlaying() {
        let json = #"{"is_playing": false}"#.data(using: .utf8)!
        XCTAssertThrowsError(try SpotifyClient.decodePlayback(json)) { error in
            XCTAssertEqual(error as? SpotifyClient.SpotifyError, .notPlaying)
        }
    }
}

final class LyricsStoreTests: XCTestCase {

    private func tempStore() -> LyricsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("carlyrics-test-\(UUID().uuidString)", isDirectory: true)
        return LyricsStore(directory: dir)
    }

    func testRoundTrip() {
        let store = tempStore()
        let track = NowPlayingTrack(title: "Song", artist: "Artist", durationMs: 200_000, source: .appleMusic)
        let lyrics = TimedLyrics(lines: [LyricsLine(timeMs: 1000, text: "hi")], isSynced: true, offsetMs: 50)
        XCTAssertNil(store.load(for: track))
        store.save(lyrics, for: track)
        let loaded = store.load(for: track)
        XCTAssertEqual(loaded, lyrics)
    }

    func testEntriesExpire30DaysAfterTheLastPlayAndAPlayRenewsThem() throws {
        let store = tempStore()
        let lyrics = TimedLyrics(lines: [LyricsLine(timeMs: 1000, text: "hi")], isSynced: true)
        let day: TimeInterval = 24 * 60 * 60
        let now = Date()
        func age(_ key: String, days: Double) throws {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * day)],
                                                  ofItemAtPath: store.fileURL(for: key).path)
        }
        store.save(lyrics, key: "played")
        try age("played", days: 29)
        XCTAssertEqual(store.load(key: "played", now: now), lyrics)       // still fresh…
        XCTAssertEqual(store.load(key: "played", now: now.addingTimeInterval(29 * day)), lyrics) // …and renewed by that play
        store.save(lyrics, key: "stale")
        try age("stale", days: 31)
        XCTAssertNil(store.load(key: "stale", now: now))                  // expired, and deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "stale").path))
        store.save(lyrics, key: "forgotten")
        try age("forgotten", days: 40)
        store.pruneExpired(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "forgotten").path))
    }

    func testCacheFileNameIsStableAcrossLaunches() {
        // Must not depend on Swift's per-process-seeded hashValue, or the cache misses every launch.
        let name = tempStore().fileURL(for: "queen|bohemian rhapsody|354").lastPathComponent
        XCTAssertEqual(name, "86a42d7f0dc6afb6a3755965797854a0c0d84b57256993f57fa78dc7f5042652.json")
    }

    func testIdentityKeyIgnoresSource() {
        // Same song from Apple Music and Spotify shares a cache entry.
        let apple = NowPlayingTrack(title: "Song", artist: "Artist", durationMs: 200_000, source: .appleMusic)
        let spotify = NowPlayingTrack(title: "song", artist: "ARTIST", durationMs: 200_400, source: .spotify)
        XCTAssertEqual(apple.identityKey, spotify.identityKey)
    }

    func testIsDifferentSong() {
        let a = NowPlayingTrack(title: "One", artist: "X", source: .spotify)
        let b = NowPlayingTrack(title: "Two", artist: "X", source: .spotify)
        XCTAssertTrue(a.isDifferentSong(from: b))
        XCTAssertFalse(a.isDifferentSong(from: a))
        XCTAssertTrue(a.isDifferentSong(from: nil))
    }
}
