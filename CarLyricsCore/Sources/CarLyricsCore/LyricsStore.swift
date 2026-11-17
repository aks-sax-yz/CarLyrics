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

    /// A song's lyrics stay cached for 30 days after it was last played; each play restarts the
    /// clock (the file's modification date is the "last played" stamp). The folder is in Caches, so
    /// iOS may still clear it under storage pressure.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    public func load(key: String, now: Date = Date()) -> TimedLyrics? {
        let url = fileURL(for: key)
        let fm = FileManager.default
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        if now.timeIntervalSince(modified) > Self.lifetime {
            try? fm.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let lyrics = try? JSONDecoder().decode(TimedLyrics.self, from: data) else { return nil }
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path) // played again: 30 more days
        return lyrics
    }

    /// Delete everything not played for 30 days (run at launch, so unplayed songs don't linger).
    public func pruneExpired(now: Date = Date()) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.lifetime { try? fm.removeItem(at: url) }
        }
    }

    public func save(_ lyrics: TimedLyrics, key: String) {
        guard let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Bump when what's cached changes, so stale entries are skipped. v2: the original script
    /// (romanized on load), not v1's baked-in ICU romanization. v3: consensus timing applied.
    /// v4: per-line consensus and translations stripped.
    static let version = "v4"

    public func load(for track: NowPlayingTrack) -> TimedLyrics? {
        load(key: "\(Self.version)|\(track.identityKey)")
    }

    public func save(_ lyrics: TimedLyrics, for track: NowPlayingTrack) {
        save(lyrics, key: "\(Self.version)|\(track.identityKey)")
    }
}
