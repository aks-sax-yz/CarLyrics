import XCTest
@testable import CarLyrics

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
