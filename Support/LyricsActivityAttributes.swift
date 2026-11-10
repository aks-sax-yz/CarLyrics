import Foundation
import ActivityKit

/// Shared between the app (which pushes updates) and the widget extension (which renders).
/// This file is compiled into BOTH targets — keep it dependency-light.
///
/// The app owns all sync computation (it has the Spotify poller, the full lyrics, and the
/// SyncEngine). It pushes a ready-to-render `ContentState` on each line change. The widget
/// just draws it — this is the only design that survives ActivityKit's push throttling.
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        /// The current lyric line (highlighted). Empty string during instrumental gaps.
        var currentLine: String
        /// The upcoming line, shown dimmed for read-ahead. Nil at end of song.
        var nextLine: String?
        var isPlaying: Bool
        /// Song length; nil when the source doesn't know it (Listen/Shazam) — the time row hides.
        var durationMs: Int? = nil
        /// Playing: the wall-clock moment the song started (now − position). The widget's
        /// `Text(timerInterval:)` / `ProgressView(timerInterval:)` then tick live with no push per
        /// second. Held steady by the app, so it only changes on seek / song change.
        var songStart: Date? = nil
        /// Paused: the frozen position (whole seconds), shown statically.
        var pausedPositionMs: Int? = nil
    }

    /// The song the activity was started for. Informational only: one activity is reused across
    /// songs (ContentState carries the current title), because a backgrounded app can't start one.
    var songId: String
}
