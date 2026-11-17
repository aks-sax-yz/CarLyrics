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
        /// Playing synced lyrics: a window of upcoming lines with wall-clock start times. The widget
        /// switches between them on iOS's own clock (like the song timer), because iOS throttles
        /// per-line pushes to one every 10–30s on CarPlay / screen off. Nil/empty → show `currentLine`.
        /// Optional so content saved by an older build (no `lines` key) still decodes.
        var lines: [TimedLine]? = nil
        /// Lyrics background: the user's solid pick or the album art's average colour, or nil for
        /// the system's glass. The widget picks black or white text to suit it.
        var background: RGB? = .black
        /// How lines switch; nil (older builds) = instant.
        var transition: Transition? = nil
    }

    /// Line-switch styles. Instant/Wipe/Karaoke switch on iOS's clock (only timer views animate in
    /// a Live Activity, so they're left → right sweeps). Morph is SwiftUI's text morph, which iOS
    /// only plays on a pushed update, so it pushes per line and lags wherever iOS throttles those
    /// (CarPlay / screen off: 10–30s on the 2026-11-14 drive).
    enum Transition: String, Codable, CaseIterable, Identifiable {
        case instant, wipe, karaoke, morph
        var id: String { rawValue }
        var label: String {
            switch self {
            case .instant: "Instant"
            case .wipe: "Wipe"
            case .karaoke: "Karaoke"
            case .morph: "Morph"
            }
        }
    }

    struct TimedLine: Codable, Hashable {
        var text: String
        var at: Date
    }

    struct RGB: Codable, Hashable {
        var r, g, b: Double
        static let black = RGB(r: 0, g: 0, b: 0)

        /// True when black text has more contrast than white: WCAG relative luminance above 0.179,
        /// the point where the two contrast ratios are equal.
        var wantsDarkText: Bool {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) > 0.179
        }
    }

    /// The song the activity was started for. Informational only: one activity is reused across
    /// songs (ContentState carries the current title), because a backgrounded app can't start one.
    var songId: String
}
