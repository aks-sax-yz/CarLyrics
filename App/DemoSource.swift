#if targetEnvironment(simulator)
import Foundation
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
        NowPlayingTrack(title: "Bohemian Rhapsody", artist: "Queen", durationMs: 354_000, source: .appleMusic),
        NowPlayingTrack(title: "Billie Jean", artist: "Michael Jackson", durationMs: 294_000, source: .appleMusic),
        NowPlayingTrack(title: "Hotel California", artist: "Eagles", durationMs: 391_000, source: .appleMusic),
        NowPlayingTrack(title: "Blinding Lights", artist: "The Weeknd", durationMs: 200_000, source: .appleMusic),
        NowPlayingTrack(title: "Shape of You", artist: "Ed Sheeran", durationMs: 233_000, source: .appleMusic),
    ]
    private let start = Date()
    private static let sliceMs = 100_000

    func sampleNow() -> PlaybackState {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let track = songs[(elapsed / Self.sliceMs) % songs.count]
        return PlaybackState(track: track, positionMs: 20_000 + elapsed % Self.sliceMs, isPlaying: true, sampledAt: Date())
    }
}
#endif
