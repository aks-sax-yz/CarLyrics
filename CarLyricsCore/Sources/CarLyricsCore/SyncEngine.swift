import Foundation

/// Maps a playback position to the current lyric line. Pure, stateless computation — the app
/// runs it every tick and pushes the resulting line to the Live Activity (the widget only draws).
public struct SyncEngine: Sendable {
    /// User-tunable offset in ms. Positive = show lyrics earlier (compensates display lag).
    public var userOffsetMs: Int

    public init(userOffsetMs: Int = 0) {
        self.userOffsetMs = userOffsetMs
    }

    /// Effective position after the LRC file offset and the user's sync knob. Both follow the LRC
    /// spec's direction — positive makes lyrics appear sooner — so both add to the clock.
    func adjustedPosition(_ positionMs: Int, fileOffsetMs: Int) -> Int {
        positionMs + userOffsetMs + fileOffsetMs
    }

    /// Index of the line that should be highlighted at `positionMs`, or nil if playback is
    /// before the first line. `lines` must be sorted ascending by `timeMs`.
    public func currentIndex(lines: [LyricsLine], positionMs: Int, fileOffsetMs: Int = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let pos = adjustedPosition(positionMs, fileOffsetMs: fileOffsetMs)
        if pos < lines[0].timeMs { return nil }

        // Binary search for the last line with timeMs <= pos.
        var lo = 0
        var hi = lines.count - 1
        var found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timeMs <= pos {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    /// Convenience over `TimedLyrics`, applying its embedded file offset.
    public func currentIndex(in lyrics: TimedLyrics, positionMs: Int) -> Int? {
        currentIndex(lines: lyrics.lines, positionMs: positionMs, fileOffsetMs: lyrics.offsetMs)
    }
}
