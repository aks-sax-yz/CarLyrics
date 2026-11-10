import Foundation
import CoreLocation

/// Keeps the app running in the background so the coordinator's 1s loop keeps pushing Live
/// Activity updates (advancing lyric lines) while the phone is locked or on CarPlay.
///
/// Uses continuous Core Location updates — the one background grant that (a) runs *indefinitely*
/// (unlike silent audio, which iOS treats as inactive and suspends after ~10s) and (b) is
/// independent of the audio session, so it survives CarPlay connect/disconnect (which killed the
/// audio-based keep-alive). We don't use the location itself; lowest accuracy is enough to hold
/// the background assertion while sparing the battery. Paired with `UIBackgroundModes: [location]`
/// and the `NSLocation…AlwaysAndWhenInUse` usage strings.
///
/// `CLBackgroundActivitySession` keeps When-In-Use authorization effective after backgrounding.
@MainActor
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case starting
        case active
        case permissionRequired
        case failed(String)
    }

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var running = false
    private(set) var lastLocationUpdate: Date?
    private(set) var lastError: String?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var status: Status {
        Self.currentStatus(
            authorization: authorizationStatus,
            hasBackgroundSession: backgroundSession != nil,
            lastLocationUpdate: lastLocationUpdate,
            lastError: lastError,
            now: Date()
        )
    }

    nonisolated static func currentStatus(
        authorization: CLAuthorizationStatus,
        hasBackgroundSession: Bool,
        lastLocationUpdate: Date?,
        lastError: String?,
        now: Date
    ) -> Status {
        if let lastError { return .failed(lastError) }
        switch authorization {
        case .denied, .restricted: return .permissionRequired
        case .notDetermined: return .starting
        default:
            return isEffective(
                authorization: authorization,
                hasBackgroundSession: hasBackgroundSession,
                lastLocationUpdate: lastLocationUpdate,
                now: now
            ) ? .active : .starting
        }
    }

    nonisolated static func isEffective(
        authorization: CLAuthorizationStatus,
        hasBackgroundSession: Bool,
        lastLocationUpdate: Date?,
        now: Date
    ) -> Bool {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways,
              hasBackgroundSession,
              let lastLocationUpdate
        else { return false }
        return now.timeIntervalSince(lastLocationUpdate) <= 60
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !running else { return }
        running = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        startLocationUpdatesIfAuthorized()
    }

    /// A background-created session can only rejoin an existing grant. Recreate it whenever the
    /// app becomes active so Settings permission changes and system relaunches get a foreground grant.
    func appBecameActive() {
        guard running else { return }
        backgroundSession?.invalidate()
        backgroundSession = nil
        startLocationUpdatesIfAuthorized()
    }

    private func startLocationUpdatesIfAuthorized() {
        guard running,
              manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways
        else { return }
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.startLocationUpdatesIfAuthorized()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.lastLocationUpdate = Date()
            self?.lastError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.lastError = message
        }
    }
}
