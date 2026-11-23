import Foundation

/// What the CarPlay lyrics widget shows, handed over through the App Group container: the whole
/// song's lines with wall-clock start times while playing, so one timeline covers the song and the
/// app reloads the widget only when this changes (song change, pause, seek, sync nudge), not per line.
struct WidgetFeed: Codable, Equatable {
    typealias Line = LyricsActivityAttributes.TimedLine
    static let kind = "CarLyricsWidget"

    var title: String
    var artist: String
    /// Playing synced lyrics: every line ("" first for the intro). Empty otherwise.
    var lines: [Line] = []
    /// Paused / unsynced: the line to show, and what comes after.
    var currentLine = ""
    var nextLines: [String] = []
    var background: LyricsActivityAttributes.RGB?
    var isPlaying = false

    static let idle = WidgetFeed(title: "", artist: "")

    /// One timeline entry: what the widget shows from `date`.
    struct Moment: Equatable {
        let date: Date
        let current: String
        let next: [String]
    }

    static let bigSize: CGFloat = 18, smallSize: CGFloat = 14 // Akshat: smaller than the first 22/16

    /// The widget timeline: one entry per line, from the one playing at `now`. Lines too long for
    /// two rows at `bigSize` in `width` are cut into parts with their own entries (LyricFit), so the
    /// type never shrinks. WidgetKit switches entries on its own schedule: no push per line (iOS
    /// throttles those on CarPlay) and no timer-mask trick (which can stop animating), and the app
    /// reloads the widget once per song.
    func timeline(now: Date, width: CGFloat) -> [Moment] {
        guard !lines.isEmpty else { return [Moment(date: now, current: currentLine, next: Array(nextLines.prefix(2)))] }
        let parts = LyricFit.split(lines, width: width, font: LyricFit.font(Self.bigSize), rows: 2)
        let first = parts.lastIndex { $0.at <= now } ?? 0
        return (first..<parts.count).map { i in
            Moment(date: i == first ? now : parts[i].at, current: parts[i].text,
                   next: parts[(i + 1)...].prefix(2).map(\.text))
        }
    }

    static func load() -> WidgetFeed? {
        guard let url = AppGroup.feedURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetFeed.self, from: data)
    }

    /// False when there's no App Group (see `AppGroup`): the widget then says to open the app.
    @discardableResult func save() -> Bool {
        guard let url = AppGroup.feedURL, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// The shared container the app and widget both see. Its ID differs per install: Xcode uses
/// `group.com.akshatsaxena01.carlyrics`; SideStore (like AltStore) re-registers it with the team ID
/// on the end, `group.<…>.carlyrics.<TEAMID>`, matching the bundle ID it gives the app, and lists
/// it under `ALTAppGroups` in Info.plist. So try those and use whichever iOS actually grants.
enum AppGroup {
    static let url: URL? = {
        var bundleID = Bundle.main.bundleIdentifier ?? ""
        if Bundle.main.bundlePath.hasSuffix(".appex") { // the widget: <app id>.widget → <app id>
            bundleID = bundleID.split(separator: ".").dropLast().joined(separator: ".")
        }
        let candidates = (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? [])
            + ["group." + bundleID, "group.com.akshatsaxena01.carlyrics"]
        return candidates.lazy.compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }.first
    }()

    static var feedURL: URL? { url?.appendingPathComponent("widget-feed.json") }
}
