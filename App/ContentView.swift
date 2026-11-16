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
                ArtworkBackground(artwork: coordinator.artwork)
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
            .safeAreaInset(edge: .bottom) {
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
        } else if coordinator.status.hasPrefix("Fetching") || coordinator.status.hasPrefix("Listening") {
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

/// Big, bold lines; the current one bright, others dimmed and blurred by distance; centred on
/// the current line as it moves. Tapping a line seeks Apple Music to it.
private struct LyricsList: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator
    let lyrics: TimedLyrics

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        lineView(index: index, text: line.text)
                            .id(index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 120) // lets the first and last lines reach the centre
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: coordinator.currentLineIndex, initial: true) { _, index in
                guard let index else { return }
                withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func lineView(index: Int, text: String) -> some View {
        let current = coordinator.currentLineIndex
        let distance = current.map { abs($0 - index) } ?? 2
        let isCurrent = distance == 0 && current != nil
        return Text(text.isEmpty ? "♪" : text)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.32))
            .blur(radius: isCurrent || !lyrics.isSynced ? 0 : min(Double(distance), 4) * 0.5)
            .scaleEffect(isCurrent ? 1 : 0.97, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { coordinator.seek(toLine: index) }
            .animation(.smooth(duration: 0.4), value: current)
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
        .glassEffect(.regular, in: .capsule)
    }

    private func nudge(_ delta: Int, _ symbol: String, _ label: String) -> some View {
        Button {
            coordinator.setOffsetForCurrentSong(min(3000, max(-3000, coordinator.userOffsetMs + delta)))
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "+0.8 s", "0 s", "−0.3 s". Positive shows lyrics earlier.
func syncLabel(_ ms: Int) -> String {
    ms == 0 ? "0 s" : String(format: "%@%.1f s", ms > 0 ? "+" : "−", Double(abs(ms)) / 1000)
}

/// The song's artwork, heavily blurred and darkened, Apple Music lyrics style; the icon's night
/// purple when there's no artwork.
private struct ArtworkBackground: View {
    let artwork: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.35, green: 0.16, blue: 0.53), Color(red: 0.04, green: 0.06, blue: 0.19)],
                           startPoint: .top, endPoint: .bottom)
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .saturation(1.3)
                    .transition(.opacity)
            }
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: artwork)
    }
}
