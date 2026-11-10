import Foundation

/// A track identified from one of the playback sources.
public struct NowPlayingTrack: Equatable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case appleMusic
        case spotify
        case shazam
    }

    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int?
    public var source: Source

    public init(title: String, artist: String, album: String? = nil, durationMs: Int? = nil, source: Source) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.source = source
    }

    /// Stable identity for cache keys and change detection. Deliberately ignores `source`
    /// so the same song from Apple Music and Spotify shares a lyrics cache entry.
    public var identityKey: String {
        "\(artist.lowercasedTrimmed)|\(title.lowercasedTrimmed)|\((durationMs ?? 0) / 1000)"
    }

    /// True when this is a different song than `other` (ignores position/source).
    public func isDifferentSong(from other: NowPlayingTrack?) -> Bool {
        guard let other else { return true }
        return title.lowercasedTrimmed != other.title.lowercasedTrimmed
            || artist.lowercasedTrimmed != other.artist.lowercasedTrimmed
    }
}

/// A snapshot of what is playing, with enough info to extrapolate position between samples.
public struct PlaybackState: Equatable, Sendable {
    public var track: NowPlayingTrack
    /// Playback position in ms *at the instant `sampledAt`*.
    public var positionMs: Int
    public var isPlaying: Bool
    /// Wall-clock time the position was measured. Used to extrapolate forward.
    public var sampledAt: Date

    public init(track: NowPlayingTrack, positionMs: Int, isPlaying: Bool, sampledAt: Date) {
        self.track = track
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.sampledAt = sampledAt
    }

    /// Position extrapolated to `now`. If paused, position is frozen at the last sample.
    public func extrapolatedPositionMs(now: Date) -> Int {
        guard isPlaying else { return positionMs }
        let elapsed = Int(now.timeIntervalSince(sampledAt) * 1000)
        let pos = positionMs + max(0, elapsed)
        if let dur = track.durationMs { return min(pos, dur) }
        return pos
    }
}

/// One line of lyrics with a start time; optionally carries word-level timings (enhanced LRC).
public struct LyricsLine: Equatable, Codable, Sendable {
    public struct Word: Equatable, Codable, Sendable {
        public var timeMs: Int
        public var text: String
        public init(timeMs: Int, text: String) {
            self.timeMs = timeMs
            self.text = text
        }
    }

    public var timeMs: Int
    public var text: String
    public var words: [Word]?

    public init(timeMs: Int, text: String, words: [Word]? = nil) {
        self.timeMs = timeMs
        self.text = text
        self.words = words
    }
}

/// Parsed lyrics for a track. `lines` is sorted ascending by `timeMs`.
public struct TimedLyrics: Equatable, Codable, Sendable {
    public var lines: [LyricsLine]
    /// False for plain (unsynced) lyrics — every line has timeMs 0 and we can't karaoke.
    public var isSynced: Bool
    /// Global offset in ms from the `[offset:]` LRC tag (positive makes lyrics appear sooner).
    public var offsetMs: Int

    public init(lines: [LyricsLine], isSynced: Bool, offsetMs: Int = 0) {
        self.lines = lines
        self.isSynced = isSynced
        self.offsetMs = offsetMs
    }

    public var isEmpty: Bool { lines.isEmpty }
}

extension String {
    var lowercasedTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
