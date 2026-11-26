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
                    Text("Auto reads whatever is playing: Apple Music, Spotify or YouTube Music.")
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
                    Toggle("Progress Bar on CarPlay", isOn: $coordinator.carPlayProgress)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Album uses the artwork's color in Apple Music and falls back to the color above. Text turns black or white to stay readable. Morph animates each change but can lag on CarPlay. With the progress bar on, CarPlay lyrics are a little smaller so it fits.")
                }

                Section {
                    ShortcutsLink()
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("In Shortcuts › Automation, add CarPlay › Connects → Start Car Lyrics and CarPlay › Disconnects → Stop Car Lyrics. If the lyrics get stuck while driving, say \u{201C}Car Lyrics froze\u{201D} to Siri to mark it in the log.")
                }

                AppleMusicLyricsSection(account: coordinator.appleAccount)

                spotifySection
                YouTubeMusicSection(source: coordinator.youTube)

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

    private func connectSpotify() {
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

    @ViewBuilder private var spotifySection: some View {
        Section {
            if !SpotifyConfig.isConfigured {
                Label("Add a Spotify Client ID in SpotifyConfig to enable.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if coordinator.spotify.isLoggedIn {
                if !coordinator.spotify.canSeek {
                    // Logins from before tap-to-jump lack the playback permission; signing in again adds it.
                    Button("Reconnect Spotify to Tap Lines") { connectSpotify() }
                }
                Button("Disconnect Spotify", role: .destructive) { coordinator.spotify.logout() }
            } else {
                Button("Connect Spotify") { connectSpotify() }
            }
            if let spotifyError { Text(spotifyError).foregroundStyle(.red) }
            SpotifyLyricsRow(account: coordinator.spotifyLyrics)
        } header: {
            Text("Spotify")
        } footer: {
            Text("Connect Spotify tells Car Lyrics what's playing and lets a tapped line jump the song (Premium); it opens Safari's sign-in, so every option works there. Spotify's own lyrics need Spotify's web sign-in as well: email, an emailed code, Apple or Google. Passkeys don't work inside apps. Songs without them use LRCLIB.")
        }
    }
}

/// Apple Music's word-timed lyrics: on by default, using the phone's own Apple Music account.
private struct AppleMusicLyricsSection: View {
    @ObservedObject var account: AppleMusicAccount
    @State private var signingIn = false

    var body: some View {
        Section {
            Toggle("Apple Music Lyrics", isOn: $account.enabled)
            if account.enabled {
                Text(account.status).font(.footnote).foregroundStyle(.secondary)
                if account.needsSignIn || account.via == .web {
                    Button(account.via == .web ? "Sign In Again" : "Sign In to Apple Music") {
                        Task {
                            await WebCookies.clear(domain: "apple.com") // a stale login would close the sheet at once
                            signingIn = true
                        }
                    }
                    // On the button, not the Section: a Section hands its modifiers to every row, and
                    // two sheets on one binding present and dismiss each other (seen 2026-11-26).
                    .sheet(isPresented: $signingIn) { signInSheet }
                }
                if account.via != nil {
                    Button("Disconnect Apple Music Lyrics", role: .destructive) { Task { await account.disconnect() } }
                }
            }
        } header: {
            Text("Apple Music")
        } footer: {
            Text("Word-by-word lyrics from Apple Music, using the Apple Music account already on this phone, so there's nothing to sign in to. If Apple refuses it, sign in here instead: tap Sign In on Apple's page, then your password and the code (passkeys don't work inside apps). Songs Apple has no lyrics for use LRCLIB.")
        }
    }

    private var signInSheet: some View {
            SignInSheet(title: "Apple Music",
                        web: SignInWebView(url: URL(string: "https://music.apple.com/us/browse")!, userAgent: SignInWebView.safariUserAgent))
                .task {
                    // Signed in once Apple sets the Apple Music user token cookie.
                    while !Task.isCancelled {
                        if let token = await WebCookies.value("media-user-token", domain: "apple.com") {
                            await account.signedIn(userToken: token)
                            signingIn = false
                            return
                        }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
    }
}

/// YouTube Music: what's playing comes from its history, so it needs the YouTube Music login.
private struct YouTubeMusicSection: View {
    @ObservedObject var source: YouTubeMusicSource
    @State private var signingIn = false

    var body: some View {
        Section {
            if source.isSignedIn {
                LabeledContent("YouTube Music", value: "Signed in")
                Button("Sign Out of YouTube Music", role: .destructive) { Task { await source.signOut() } }
            } else {
                Button("Sign In to YouTube Music") { signingIn = true }
                    .sheet(isPresented: $signingIn) {
                        SignInSheet(title: "YouTube Music",
                                    web: SignInWebView(url: YouTubeMusicSource.signInURL, userAgent: SignInWebView.safariUserAgent))
                            .task {
                                // Signed in once Google sets YouTube's login cookie (after its redirect lands).
                                while !Task.isCancelled {
                                    await source.refreshSignIn()
                                    if source.isSignedIn {
                                        try? await Task.sleep(for: .seconds(2)) // let the redirect to YouTube Music land
                                        signingIn = false
                                        return
                                    }
                                    try? await Task.sleep(for: .seconds(1))
                                }
                            }
                    }
            }
        } header: {
            Text("YouTube Music")
        } footer: {
            Text("iOS doesn't tell apps what YouTube Music is playing, so Car Lyrics reads your YouTube Music history (keep it on) and times each song from the moment it starts. Sign in with your password or a prompt on your phone: if Google tries a passkey, tap Try another way. After you drag the slider in YouTube Music, tap the line being sung.")
        }
    }
}

/// Spotify's own lyrics: a separate web sign-in (see SpotifyLyricsAccount).
private struct SpotifyLyricsRow: View {
    @ObservedObject var account: SpotifyLyricsAccount
    @State private var signingIn = false

    var body: some View {
        if account.isConnected {
            LabeledContent("Spotify Lyrics", value: account.status)
            Button("Sign Out of Spotify Lyrics", role: .destructive) { Task { await account.signOut() } }
        } else {
            Button("Sign In for Spotify Lyrics") { signingIn = true }
                .sheet(isPresented: $signingIn) {
                    SignInSheet(title: "Spotify", web: account.signInPage())
                        .onAppear { account.onSignedIn = { signingIn = false } }
                }
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
