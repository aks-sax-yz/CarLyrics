import Foundation

/// On-disk cache of parsed lyrics keyed by track identity. Foundation-only so it works in
/// the app, the widget extension, and macOS tests. Stores JSON in a directory (defaults to
/// caches); pass an App Group container URL in the app so the widget can read what the app
/// fetched.
public struct LyricsStore: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Convenience: a store in the app's caches directory (for tests / standalone use).
    public static func caches() -> LyricsStore {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return LyricsStore(directory: base.appendingPathComponent("CarLyricsCache", isDirectory: true))
    }

    private func fileURL(for key: String) -> URL {
        // Hash the identity key to a filesystem-safe filename.
        let safe = key.unicodeScalars.reduce(into: "") { acc, scalar in
            acc.append(scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) ? Character(scalar) : "_")
        }
        let hashed = String(UInt64(bitPattern: Int64(key.hashValue)))
        return directory.appendingPathComponent("\(safe.prefix(40))_\(hashed).json")
    }

    public func load(key: String) -> TimedLyrics? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TimedLyrics.self, from: data)
    }

    public func save(_ lyrics: TimedLyrics, key: String) {
        guard let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    public func load(for track: NowPlayingTrack) -> TimedLyrics? {
        load(key: track.identityKey)
    }

    public func save(_ lyrics: TimedLyrics, for track: NowPlayingTrack) {
        save(lyrics, key: track.identityKey)
    }
}
