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
