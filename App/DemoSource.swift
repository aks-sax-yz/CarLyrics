#if targetEnvironment(simulator)
import Foundation
import UIKit
import CarLyricsCore

/// Simulator-only playback source. The iOS Simulator has no Music app, so `systemMusicPlayer`
/// reads nothing there — this feeds real, well-known tracks (LRCLIB has synced lyrics for them)
/// with a wall-clock-advancing position so the whole pipeline (fetch → parse → sync → UI →
/// Live Activity) can be exercised without a device. Compiled out of device builds entirely.
///
/// Each song plays a 100s slice (from 20s in, past most intros) and then the next one starts,
/// so the song changes — after 3–4 of which the widget used to freeze on device — come every
/// ~2 minutes instead of every ~4.
@MainActor
final class DemoSource {
    private let songs = [
        // Word-timed, like Apple Music's lyrics (seeded into the cache below): the word sweep + held-word swell.
        DemoSource.wordDemo,
        // Long lines that wrap to two rows (karaoke's per-row sweep).
        NowPlayingTrack(title: "I Write Sins Not Tragedies", artist: "Panic! At The Disco", durationMs: 187_000, source: .appleMusic),
        NowPlayingTrack(title: "Bohemian Rhapsody", artist: "Queen", durationMs: 354_000, source: .appleMusic),
        NowPlayingTrack(title: "Billie Jean", artist: "Michael Jackson", durationMs: 294_000, source: .appleMusic),
        NowPlayingTrack(title: "Hotel California", artist: "Eagles", durationMs: 391_000, source: .appleMusic),
        NowPlayingTrack(title: "Blinding Lights", artist: "The Weeknd", durationMs: 200_000, source: .appleMusic),
        NowPlayingTrack(title: "Shape of You", artist: "Ed Sheeran", durationMs: 233_000, source: .appleMusic),
    ]
    private let start = Date()

    static let wordDemo = NowPlayingTrack(title: "Word by Word", artist: "Car Lyrics Demo", durationMs: 130_000, source: .appleMusic)

    init() {
        // Lines from 20s (where each demo slice starts), each word timed; "love" and "night" are held.
        func line(_ at: Int, _ words: [(String, Int, Int)]) -> LyricsLine {
            let w = words.map { LyricsLine.Word(timeMs: at + $0.1, text: $0.0, endMs: at + $0.2) }
            return LyricsLine(timeMs: at, text: w.map(\.text).joined(separator: " "), words: w, endMs: w.last?.endMs)
        }
        var lines: [LyricsLine] = []
        for round in 0..<6 {
            let t = 20_000 + round * 16_000
            lines.append(line(t, [("Driving", 0, 500), ("through", 500, 900), ("the", 900, 1100), ("city", 1100, 1700), ("lights", 1700, 2600)]))
            lines.append(line(t + 4_000, [("All", 0, 300), ("I", 300, 500), ("want", 500, 900), ("is", 900, 1100), ("love", 1100, 3400)]))
            lines.append(line(t + 8_000, [("Sing", 0, 400), ("it", 400, 600), ("back", 600, 1000), ("to", 1000, 1200), ("me", 1200, 1900),
                                          ("one", 1900, 2300), ("more", 2300, 2700), ("time", 2700, 3300)]))
            lines.append(line(t + 12_000, [("Into", 0, 500), ("the", 500, 700), ("night", 700, 3000)]))
        }
        var lyrics = TimedLyrics(lines: lines, isSynced: true)
        lyrics.source = "apple syllable demo"
        LyricsStore.caches().save(lyrics, for: Self.wordDemo)
    }

    /// Square stand-in artwork, so the simulator shows the lyrics screen as it looks with real
    /// Apple Music art (the blurred background is where layout bugs hide).
    static let artwork = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { ctx in
        let colors = [UIColor.systemPink.cgColor, UIColor.systemOrange.cgColor, UIColor.systemIndigo.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.5, 1])!
        ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
    }
    private static let sliceMs = 100_000

    func sampleNow() -> PlaybackState {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let track = songs[(elapsed / Self.sliceMs) % songs.count]
        return PlaybackState(track: track, positionMs: 20_000 + elapsed % Self.sliceMs, isPlaying: true, sampledAt: Date())
    }
}
#endif
