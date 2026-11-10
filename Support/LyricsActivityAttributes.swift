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
    }

    /// Stable per-song identity so the system coalesces same-song updates.
    var songId: String
}
