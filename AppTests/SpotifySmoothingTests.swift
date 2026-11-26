import XCTest
@testable import CarLyrics

final class SpotifySmoothingTests: XCTestCase {
    func testWobbleIgnoredSeekTakenAtOnce() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var history: [Date] = []
        for d in [0.0, 0.05, -0.04] { _ = NowPlayingCoordinator.smoothedStart(&history, adding: t.addingTimeInterval(d)) }
        // One reading 1.3s off (the 2026-11-25 log's wobble) doesn't move the start.
        XCTAssertEqual(NowPlayingCoordinator.smoothedStart(&history, adding: t.addingTimeInterval(-1.3)).timeIntervalSince(t), 0, accuracy: 0.06)
        // A seek (start 30s earlier) is taken straight away.
        XCTAssertEqual(NowPlayingCoordinator.smoothedStart(&history, adding: t.addingTimeInterval(-30)).timeIntervalSince(t), -30, accuracy: 0.001)
        XCTAssertEqual(history.count, 1)
    }
}
