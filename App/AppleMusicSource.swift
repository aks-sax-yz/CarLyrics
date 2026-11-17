import Foundation
import MediaPlayer
import CoreImage
import UIKit
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

    /// Average colour of the now-playing artwork (nil without art), for the album-art background.
    /// ponytail: a plain average can come out muddy; a dominant colour (CIKMeans) is the upgrade.
    func artworkColor() -> LyricsActivityAttributes.RGB? {
        guard let image = player.nowPlayingItem?.artwork?.image(at: CGSize(width: 40, height: 40)),
              let input = CIImage(image: image) else { return nil }
        let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return .init(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
    }

    /// Now-playing artwork for the lyrics screen's background and header.
    func artworkImage() -> UIImage? {
        player.nowPlayingItem?.artwork?.image(at: CGSize(width: 600, height: 600))
    }

    /// Jump playback (tapping a lyric line, as in Apple Music's own lyrics view).
    func seek(toMs ms: Int) {
        player.currentPlaybackTime = Double(max(0, ms)) / 1000
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
