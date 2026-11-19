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
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: anchor.addingTimeInterval(0.1)), anchor)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: anchor.addingTimeInterval(-0.2)), anchor)
        // A stale start reading as small as 0.4s is corrected; lyrics are scheduled from this anchor.
        let corrected = anchor.addingTimeInterval(0.4)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: corrected), corrected)
        // A seek / new song moves it.
        let seek = anchor.addingTimeInterval(-30)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: anchor, candidate: seek), seek)
        XCTAssertEqual(NowPlayingCoordinator.steadySongStart(previous: nil, candidate: seek), seek)
    }

    func testLyricWindowCarriesUpcomingLinesOnTheWallClock() {
        let lyrics = TimedLyrics(lines: (0..<30).map { LyricsLine(timeMs: 10_000 + $0 * 1_000, text: "L\($0)") },
                                 isSynced: true, offsetMs: 200)
        let start = Date(timeIntervalSince1970: 1_000)
        // Intro: ♪ from song start, then lines 0–11 at songStart + time − (user + file offset).
        let intro = NowPlayingCoordinator.lyricWindow(lyrics, index: nil, songStart: start, userOffsetMs: 800)
        XCTAssertEqual(intro.count, 13)
        XCTAssertEqual(intro[0], .init(text: "", at: start))
        XCTAssertEqual(intro[1], .init(text: "L0", at: start.addingTimeInterval(9)))
        // The window moves only every 4 lines, so the pushed state doesn't change per line.
        XCTAssertEqual(NowPlayingCoordinator.lyricWindow(lyrics, index: 8, songStart: start, userOffsetMs: 800),
                       NowPlayingCoordinator.lyricWindow(lyrics, index: 11, songStart: start, userOffsetMs: 800))
        XCTAssertEqual(NowPlayingCoordinator.lyricWindow(lyrics, index: 8, songStart: start, userOffsetMs: 800).count, 12)
        let end = NowPlayingCoordinator.lyricWindow(lyrics, index: 27, songStart: start, userOffsetMs: 800)
        XCTAssertEqual(end.map(\.text), ["L24", "L25", "L26", "L27", "L28", "L29"])
    }

    func testLongLineIsCutIntoPartsThatFitInsteadOfShrinking() {
        let font = LyricFit.font(20)
        // Room for exactly two 4-letter words per row (letters differ in width, so the widest pair).
        let width = ["aaaa bbbb", "cccc dddd", "eeee ffff", "gggg hhhh"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()! / 0.95 + 1
        let long = "aaaa bbbb cccc dddd eeee ffff gggg hhhh" // 4 rows at this width
        XCTAssertEqual(LyricFit.parts(of: long, width: width, font: font, rows: 2),
                       ["aaaa bbbb cccc dddd", "eeee ffff gggg hhhh"])
        XCTAssertEqual(LyricFit.parts(of: long, width: width, font: font, rows: 1).count, 4) // karaoke: one row each
        XCTAssertEqual(LyricFit.parts(of: "aaaa bbbb", width: width, font: font, rows: 2), ["aaaa bbbb"])

        let start = Date(timeIntervalSince1970: 1_000)
        let lines: [LyricsActivityAttributes.TimedLine] = [.init(text: long, at: start), .init(text: "short", at: start.addingTimeInterval(2))]
        let split = LyricFit.split(lines, width: width, font: font, rows: 2)
        XCTAssertEqual(split.map(\.text), ["aaaa bbbb cccc dddd", "eeee ffff gggg hhhh", "short"])
        // The second part starts 20/39 of the way to the next line.
        XCTAssertEqual(split[1].at.timeIntervalSince(start), 2 * 20 / 39, accuracy: 0.001)
        XCTAssertEqual(split[2].at, start.addingTimeInterval(2))
        // Read-ahead: during part 0 the next row shows part 1.
        XCTAssertEqual(LyricFit.ahead(split, by: 1).map(\.text), ["eeee ffff gggg hhhh", "short", ""])
    }

    func testWidgetTimelineHasAnEntryPerLineFromTheCurrentOne() {
        let start = Date(timeIntervalSince1970: 1_000)
        let feed = WidgetFeed(title: "Song", artist: "Artist",
                              lines: (0..<5).map { .init(text: "L\($0)", at: start.addingTimeInterval(Double($0))) })
        let moments = feed.timeline(now: start.addingTimeInterval(2.5), width: 300) // L2 playing
        XCTAssertEqual(moments.map(\.date), [2.5, 3, 4].map { start.addingTimeInterval($0) })
        XCTAssertEqual(moments.map(\.current), ["L2", "L3", "L4"])
        XCTAssertEqual(moments[0].next, ["L3", "L4"])
        XCTAssertEqual(moments[2].next, [])
        // A line too long for two rows becomes two entries, so its text keeps the same size.
        let font = LyricFit.font(WidgetFeed.bigSize)
        let narrow = ["aaaa bbbb", "cccc dddd", "eeee ffff", "gggg hhhh"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()! / 0.95 + 1
        let long = WidgetFeed(title: "Song", artist: "Artist",
                              lines: [.init(text: "aaaa bbbb cccc dddd eeee ffff gggg hhhh", at: start),
                                      .init(text: "end", at: start.addingTimeInterval(4))])
        XCTAssertEqual(long.timeline(now: start, width: narrow).map(\.current),
                       ["aaaa bbbb cccc dddd", "eeee ffff gggg hhhh", "end"])
        // Paused: one entry, the line and what's next.
        let paused = WidgetFeed(title: "Song", artist: "Artist", currentLine: "now", nextLines: ["a", "b", "c"])
        XCTAssertEqual(paused.timeline(now: start, width: 300), [.init(date: start, current: "now", next: ["a", "b"])])
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
