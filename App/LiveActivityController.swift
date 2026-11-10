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
        var shortID: String { String(activity.id.prefix(6)) }
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
    /// The current activity was requested by this process and the app hasn't left the
    /// foreground since — nothing to refresh. Adopted leftovers and backgrounded ones aren't.
    private var boxIsFresh = false
    /// Freeze diagnostics: does the system's copy of the content match our last push, how long
    /// pushes take, and why the last request failed (logged once per distinct error).
    private var systemHasLatest = true
    private var behindStreak = 0
    private var maxPushLatency: TimeInterval = 0
    private var lastRequestError: String?

    private static let staleInterval: TimeInterval = 20
    private static let attemptsKey = "diagnostics.activityUpdateAttempts"
    private static let lastAttemptKey = "diagnostics.lastActivityUpdateAttempt"

    var updateAttempts: Int { UserDefaults.standard.integer(forKey: Self.attemptsKey) }
    var lastUpdateAttempt: Date? { UserDefaults.standard.object(forKey: Self.lastAttemptKey) as? Date }

    /// One line for the in-app diagnostics and the event log, e.g. `active a1b2c3 sys=ok n=1 max=0.1s`.
    /// When the widget looks frozen: `sys=ok` + `active` → iOS accepted the update but didn't draw
    /// it; `sys=BEHIND` → iOS is dropping updates; `ended`/`dismissed` → iOS killed the activity.
    var healthSummary: String {
        let count = Activity<LyricsActivityAttributes>.activities.count
        guard let box else { return "none n=\(count) \(lastRequestError ?? "")" }
        return "\(box.activity.activityState) \(box.shortID) sys=\(systemHasLatest ? "ok" : "BEHIND") n=\(count) max=\(String(format: "%.1f", maxPushLatency))s"
    }

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

    /// Live Activities survive app termination. On the first call after launch, adopt one
    /// leftover (a background relaunch can't request a new one, so adopting keeps a widget) and
    /// end any extras. Reaching the foreground then swaps the adopted one for a fresh activity
    /// (`restart()`): a leftover that had frozen stays frozen, which is why the widget used to
    /// need clearing by hand before a relaunch helped.
    private func reconcile() {
        guard !reconciled else { return }
        reconciled = true
        for activity in Activity<LyricsActivityAttributes>.activities {
            let leftover = ActivityBox(activity)
            if box == nil {
                box = leftover
                EventLog.log("activity \(leftover.shortID) leftover \(activity.activityState) adopted")
                observe(leftover)
            } else {
                EventLog.log("activity \(leftover.shortID) extra leftover → ending")
                Task { await leftover.end() }
            }
        }
    }

    /// Ensure the single session-wide activity exists. We reuse one activity across all songs —
    /// `update()` carries the new title/artist/lines — because a backgrounded app can update an
    /// activity but CANNOT start one, so re-requesting on song change would drop the widget on
    /// CarPlay. Recreate only when it's genuinely gone (that request succeeds only in foreground).
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
            let fresh = ActivityBox(activity)
            box = fresh
            boxIsFresh = true
            recordAttempt(at: now)
            lastState = initial
            systemHasLatest = true
            behindStreak = 0
            maxPushLatency = 0
            lastRequestError = nil
            EventLog.log("activity \(fresh.shortID) requested")
            observe(fresh)
        } catch {
            box = nil
            let message = "\(error)"
            if message != lastRequestError {
                lastRequestError = message
                EventLog.log("activity request failed: \(message)")
            }
        }
    }

    func appEnteredBackground() { boxIsFresh = false }

    /// Swap in a fresh activity while the app is in the foreground (the only time iOS grants
    /// one — a background request fails with `visibility`). Called whenever the app becomes
    /// active; replaces only an adopted leftover or one that has been through the background, so
    /// opening the app recovers a frozen widget. The old one is ended only once the new one exists.
    func restart() async {
        reconcile() // adopt a leftover first, so it gets replaced rather than kept
        guard let old = box, !boxIsFresh else { return }
        let state = lastState ?? old.activity.content.state
        box = nil
        await ensureActivity(songId: old.songId, initial: state)
        guard box != nil else { box = old; return } // no fresh one granted — keep the old
        EventLog.log("activity \(old.shortID) replaced on foreground")
        await old.end()
    }

    func update(_ state: LyricsActivityAttributes.ContentState) async {
        let now = Date()
        guard let box, box.isLive,
              Self.shouldPush(state: state, lastState: lastState)
        else { return }
        recordAttempt(at: now)
        await box.update(content(for: state, now: now))
        maxPushLatency = max(maxPushLatency, Date().timeIntervalSince(now))
        lastState = state
        // The local `Activity.content` refreshes a beat after `update` returns, so one mismatch is
        // normal (seen in the simulator). Only 3 pushes in a row unacknowledged means iOS is
        // really dropping them.
        behindStreak = box.activity.content.state == state ? 0 : behindStreak + 1
        let accepted = behindStreak < 3
        if accepted != systemHasLatest {
            EventLog.log("activity \(box.shortID) system copy \(accepted ? "caught up" : "fell BEHIND our pushes")")
        }
        systemHasLatest = accepted
    }

    func endCurrent() async {
        guard let box else { return }
        self.box = nil
        lastState = nil
        EventLog.log("activity \(box.shortID) ended by app")
        await box.end()
    }

    func resetDiagnostics() {
        UserDefaults.standard.removeObject(forKey: Self.attemptsKey)
        UserDefaults.standard.removeObject(forKey: Self.lastAttemptKey)
    }

    /// Log every lifecycle change the system makes (e.g. ending or dismissing it behind our back).
    private func observe(_ box: ActivityBox) {
        Task {
            for await state in box.activity.activityStateUpdates {
                EventLog.log("activity \(box.shortID) → \(state)")
            }
        }
    }

    private func recordAttempt(at date: Date) {
        UserDefaults.standard.set(updateAttempts + 1, forKey: Self.attemptsKey)
        UserDefaults.standard.set(date, forKey: Self.lastAttemptKey)
    }
}
