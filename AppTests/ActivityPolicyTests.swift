import XCTest
@testable import CarLyrics
import CarLyricsCore

final class ActivityPolicyTests: XCTestCase {
    func testBackgroundKeepAliveIsActiveOnlyWithPermissionSessionAndLocationDelivery() {
        XCTAssertFalse(BackgroundKeepAlive.isEffective(
            authorization: .authorizedWhenInUse,
            hasBackgroundSession: false,
            lastLocationUpdate: nil,
            now: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertFalse(BackgroundKeepAlive.isEffective(
            authorization: .authorizedWhenInUse,
            hasBackgroundSession: true,
            lastLocationUpdate: nil,
            now: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertTrue(BackgroundKeepAlive.isEffective(
            authorization: .authorizedWhenInUse,
            hasBackgroundSession: true,
            lastLocationUpdate: Date(timeIntervalSince1970: 85),
            now: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertFalse(BackgroundKeepAlive.isEffective(
            authorization: .authorizedWhenInUse,
            hasBackgroundSession: true,
            lastLocationUpdate: Date(timeIntervalSince1970: 39),
            now: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertFalse(BackgroundKeepAlive.isEffective(
            authorization: .denied,
            hasBackgroundSession: true,
            lastLocationUpdate: Date(timeIntervalSince1970: 99),
            now: Date(timeIntervalSince1970: 100)
        ))
    }

    func testBackgroundStatusReportsPermissionFailureInsteadOfActive() {
        XCTAssertEqual(BackgroundKeepAlive.currentStatus(
            authorization: .denied,
            hasBackgroundSession: true,
            lastLocationUpdate: Date(timeIntervalSince1970: 99),
            lastError: nil,
            now: Date(timeIntervalSince1970: 100)
        ), .permissionRequired)
        XCTAssertEqual(BackgroundKeepAlive.currentStatus(
            authorization: .authorizedWhenInUse,
            hasBackgroundSession: true,
            lastLocationUpdate: Date(timeIntervalSince1970: 99),
            lastError: nil,
            now: Date(timeIntervalSince1970: 100)
        ), .active)
    }

    func testOnlyDisconnectTransitionEndsActivity() {
        XCTAssertTrue(NowPlayingCoordinator.shouldEndActivity(wasCarPlayConnected: true, isCarPlayConnected: false))
        XCTAssertFalse(NowPlayingCoordinator.shouldEndActivity(wasCarPlayConnected: false, isCarPlayConnected: false))
        XCTAssertFalse(NowPlayingCoordinator.shouldEndActivity(wasCarPlayConnected: false, isCarPlayConnected: true))
        XCTAssertFalse(NowPlayingCoordinator.shouldEndActivity(wasCarPlayConnected: true, isCarPlayConnected: true))
    }

    func testSongStartStaysSteadyThroughJitterButFollowsSeeks() {
        let anchor = Date(timeIntervalSince1970: 1_000)
        // Per-tick jitter keeps the old anchor, so the live timer doesn't force a push per tick.
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: anchor.addingTimeInterval(0.4)), anchor)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: anchor.addingTimeInterval(-1.4)), anchor)
        // A seek / new song moves it.
        let seek = anchor.addingTimeInterval(-30)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: seek), seek)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: nil, candidate: seek), seek)
    }

    func testLyricWindowCarriesUpcomingLinesOnTheWallClock() {
        let lyrics = TimedLyrics(lines: (0..<30).map { LyricsLine(timeMs: 10_000 + $0 * 1_000, text: "L\($0)") },
                                 isSynced: true, offsetMs: 200)
        let start = Date(timeIntervalSince1970: 1_000)
        // Intro: ♪ from song start, then lines 0–23 at songStart + time − (user + file offset).
        let intro = NowPlayingCoordinator.lyricWindow(lyrics, index: nil, songStart: start, userOffsetMs: 800)
        XCTAssertEqual(intro.count, 25)
        XCTAssertEqual(intro[0], .init(text: "", at: start))
        XCTAssertEqual(intro[1], .init(text: "L0", at: start.addingTimeInterval(9)))
        // The window moves only every 8 lines, so the pushed state doesn't change per line.
        XCTAssertEqual(NowPlayingCoordinator.lyricWindow(lyrics, index: 8, songStart: start, userOffsetMs: 800),
                       NowPlayingCoordinator.lyricWindow(lyrics, index: 15, songStart: start, userOffsetMs: 800))
        let end = NowPlayingCoordinator.lyricWindow(lyrics, index: 27, songStart: start, userOffsetMs: 800)
        XCTAssertEqual(end.map(\.text), ["L24", "L25", "L26", "L27", "L28", "L29"])
    }

    func testLongLineIsShownInTwoTimedParts() {
        let long = "aaaa bbbb cccc dddd eeee ffff gggg hhhh" // 39 chars, middle space at 19
        let lyrics = TimedLyrics(lines: [LyricsLine(timeMs: 10_000, text: long), LyricsLine(timeMs: 12_000, text: "short")],
                                 isSynced: true)
        let start = Date(timeIntervalSince1970: 1_000)
        let window = NowPlayingCoordinator.lyricWindow(lyrics, index: 0, songStart: start, userOffsetMs: 0)
        XCTAssertEqual(window.map(\.text), ["", "aaaa bbbb cccc dddd", "eeee ffff gggg hhhh", "short"])
        XCTAssertEqual(window[1].at, start.addingTimeInterval(10))
        // Second part from 19/39 of the way to the next line.
        XCTAssertEqual(window[2].at.timeIntervalSince(start), 10.974, accuracy: 0.001)
        XCTAssertEqual(window[3].at, start.addingTimeInterval(12))
    }

    func testTextTurnsBlackOnLightBackgroundsAndWhiteOnDark() {
        typealias RGB = LyricsActivityAttributes.RGB
        XCTAssertTrue(RGB(r: 1, g: 1, b: 1).wantsDarkText)
        XCTAssertTrue(RGB(r: 1, g: 1, b: 0).wantsDarkText)     // yellow
        XCTAssertTrue(RGB(r: 0.5, g: 0.5, b: 0.5).wantsDarkText) // mid grey: black has more contrast
        XCTAssertFalse(RGB(r: 0, g: 0, b: 1).wantsDarkText)    // blue
        XCTAssertFalse(RGB(r: 0.8, g: 0, b: 0).wantsDarkText)  // red
        XCTAssertFalse(RGB.black.wantsDarkText)
    }

    func testContentFromAnOlderBuildStillDecodes() throws {
        // A leftover activity from the previous build has no `lines` / `background` keys.
        let old = #"{"title":"Song","artist":"Artist","currentLine":"Line","isPlaying":true}"#
        let state = try JSONDecoder().decode(LyricsActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNil(state.lines)
        XCTAssertEqual(state.currentLine, "Line")
    }

    func testIdenticalStateIsNeverRepushed() {
        let state = LyricsActivityAttributes.ContentState(
            title: "Song",
            artist: "Artist",
            currentLine: "Line",
            nextLine: nil,
            isPlaying: true
        )
        XCTAssertFalse(LiveActivityController.shouldPush(
            state: state,
            lastState: state
        ))
        XCTAssertTrue(LiveActivityController.shouldPush(
            state: state,
            lastState: nil
        ))
    }
}
