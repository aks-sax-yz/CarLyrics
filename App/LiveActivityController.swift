import Foundation
import ActivityKit
import CarLyricsCore

/// Starts, updates, and ends the lyrics Live Activity. The coordinator calls `update` on
/// each line change; the system throttles how fast these actually reach the widget, so we
/// only push when the visible content genuinely changes (guarded by `lastState`).
@MainActor
final class LiveActivityController {

    /// ActivityKit's `Activity` is not Sendable in the iOS 26 SDK, but its `update`/`end`
    /// methods are `nonisolated async` and internally thread-safe. This box is the correct,
    /// localized escape hatch: it lets the main actor hand the activity to those methods
    /// without dropping the whole target out of Swift 6 strict concurrency.
    private final class ActivityBox: @unchecked Sendable {
        let activity: Activity<LyricsActivityAttributes>
        init(_ activity: Activity<LyricsActivityAttributes>) { self.activity = activity }
        var songId: String { activity.attributes.songId }
        /// Still on screen? False once the user swipes it away (dismissed) or it's ended.
        var isLive: Bool {
            switch activity.activityState {
            case .active, .stale: return true
            case .dismissed, .ended: return false
            @unknown default: return true
            }
        }
        func update(_ content: ActivityContent<LyricsActivityAttributes.ContentState>) async {
            await activity.update(content)
        }
        func end() async {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private var box: ActivityBox?
    private var lastState: LyricsActivityAttributes.ContentState?
    private var reconciled = false

    private static let staleInterval: TimeInterval = 20
    private static let attemptsKey = "diagnostics.activityUpdateAttempts"
    private static let lastAttemptKey = "diagnostics.lastActivityUpdateAttempt"

    var updateAttempts: Int { UserDefaults.standard.integer(forKey: Self.attemptsKey) }
    var lastUpdateAttempt: Date? { UserDefaults.standard.object(forKey: Self.lastAttemptKey) as? Date }

    nonisolated static func shouldPush(
        state: LyricsActivityAttributes.ContentState,
        lastState: LyricsActivityAttributes.ContentState?
    ) -> Bool {
        state != lastState
    }

    private func content(
        for state: LyricsActivityAttributes.ContentState,
        now: Date = Date()
    ) -> ActivityContent<LyricsActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(Self.staleInterval),
            relevanceScore: state.isPlaying ? 1 : 0
        )
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Live Activities survive app termination. On the first call after launch, adopt an
    /// existing activity for the current song (instead of starting a duplicate) and end any
    /// stale leftovers from a previous run.
    private func reconcile() {
        guard !reconciled else { return }
        reconciled = true
        for activity in Activity<LyricsActivityAttributes>.activities {
            if box == nil {
                box = ActivityBox(activity) // adopt one leftover; content updates handle the rest
            } else {
                let leftover = ActivityBox(activity)
                Task { await leftover.end() }
            }
        }
    }

    /// Ensure the single session-wide activity exists. We reuse one activity across all songs —
    /// `update()` carries the new title/artist/lines — so we only ever `request()` once, while the
    /// app is foreground. A backgrounded app can update an activity but CANNOT start one, so
    /// re-requesting on song change would drop the widget on CarPlay. Recreate only when it's
    /// genuinely gone or the user swiped it away.
    func ensureActivity(songId: String, initial: LyricsActivityAttributes.ContentState) async {
        reconcile()
        if let box, box.isLive { return }
        guard areActivitiesEnabled else { return }
        do {
            let now = Date()
            let activity = try Activity.request(
                attributes: LyricsActivityAttributes(songId: songId),
                content: content(for: initial, now: now),
                pushType: nil
            )
            box = ActivityBox(activity)
            recordAttempt(at: now)
            lastState = initial
        } catch {
            box = nil
        }
    }

    func update(_ state: LyricsActivityAttributes.ContentState) async {
        let now = Date()
        guard let box, box.isLive,
              Self.shouldPush(state: state, lastState: lastState)
        else { return }
        recordAttempt(at: now)
        await box.update(content(for: state, now: now))
        lastState = state
    }

    func endCurrent() async {
        guard let box else { return }
        self.box = nil
        lastState = nil
        await box.end()
    }

    func resetDiagnostics() {
        UserDefaults.standard.removeObject(forKey: Self.attemptsKey)
        UserDefaults.standard.removeObject(forKey: Self.lastAttemptKey)
    }

    private func recordAttempt(at date: Date) {
        UserDefaults.standard.set(updateAttempts + 1, forKey: Self.attemptsKey)
        UserDefaults.standard.set(date, forKey: Self.lastAttemptKey)
    }
}
