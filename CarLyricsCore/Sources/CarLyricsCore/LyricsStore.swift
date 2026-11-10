import Foundation
import CryptoKit

/// On-disk cache of parsed lyrics keyed by track identity, stored as JSON files in a directory.
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

    /// SHA256 of the key: filesystem-safe and identical across launches. (`hashValue` is seeded
    /// per process, which made every relaunch miss the cache.)
    func fileURL(for key: String) -> URL {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).json")
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
