#if targetEnvironment(simulator)
import Foundation
import CarLyricsCore

/// Simulator-only playback source. The iOS Simulator has no Music app, so `systemMusicPlayer`
/// reads nothing there — this feeds a real, well-known track (LRCLIB has synced lyrics for it)
/// with a wall-clock-advancing position so the whole pipeline (fetch → parse → sync → UI →
/// Live Activity) can be exercised without a device. Compiled out of device builds entirely.
@MainActor
final class DemoSource {
    private let track = NowPlayingTrack(
        title: "Bohemian Rhapsody",
        artist: "Queen",
        album: "A Night at the Opera",
        durationMs: 354_000,
        source: .appleMusic
    )
    private var start = Date()

    func reset() { start = Date() }

    func sampleNow() -> PlaybackState {
        let duration = track.durationMs ?? 354_000
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let position = elapsed % duration // loop the song so the demo runs forever
        return PlaybackState(track: track, positionMs: position, isPlaying: true, sampledAt: Date())
    }
}
#endif
