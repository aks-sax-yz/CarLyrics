import XCTest
@testable import CarLyricsCore

final class SyncEngineTests: XCTestCase {

    private func lyrics(_ times: [Int]) -> TimedLyrics {
        TimedLyrics(lines: times.map { LyricsLine(timeMs: $0, text: "line@\($0)") }, isSynced: true)
    }

    func testBeforeFirstLineReturnsNil() {
        let engine = SyncEngine()
        let l = lyrics([10_000, 20_000, 30_000])
        XCTAssertNil(engine.currentIndex(in: l, positionMs: 5_000))
    }

    func testExactBoundaryIsInclusive() {
        let engine = SyncEngine()
        let l = lyrics([10_000, 20_000, 30_000])
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 10_000), 0)
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 20_000), 1)
    }

    func testMidLineHoldsPreviousIndex() {
        let engine = SyncEngine()
        let l = lyrics([10_000, 20_000, 30_000])
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 15_000), 0)
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 29_999), 1)
    }

    func testPastLastLineReturnsLast() {
        let engine = SyncEngine()
        let l = lyrics([10_000, 20_000, 30_000])
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 999_999), 2)
    }

    func testBinarySearchAcrossManyLines() {
        // 1000 lines every 1000ms; brute-force oracle must agree with binary search.
        let times = (0..<1000).map { $0 * 1000 }
        let l = lyrics(times)
        let engine = SyncEngine()
        for pos in stride(from: 0, to: 1_000_000, by: 137) {
            let expected = times.lastIndex(where: { $0 <= pos })
            XCTAssertEqual(engine.currentIndex(in: l, positionMs: pos), expected, "pos=\(pos)")
        }
    }

    func testUserOffsetShiftsEarlier() {
        // +1000ms user offset => lyrics appear 1s sooner => at pos 9000 we're already on line 0.
        let engine = SyncEngine(userOffsetMs: 1_000)
        let l = lyrics([10_000, 20_000])
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 9_000), 0)
        XCTAssertNil(SyncEngine().currentIndex(in: l, positionMs: 9_000))
    }

    func testFileOffsetShiftsEarlier() {
        // LRC spec: [offset:+1000] => lyrics appear 1s SOONER => at pos 9000 line 0 is already up.
        let engine = SyncEngine()
        let l = TimedLyrics(lines: [LyricsLine(timeMs: 10_000, text: "x")], isSynced: true, offsetMs: 1_000)
        XCTAssertNil(engine.currentIndex(in: l, positionMs: 8_000))
        XCTAssertEqual(engine.currentIndex(in: l, positionMs: 9_000), 0)
    }

    func testExtrapolatedPosition() {
        let base = Date(timeIntervalSince1970: 1_000)
        let track = NowPlayingTrack(title: "t", artist: "a", durationMs: 200_000, source: .spotify)
        let state = PlaybackState(track: track, positionMs: 30_000, isPlaying: true, sampledAt: base)
        // 2 seconds later, position advanced 2000ms.
        XCTAssertEqual(state.extrapolatedPositionMs(now: base.addingTimeInterval(2)), 32_000)
        // Paused: frozen.
        var paused = state; paused.isPlaying = false
        XCTAssertEqual(paused.extrapolatedPositionMs(now: base.addingTimeInterval(10)), 30_000)
        // Never exceeds duration.
        XCTAssertEqual(state.extrapolatedPositionMs(now: base.addingTimeInterval(9_999)), 200_000)
    }
}
