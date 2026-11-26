import Foundation

/// A track identified from one of the playback sources.
public struct NowPlayingTrack: Equatable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case appleMusic
        case spotify
        case youtubeMusic
    }

    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int?
    public var source: Source
    /// The service's own ID: Apple Music's catalog ID (`playbackStoreID`, nil for local files),
    /// Spotify's track ID or YouTube's video ID. Asks that service for its lyrics. Not part of `identityKey`.
    public var catalogID: String? = nil
    /// The recording's ISRC (Spotify reports it): finds the same recording on Apple Music, whose
    /// word timing then fits Spotify's audio too.
    public var isrc: String? = nil
    /// Album art to download (Spotify, YouTube Music; Apple Music's comes from MediaPlayer).
    public var artworkURL: String? = nil

    public init(title: String, artist: String, album: String? = nil, durationMs: Int? = nil, source: Source,
                catalogID: String? = nil, isrc: String? = nil, artworkURL: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.source = source
        self.catalogID = catalogID
        self.isrc = isrc
        self.artworkURL = artworkURL
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
        /// When the word stops being sung (Apple's word-timed lyrics); nil = at the next word.
        public var endMs: Int? = nil
        public init(timeMs: Int, text: String, endMs: Int? = nil) {
            self.timeMs = timeMs
            self.text = text
            self.endMs = endMs
        }
    }

    public var timeMs: Int
    public var text: String
    public var words: [Word]?
    /// When the line ends (Apple / Spotify); nil = at the next line.
    public var endMs: Int? = nil

    public init(timeMs: Int, text: String, words: [Word]? = nil, endMs: Int? = nil) {
        self.timeMs = timeMs
        self.text = text
        self.words = words
        self.endMs = endMs
    }
}

/// Parsed lyrics for a track. `lines` is sorted ascending by `timeMs`.
public struct TimedLyrics: Equatable, Codable, Sendable {
    public var lines: [LyricsLine]
    /// False for plain (unsynced) lyrics — every line has timeMs 0 and we can't karaoke.
    public var isSynced: Bool
    /// Global offset in ms from the `[offset:]` LRC tag (positive makes lyrics appear sooner).
    public var offsetMs: Int
    /// Where these came from, for the debug log (e.g. "lrclib get id=… uploads=14 consensus=-120ms").
    public var source: String? = nil

    public init(lines: [LyricsLine], isSynced: Bool, offsetMs: Int = 0) {
        self.lines = lines
        self.isSynced = isSynced
        self.offsetMs = offsetMs
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Apple's offset for the Dolby Atmos ("spatial") recording, from the TTML metadata AppleTTML
    /// notes in `source` ("lyricOffset[spatial]=1115ms"). Positive = lyrics belong later. Blinding
    /// Lights: +1115ms, so on Atmos its stereo-timed words were a second early (Akshat, 2026-11-25).
    public var spatialLyricOffsetMs: Int? {
        guard let source, let r = source.range(of: #"lyricOffset\[spatial\]=(-?\d+)ms"#, options: .regularExpression) else { return nil }
        return Int(source[r].dropFirst("lyricOffset[spatial]=".count).dropLast(2))
    }
}

extension String {
    var lowercasedTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
