import Foundation
import ShazamKit
import AVFAudio
import CarLyricsCore

/// Universal audio detector. Listens to ambient audio via ShazamKit and identifies whatever is
/// playing — YouTube Music, Amazon Music, radio, TV, vinyl — that the Apple Music and Spotify
/// APIs can't see. In a car the audio comes through the speakers, so the phone's mic hears it.
///
/// ShazamKit hands back `predictedCurrentMatchOffset` (the position *within* the matched
/// recording, adjusted for time since the match), so sync is real, not just a title. We anchor
/// on each match and extrapolate with the wall clock between matches.
///
/// Needs `NSMicrophoneUsageDescription`. Does nothing on the Simulator (no real mic input) —
/// it just never matches, which is fine; it's a device feature.
@MainActor
final class ShazamSource: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    // `SHManagedSession()` with no custom catalog matches against Apple's full Shazam catalog
    // and manages the audio engine + mic itself — the modern, "just works" entry point.
    private let session = SHManagedSession()
    private var listenTask: Task<Void, Never>?

    // Anchor from the most recent successful match.
    private var track: NowPlayingTrack?
    private var anchorOffsetMs = 0
    private var anchoredAt = Date()
    private var lastMatchAt: Date?

    /// Drop the anchor if we haven't re-matched in this long — the audio likely stopped or
    /// changed songs. Shazam re-confirms every ~10-20s, so 40s is a couple of missed windows.
    private static let staleAfter: TimeInterval = 40

    func start() {
        guard listenTask == nil else { return }
        isListening = true
        lastError = nil
        configureAudioSession()
        listenTask = Task { [weak self] in
            guard let self else { return }
            await self.session.prepare()            // requests mic permission, warms up
            for await result in self.session.results {
                self.handle(result)
            }
            self.isListening = false
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        session.cancel()
        isListening = false
        track = nil
        lastMatchAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Record while the car's music keeps playing (`.mixWithOthers` so we don't pause it), and
    /// stay alive in the background (paired with `UIBackgroundModes: [audio]`) so the Live
    /// Activity loop keeps advancing lyric lines on CarPlay.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // A2DP only (NOT .allowBluetooth): .allowBluetooth enables the HFP call codec, which
            // drops the car/headphone audio to call quality. A2DP keeps output high-fidelity while
            // we record ambient sound off the built-in mic.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
    }

    private func handle(_ result: SHSession.Result) {
        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first else { return }
            track = NowPlayingTrack(
                title: item.title ?? "Unknown",
                artist: item.artist ?? "Unknown",
                album: nil,
                durationMs: nil,           // Shazam doesn't give duration; LRCLIB search covers it
                source: .shazam
            )
            let offset = item.predictedCurrentMatchOffset
            anchorOffsetMs = offset.isFinite ? Int(offset * 1000) : 0
            anchoredAt = Date()
            lastMatchAt = Date()
            lastError = nil
        case .noMatch:
            break   // keep extrapolating from the last anchor until it goes stale
        case .error(let err, _):
            lastError = err.localizedDescription
        }
    }

    /// Current playback, extrapolated from the last match. Nil once the anchor goes stale.
    func sampleNow() -> PlaybackState? {
        guard let track, let lastMatchAt else { return nil }
        let now = Date()
        guard now.timeIntervalSince(lastMatchAt) <= Self.staleAfter else { return nil }
        let elapsed = Int(now.timeIntervalSince(anchoredAt) * 1000)
        return PlaybackState(
            track: track,
            positionMs: anchorOffsetMs + elapsed,
            isPlaying: true,
            sampledAt: now
        )
    }
}
