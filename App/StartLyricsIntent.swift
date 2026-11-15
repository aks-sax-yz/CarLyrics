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
