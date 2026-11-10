import Foundation

/// Maps a playback position to the current lyric line. Pure, stateless computation —
/// this is the heart of the product and the most heavily tested piece.
///
/// The car-display problem: ActivityKit throttles Live Activity pushes (~16s), so the
/// widget can't be told "highlight line N" in real time. Instead we push a *playback
/// anchor* (position at wall-clock T) plus the lyric lines, and the widget re-derives the
/// current line locally from the clock. `SyncEngine` is that derivation, used both in-app
/// and in the widget.
public struct SyncEngine: Sendable {
    /// User-tunable offset in ms. Positive = show lyrics earlier (compensates display lag).
    public var userOffsetMs: Int

    public init(userOffsetMs: Int = 0) {
        self.userOffsetMs = userOffsetMs
    }

    /// Effective position after applying LRC file offset and the user's sync knob.
    /// LRC `[offset:]` is defined as "positive shifts lyrics *later*", so we subtract it
    /// from the position clock; the user knob shifts lyrics *earlier*, so we add it.
    func adjustedPosition(_ positionMs: Int, fileOffsetMs: Int) -> Int {
        positionMs + userOffsetMs - fileOffsetMs
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

    /// A window of lines centered on the current one — what the widget renders.
    /// Returns the current index (relative to `lines`) and the slice `[before ... after]`.
    public struct Window: Equatable, Sendable {
        public var currentIndex: Int?          // index into original `lines`, nil if pre-song
        public var lines: [LyricsLine]         // the slice to display
        public var highlightOffset: Int?       // index of current line *within* `lines`
    }

    public func window(in lyrics: TimedLyrics, positionMs: Int, before: Int = 1, after: Int = 3) -> Window {
        let all = lyrics.lines
        guard !all.isEmpty else { return Window(currentIndex: nil, lines: [], highlightOffset: nil) }
        let cur = currentIndex(in: lyrics, positionMs: positionMs)
        let center = cur ?? 0
        let start = max(0, center - before)
        let end = min(all.count - 1, center + after)
        let slice = Array(all[start...end])
        let highlight: Int? = cur.map { $0 - start }
        return Window(currentIndex: cur, lines: slice, highlightOffset: highlight)
    }

    /// Milliseconds until the next line change from `positionMs` (for scheduling a UI tick).
    /// Nil if there is no next line. Never negative.
    public func msUntilNextLine(lines: [LyricsLine], positionMs: Int, fileOffsetMs: Int = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let pos = adjustedPosition(positionMs, fileOffsetMs: fileOffsetMs)
        for line in lines where line.timeMs > pos {
            return line.timeMs - pos
        }
        return nil
    }
}
