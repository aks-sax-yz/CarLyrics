import Foundation
import MediaPlayer
import CarLyricsCore

/// Reads now-playing from the system Music app (Apple Music / local library) via
/// MediaPlayer. This only ever sees the Music app — never Spotify — which is an Apple
/// platform limitation, not a bug. Requires `NSAppleMusicUsageDescription`.
@MainActor
final class AppleMusicSource: ObservableObject {
    @Published private(set) var state: PlaybackState?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observing = false

    func start() {
        MPMediaLibrary.requestAuthorization { _ in }
        guard !observing else { return }
        observing = true
        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        refresh()
    }

    func stop() {
        guard observing else { return }
        observing = false
        player.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    /// Read the current position on demand (position isn't pushed via notifications).
    func sampleNow() -> PlaybackState? {
        buildState()
    }

    @objc private func refresh() {
        state = buildState()
    }

    private func buildState() -> PlaybackState? {
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
