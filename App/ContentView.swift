import SwiftUI
import CarLyricsCore

/// The lyrics screen, styled after Apple Music's: blurred artwork behind big bold lines, the
/// current line bright, the rest dimmed and softened, auto-scrolling, tap a line to jump there.
/// Everything else lives in Settings.
struct ContentView: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                ArtworkBackground()
                VStack(spacing: 0) {
                    if coordinator.track != nil { NowPlayingHeader() }
                    lyricsOrPlaceholder
                }
            }
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            // An overlay, not a safeAreaInset: the lyrics scroll under an inset, and the line beneath
            // the pill took its taps (as tap-to-seek) instead of the buttons.
            .overlay(alignment: .bottom) {
                if coordinator.lyrics?.isSynced == true { SyncPill().padding(.bottom, 8) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var lyricsOrPlaceholder: some View {
        if coordinator.track == nil {
            ContentUnavailableView {
                Label(coordinator.status == "Stopped" ? "Stopped" : "Nothing Playing", systemImage: "music.note")
            } description: {
                Text("Play a song in Apple Music. Its lyrics appear here, on the Lock Screen and on CarPlay.")
            }
        } else if let lyrics = coordinator.lyrics, !lyrics.isEmpty {
            LyricsList(lyrics: lyrics)
        } else if coordinator.status.hasPrefix("Fetching") {
            ContentUnavailableView {
                Label(coordinator.status.replacingOccurrences(of: "…", with: ""), systemImage: "text.quote")
            } description: { ProgressView() }
        } else {
            ContentUnavailableView("No Lyrics", systemImage: "text.quote",
                                   description: Text(coordinator.status))
        }
    }
}

/// Artwork, title and artist, Apple Music's mini-player style.
private struct NowPlayingHeader: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = coordinator.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 8))
            .shadow(radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.track?.title ?? "").font(.headline).lineLimit(1)
                Text(coordinator.track?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

/// Big, bold lines; the current one bright, the rest dimmed; tap a line to seek Apple Music to it.
/// Smoothness: lines switch exactly when they start (a TimelineView on the coordinator's
/// `lineDates`, not the 1s tick); one spring animates the whole list (opacity + scale only, no
/// per-line blur); the current line sits in the upper third like Apple Music; auto-scroll pauses
/// while you scroll and picks up again 3s after you let go.
private struct LyricsList: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator
    let lyrics: TimedLyrics
    @State private var holdAutoScrollUntil = Date.distantPast

    var body: some View {
        TimelineView(.explicit(coordinator.lineDates)) { context in
            let current = currentLine(at: context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            lineView(index: index, line: line, current: current)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 200) // lets the first and last lines reach the focus point
                    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: current)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    // Hand-scrolling: leave the view where the user put it for a moment.
                    if phase != .idle { holdAutoScrollUntil = .now.addingTimeInterval(3) }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: current, initial: true) { _, index in
                    guard let index, Date() > holdAutoScrollUntil else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.32))
                    }
                }
            }
        }
    }

    /// The line playing at `date`: exact from the line start times while playing, else the
    /// coordinator's last tick (paused, unsynced, or a source without timing).
    private func currentLine(at date: Date) -> Int? {
        let dates = coordinator.lineDates
        guard !dates.isEmpty else { return coordinator.currentLineIndex }
        return dates.lastIndex { $0 <= date }
    }

    private func lineView(index: Int, line: LyricsLine, current: Int?) -> some View {
        let isCurrent = index == current
        let isPast = current.map { index < $0 } ?? false
        // Word-timed lyrics: the words as one line, so it doesn't reflow when it starts.
        let text = line.words.map { $0.map(\.text).joined(separator: " ") } ?? line.text
        let dates = coordinator.lineDates
        return Group {
            if isCurrent, let words = line.words, lyrics.isSynced, index < dates.count {
                WordLineView(words: words, lineEndMs: line.endMs, lineStart: dates[index],
                             lineTimeMs: line.timeMs, fontSize: 30)
            } else {
                Text(text.isEmpty ? "♪" : text)
                    .font(.system(size: 30, weight: .bold))
            }
        }
            .foregroundStyle(.white.opacity(isCurrent ? 1 : (isPast ? 0.22 : 0.38)))
            .scaleEffect(isCurrent ? 1 : 0.96, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { coordinator.seek(toLine: index) }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Liquid Glass "− +0.8 s +" pill. Nudges this song's sync (remembered per song).
private struct SyncPill: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator

    var body: some View {
        HStack(spacing: 4) {
            nudge(-100, "minus", "Show lyrics later")
            VStack(spacing: 0) {
                Text("Sync").font(.caption2).foregroundStyle(.secondary)
                Text(syncLabel(coordinator.userOffsetMs)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .frame(minWidth: 72)
            nudge(100, "plus", "Show lyrics earlier")
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func nudge(_ delta: Int, _ symbol: String, _ label: String) -> some View {
        Button {
            coordinator.setOffsetForCurrentSong(min(3000, max(-3000, coordinator.userOffsetMs + delta)))
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(width: 44, height: 36)
                .contentShape(.rect) // the whole 44pt button, not just the 14pt glyph
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "+0.8 s", "0 s", "−0.3 s". Positive shows lyrics earlier.
func syncLabel(_ ms: Int) -> String {
    ms == 0 ? "0 s" : String(format: "%@%.1f s", ms > 0 ? "+" : "−", Double(abs(ms)) / 1000)
}

/// The song's artwork, blurred and darkened, Apple Music lyrics style; the icon's night purple
/// when there's no artwork. The blur is baked into `artworkBackdrop` once per song, instead of a
/// live full-screen blur re-rendered with the view.
private struct ArtworkBackground: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.35, green: 0.16, blue: 0.53), Color(red: 0.04, green: 0.06, blue: 0.19)],
                           startPoint: .top, endPoint: .bottom)
            if let backdrop = coordinator.artworkBackdrop {
                // In an overlay on a size-neutral Color.clear: a square image filled to the screen's
                // height is wider than the screen, and as a ZStack child it widened the whole page.
                Color.clear
                    .overlay { Image(uiImage: backdrop).resizable().interpolation(.high).scaledToFill() }
                    .clipped()
                    .transition(.opacity)
            }
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: coordinator.artworkBackdrop)
    }
}
