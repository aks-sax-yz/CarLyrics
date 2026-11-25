import XCTest
@testable import CarLyricsCore

final class ServiceLyricsTests: XCTestCase {
    private func jwt(_ header: String, _ payload: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(header)).\(b64(payload)).c2ln"
    }

    func testFindsWebPlayDeveloperToken() {
        let future = Int(Date().timeIntervalSince1970) + 86_400
        let other = jwt(#"{"alg":"ES256","kid":"Other"}"#, #"{"exp":\#(future)}"#)
        let expired = jwt(#"{"alg":"ES256","kid":"WebPlayKid"}"#, #"{"exp":1000}"#)
        let good = jwt(#"{"alg":"ES256","typ":"JWT","kid":"WebPlayKid"}"#, #"{"iss":"AMPWebPlay","exp":\#(future)}"#)
        let js = #"const a="\#(other)",b="\#(expired)",c="\#(good)";"#
        XCTAssertEqual(AppleMusicLyrics.developerToken(inScript: js), good)
        XCTAssertEqual(AppleMusicLyrics.expiry(ofJWT: good).map { Int($0.timeIntervalSince1970) }, future)
        XCTAssertNil(AppleMusicLyrics.developerToken(inScript: "no tokens"))
    }

    func testAppleOutcomes() throws {
        let ttml = #"<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"1.0\" end=\"2.0\">Hi</p></div></body></tt>"#
        let ok = Data(#"{"data":[{"attributes":{"ttml":"\#(ttml)"}}]}"#.utf8)
        XCTAssertEqual(try AppleMusicLyrics.outcome(status: 200, body: ok).get().lines.map(\.text), ["Hi"])
        func failure(_ status: Int, _ body: String = "{}") -> AppleMusicLyrics.Failure? {
            if case .failure(let f) = AppleMusicLyrics.outcome(status: status, body: Data(body.utf8)) { return f }
            return nil
        }
        XCTAssertEqual(failure(200, #"{"data":[]}"#), .notFound)
        XCTAssertEqual(failure(401), .developerTokenRejected)
        XCTAssertEqual(failure(403), .userTokenRejected)
        XCTAssertEqual(failure(404, #"{"errors":[{"code":"40403","status":"404"}]}"#), .noSubscription)
        XCTAssertEqual(failure(404, #"{"errors":[{"code":"40400"}]}"#), .notFound)
        XCTAssertEqual(failure(500), .http(500))
    }

    func testAppleRequestHeaders() {
        let r = AppleMusicLyrics.request(songID: "123", tokens: .init(developer: "D", user: "U", storefront: "in"), syllable: true)
        XCTAssertTrue(r.url!.absoluteString.hasPrefix("https://amp-api.music.apple.com/v1/catalog/in/songs/123/syllable-lyrics?"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer D")
        XCTAssertEqual(r.value(forHTTPHeaderField: "media-user-token"), "U")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Origin"), "https://music.apple.com")
    }

    func testSpotifyParse() throws {
        let body = Data(#"{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"2000","words":"Second","endTimeMs":"0"},{"startTimeMs":"500","words":"First","endTimeMs":"1900"},{"startTimeMs":"3000","words":"♪","endTimeMs":"0"}],"provider":"MusixMatch"},"colors":{}}"#.utf8)
        let lyrics = try SpotifyLyrics.outcome(status: 200, body: body).get()
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second", ""])
        XCTAssertEqual(lyrics.lines.map(\.timeMs), [500, 2000, 3000])
        XCTAssertEqual(lyrics.lines.map(\.endMs), [1900, nil, nil])

        let plain = Data(#"{"lyrics":{"syncType":"UNSYNCED","lines":[{"startTimeMs":"0","words":"A"}]}}"#.utf8)
        XCTAssertFalse(try SpotifyLyrics.outcome(status: 200, body: plain).get().isSynced)
        if case .failure(let f) = SpotifyLyrics.outcome(status: 401, body: Data()) { XCTAssertEqual(f, .tokenRejected) } else { XCTFail() }
        if case .failure(let f) = SpotifyLyrics.outcome(status: 404, body: Data()) { XCTAssertEqual(f, .notFound) } else { XCTFail() }
    }

    func testSpotifyPlaybackCarriesTrackID() throws {
        let body = Data(#"{"is_playing":true,"progress_ms":10,"item":{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Song","artists":[{"name":"A"}],"duration_ms":1000}}"#.utf8)
        XCTAssertEqual(try SpotifyClient.decodePlayback(body).track.catalogID, "4uLU6hMCjMI75M1A2tKUQC")
    }
}
