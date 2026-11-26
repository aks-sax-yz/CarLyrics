import XCTest
@testable import CarLyrics

/// The YouTube Music clock against the sequences seen on the phone (2026-11-26 tests).
final class YouTubeMusicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func song(_ id: String) -> YTMTimeline.Song { .init(id: id, title: id, artist: "A", durationMs: 200_000) }

    /// A timeline that saw `a` start at t0 and is playing it.
    private func playingA() -> YTMTimeline {
        var tl = YTMTimeline()
        _ = tl.history(song("a"), at: at(-100)) // the first answer after launch: no timing
        tl.signal(at: at(-50), playState: true)
        tl.setPlaying(true, at: at(-50))
        tl.signal(at: at(0), playState: false) // tapped a new song: lock screen signal
        XCTAssertTrue(tl.history(song("a2"), at: at(1.3)))
        _ = tl.history(song("a"), at: at(2)) // a flip back: ignored
        return tl
    }

    func testNewSongIsTimedFromItsSignalAndFlipsBackAreIgnored() {
        let tl = playingA()
        XCTAssertEqual(tl.song?.id, "a2")
        XCTAssertEqual(tl.positionMs(at: at(10)), 10_000)
        XCTAssertTrue(tl.positionKnown)
    }

    func testGoingBackToThePreviousSongNeedsASignal() {
        var tl = playingA()
        tl.signal(at: at(30), playState: false) // "previous"
        XCTAssertTrue(tl.history(song("a"), at: at(31)))
        XCTAssertEqual(tl.positionMs(at: at(35)), 5_000)
    }

    func testPauseAndResumeUseTheSignalMoments() {
        var tl = playingA()
        tl.signal(at: at(20), playState: true)
        tl.setPlaying(false, at: at(20.6)) // the other-audio flag lags the signal
        XCTAssertEqual(tl.positionMs(at: at(25)), 20_000)
        tl.signal(at: at(40), playState: true)
        tl.setPlaying(true, at: at(41))
        tl.settle(at: at(50)) // explained by the resume: still known
        XCTAssertEqual(tl.positionMs(at: at(50)), 30_000)
    }

    func testUnexplainedPlayStateSignalIsADrag() {
        var tl = playingA()
        tl.signal(at: at(20), playState: true) // drag that rebuffers
        tl.settle(at: at(23))
        XCTAssertTrue(tl.positionKnown) // not yet: a skip's history may still come
        tl.settle(at: at(24.1))
        XCTAssertFalse(tl.positionKnown)
        tl.seeked(toMs: 60_000, at: at(30)) // a tapped line
        tl.signal(at: at(30.5), playState: true) // our own jump's signal
        tl.settle(at: at(40))
        XCTAssertEqual(tl.positionMs(at: at(40)), 70_000)
    }

    func testSlowHistoryAfterASkipStillTimesTheSongFromTheSkip() {
        var tl = playingA()
        tl.signal(at: at(20), playState: true)
        tl.settle(at: at(25)) // history is late: unknown for now
        XCTAssertFalse(tl.positionKnown)
        XCTAssertTrue(tl.history(song("b"), at: at(40)))
        XCTAssertEqual(tl.positionMs(at: at(41)), 21_000)
    }

    func testRelaunchNeverGuesses() {
        var tl = playingA()
        tl.stopped(at: at(60)) // CarPlay disconnect
        XCTAssertEqual(tl.positionMs(at: at(99)), 60_000)
        tl.relaunched()
        tl.setPlaying(true, at: at(500)) // already playing when Car Lyrics came back: missed the resume
        XCTAssertFalse(tl.positionKnown)

        var seen = playingA()
        seen.stopped(at: at(60))
        seen.relaunched()
        seen.signal(at: at(500), playState: true) // the resume, seen
        seen.setPlaying(true, at: at(500.5))
        XCTAssertEqual(seen.positionMs(at: at(510)), 70_000)
    }

    func testHistoryParsing() throws {
        let item: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "XfEMj-z3TtA"],
                "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [
                    ["url": "https://lh3.googleusercontent.com/x=w60-h60-l90-rj"], ["url": "https://lh3.googleusercontent.com/x=w120-h120-l90-rj"]]]]],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "STAY"]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                        ["text": "The Kid LAROI", "navigationEndpoint": [:]], ["text": " & "],
                        ["text": "Justin Bieber", "navigationEndpoint": [:]]]]]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "STAY"]]]]],
                ],
                "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": "2:22"]]]]]],
            ],
        ]
        let json: [String: Any] = ["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": [
            "sectionListRenderer": ["contents": [["musicShelfRenderer": ["title": ["runs": [["text": "Today"]]], "contents": [item]]]]]]]]]]]]
        let s = try XCTUnwrap(YouTubeMusicSource.song(fromHistory: json))
        XCTAssertEqual(s.id, "XfEMj-z3TtA")
        XCTAssertEqual(s.title, "STAY")
        XCTAssertEqual(s.artist, "The Kid LAROI, Justin Bieber")
        XCTAssertEqual(s.album, "STAY")
        XCTAssertEqual(s.durationMs, 142_000)
        XCTAssertEqual(s.artworkURL, "https://lh3.googleusercontent.com/x=w544-h544-l90-rj")
        XCTAssertEqual(YouTubeMusicSource.durationMs("1:02:03"), 3_723_000)
        XCTAssertNil(YouTubeMusicSource.durationMs("3:3x"))
    }
}
