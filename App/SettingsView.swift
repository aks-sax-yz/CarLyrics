import SwiftUI
import AppIntents
import AuthenticationServices
import CarLyricsCore

/// Settings sheet: a grouped iOS form. The lyrics screen stays free of controls.
struct SettingsView: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var spotifyError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $coordinator.sourceMode) {
                        ForEach(NowPlayingCoordinator.SourceMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Auto reads Apple Music, then Spotify, and listens with the microphone only when another app is playing.")
                }

                Section {
                    LabeledContent("Default", value: syncLabel(coordinator.defaultOffsetMs))
                    Slider(value: Binding(get: { Double(coordinator.defaultOffsetMs) },
                                          set: { coordinator.setDefaultOffset(Int($0)) }),
                           in: -3000...3000, step: 100) {
                        Text("Default sync")
                    } minimumValueLabel: { Text("Later").font(.caption) } maximumValueLabel: { Text("Earlier").font(.caption) }
                    if coordinator.currentSongHasOwnOffset, let title = coordinator.track?.title {
                        LabeledContent(title, value: syncLabel(coordinator.userOffsetMs))
                        Button("Use Default for This Song") { coordinator.resetCurrentSongOffset() }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("The default applies to every song you haven't adjusted. The Sync pill on the lyrics screen changes only the song that's playing, and is remembered for it. Lyric timing is also matched to most uploads of each song automatically.")
                }

                Section {
                    Picker("Background", selection: $coordinator.lyricsBackground) {
                        ForEach(NowPlayingCoordinator.LyricsBackground.allCases) { Text($0.label).tag($0) }
                    }
                    if coordinator.lyricsBackground != .glass {
                        ColorPicker("Color", selection: solidColor, supportsOpacity: false)
                    }
                    Picker("Line Transition", selection: $coordinator.lineTransition) {
                        ForEach(LyricsActivityAttributes.Transition.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Album uses the artwork's color in Apple Music and falls back to the color above. Text turns black or white to stay readable. Morph animates each change but can lag on CarPlay.")
                }

                Section {
                    ShortcutsLink()
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("In Shortcuts › Automation, add CarPlay › Connects → Start Car Lyrics and CarPlay › Disconnects → Stop Car Lyrics. If the lyrics get stuck while driving, say \u{201C}Car Lyrics froze\u{201D} to Siri to mark it in the log.")
                }

                spotifySection

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var solidColor: Binding<Color> {
        Binding(
            get: { Color(red: coordinator.solidColor.r, green: coordinator.solidColor.g, blue: coordinator.solidColor.b) },
            set: {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                UIColor($0).getRed(&r, green: &g, blue: &b, alpha: nil)
                // Wide-gamut picks come back outside 0...1 in extended sRGB.
                coordinator.solidColor = .init(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
            }
        )
    }

    @ViewBuilder private var spotifySection: some View {
        Section {
            if !SpotifyConfig.isConfigured {
                Label("Add a Spotify Client ID in SpotifyConfig to enable.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if coordinator.spotify.isLoggedIn {
                Button("Disconnect Spotify", role: .destructive) { coordinator.spotify.logout() }
            } else {
                Button("Connect Spotify") {
                    Task {
                        do {
                            try await coordinator.spotify.login()
                            spotifyError = nil
                        } catch ASWebAuthenticationSessionError.canceledLogin {
                            spotifyError = nil // closed the sheet: not an error
                        } catch {
                            spotifyError = "Spotify login failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
            if let spotifyError { Text(spotifyError).foregroundStyle(.red) }
        } header: {
            Text("Spotify")
        }
    }
}

/// The background-running and Live Activity health readouts, plus the debug log.
struct DiagnosticsView: View {
    @EnvironmentObject var coordinator: NowPlayingCoordinator

    var body: some View {
        List {
            Section {
                LabeledContent("Background", value: keepAliveLabel)
                LabeledContent("Location update", value: age(coordinator.lastLocationUpdate))
                LabeledContent("CarPlay", value: coordinator.isCarPlayConnected ? "Connected" : "Disconnected")
                LabeledContent("Longest pause", value: String(format: "%.0f s", coordinator.maxTickGap))
                LabeledContent("Pauses over 3 s", value: "\(coordinator.tickGapEvents.count)")
            } header: {
                Text("Running in Background")
            } footer: {
                Text("A long pause means iOS suspended the app, so the lyrics stopped advancing.")
            }

            Section("Live Activity") {
                LabeledContent("State", value: coordinator.activityHealth)
                LabeledContent("Updates sent", value: "\(coordinator.activityUpdateAttempts)")
                LabeledContent("Last update", value: age(coordinator.lastActivityUpdateAttempt))
            }

            Section {
                ShareLink(items: [EventLog.url, EventLog.previousURL].filter { FileManager.default.fileExists(atPath: $0.path) }) {
                    Label("Share Logs", systemImage: "square.and.arrow.up")
                }
                Button("Reset Counters", role: .destructive) { coordinator.resetDiagnostics() }
            } footer: {
                Text("The log records every Live Activity update, lyric fetch and system event, for debugging freezes.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keepAliveLabel: String {
        switch coordinator.keepAliveStatus {
        case .starting: "Starting"
        case .active: "Active"
        case .permissionRequired: "Needs Location Access"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func age(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return "\(max(0, Int(Date().timeIntervalSince(date)))) s ago"
    }
}
