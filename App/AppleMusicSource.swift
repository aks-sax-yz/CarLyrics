import Foundation
import MediaPlayer
import CarLyricsCore

/// Reads now-playing from the system Music app (Apple Music / local library) via
/// MediaPlayer. This only ever sees the Music app — never Spotify — which is an Apple
/// platform limitation, not a bug. Requires `NSAppleMusicUsageDescription`.
/// The coordinator polls `sampleNow()` every tick, so no change notifications are observed.
@MainActor
final class AppleMusicSource {
    private let player = MPMusicPlayerController.systemMusicPlayer
    private var started = false

    func start() {
        MPMediaLibrary.requestAuthorization { _ in }
        guard !started else { return }
        started = true
        // ponytail: kept from the observer version — not proven necessary for fresh reads in the
        // background, and dropping it mid-investigation of the widget freeze would add a variable.
        player.beginGeneratingPlaybackNotifications()
    }

    /// Read the current track + position on demand (position isn't pushed via notifications).
    func sampleNow() -> PlaybackState? {
        guard let item = player.nowPlayingItem else { return nil }
        // MediaPlayer returns NaN/non-finite times when nothing is loaded; `Int(NaN)` traps.
        let duration = item.playbackDuration
        let position = player.currentPlaybackTime
        let track = NowPlayingTrack(
            title: item.title ?? "Unknown",
            artist: item.artist ?? "Unknown",
            album: item.albumTitle,
            durationMs: duration.isFinite ? Int(duration * 1000) : nil,
            source: .appleMusic
        )
        return PlaybackState(
            track: track,
            positionMs: position.isFinite ? Int(position * 1000) : 0,
            isPlaying: player.playbackState == .playing,
            sampledAt: Date()
        )
    }
}
