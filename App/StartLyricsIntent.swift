import AppIntents

/// "Start Car Lyrics" for Shortcuts: brings up the lyrics Live Activity without opening the app,
/// even with the phone locked, so an automation (CarPlay connects / Music opened) can start it.
/// A `LiveActivityIntent` is the one way iOS lets a backgrounded app *start* a Live Activity;
/// `Activity.request` from the background otherwise fails with `visibility` (2026-11-14 drive).
struct StartLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Start Car Lyrics" }
    static var description: IntentDescription {
        IntentDescription("Shows synced lyrics on the Lock Screen and CarPlay without opening the app.")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NowPlayingCoordinator.shared.startFromIntent()
        return .result()
    }
}

/// "Stop Car Lyrics" for a CarPlay-disconnects automation: ends the Live Activity, stops the loop
/// and the location keep-alive, and clears what's playing, so iOS can suspend the app.
struct StopLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Car Lyrics" }
    static var description: IntentDescription {
        IntentDescription("Ends the lyrics Live Activity and stops Car Lyrics running in the background.")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NowPlayingCoordinator.shared.stopFromIntent()
        return .result()
    }
}

/// "Car Lyrics froze": say it to Siri when the widget looks stuck. It logs a marked snapshot so the
/// freeze can be matched to the push log and the phone's memory reports afterwards.
struct ReportFreezeIntent: AppIntent {
    static var title: LocalizedStringResource { "Report Car Lyrics Freeze" }
    static var description: IntentDescription {
        IntentDescription("Marks the moment the lyrics looked stuck in Car Lyrics' debug log.")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NowPlayingCoordinator.shared.markFreeze()
        return .result(dialog: "Logged.")
    }
}

/// Both actions show up under Car Lyrics in the Shortcuts app (and Siri/Spotlight) with no setup.
/// Apps can't create the CarPlay connect/disconnect automations themselves; the user adds those.
struct CarLyricsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartLyricsIntent(), phrases: ["Start \(.applicationName)", "Show lyrics in \(.applicationName)"],
                    shortTitle: "Start Car Lyrics", systemImageName: "music.note")
        AppShortcut(intent: StopLyricsIntent(), phrases: ["Stop \(.applicationName)"],
                    shortTitle: "Stop Car Lyrics", systemImageName: "stop.circle")
        AppShortcut(intent: ReportFreezeIntent(), phrases: ["\(.applicationName) froze", "\(.applicationName) is stuck"],
                    shortTitle: "Report Freeze", systemImageName: "exclamationmark.bubble")
    }
}
