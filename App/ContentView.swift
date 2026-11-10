import SwiftUI
import CarLyricsCore

struct ContentView: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                lyricsScroller
                Divider()
                controls
            }
            .navigationTitle("Car Lyrics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(coordinator.track?.title ?? "—")
                .font(.headline)
                .lineLimit(1)
            Text(coordinator.track?.artist ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(coordinator.status)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }

    private var lyricsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let lyrics = coordinator.lyrics, !lyrics.isEmpty {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(index == coordinator.currentLineIndex ? .title2.bold() : .body)
                                .foregroundStyle(index == coordinator.currentLineIndex ? .primary : .secondary)
                                .id(index)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("No lyrics")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
            .onChange(of: coordinator.currentLineIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Source", selection: $coordinator.sourceMode) {
                ForEach(NowPlayingCoordinator.SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Sync")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(coordinator.userOffsetMs) },
                        set: { coordinator.userOffsetMs = Int($0) }
                    ),
                    in: -3000...3000, step: 100
                )
                Text("\(coordinator.userOffsetMs > 0 ? "+" : "")\(coordinator.userOffsetMs)ms")
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }

            spotifyRow
            diagnosticsRow
        }
        .padding()
    }

    /// Background-freeze diagnostic. Background the app ~30s then reopen: if "max gap" jumps to
    /// ~30s the app was suspended (keep-alive failed); if it stays ~1s the app kept running.
    private var diagnosticsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: keepAliveIsActive ? "location.circle.fill" : "location.circle")
                    .foregroundStyle(keepAliveIsActive ? .green : .orange)
                Text("background: \(keepAliveLabel) · max gap: \(String(format: "%.0f", coordinator.maxTickGap))s")
                Spacer()
                Button("Reset") { coordinator.resetDiagnostics() }
                    .buttonStyle(.bordered)
            }
            Text("location callback: \(locationUpdateAge) · activity attempts: \(coordinator.activityUpdateAttempts)")
            Text("CarPlay: \(coordinator.isCarPlayConnected ? "connected" : "disconnected") · launch requires Shortcuts automation")
            Text("last activity attempt: \(activityAttemptAge) · gaps >3s: \(coordinator.tickGapEvents.count)")
            if let latest = coordinator.tickGapEvents.last {
                Text("latest gap: \(String(format: "%.1f", latest.gap))s at \(latest.timestamp.formatted(date: .abbreviated, time: .standard))")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var keepAliveIsActive: Bool {
        coordinator.keepAliveStatus == .active
    }

    private var keepAliveLabel: String {
        switch coordinator.keepAliveStatus {
        case .starting: "starting"
        case .active: "active"
        case .permissionRequired: "location permission required"
        case .failed(let message): "failed (\(message))"
        }
    }

    private var locationUpdateAge: String {
        guard let date = coordinator.lastLocationUpdate else { return "never" }
        return "\(max(0, Int(Date().timeIntervalSince(date))))s ago"
    }

    private var activityAttemptAge: String {
        guard let date = coordinator.lastActivityUpdateAttempt else { return "never" }
        return "\(max(0, Int(Date().timeIntervalSince(date))))s ago"
    }

    @ViewBuilder private var spotifyRow: some View {
        if !SpotifyConfig.isConfigured {
            Label("Set your Spotify Client ID in SpotifyConfig", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if coordinator.spotify.isLoggedIn {
            Button(role: .destructive) { coordinator.spotify.logout() } label: {
                Label("Disconnect Spotify", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task { try? await coordinator.spotify.login() }
            } label: {
                Label("Connect Spotify", systemImage: "music.note.list")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
