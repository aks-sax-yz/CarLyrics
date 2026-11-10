import Foundation

/// Append-only event log for the "widget stops updating after a few songs" investigation. Lives
/// in Documents so it can be pulled off the phone:
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
///   --domain-identifier com.akshatsaxena01.carlyrics --source Documents/events.log --destination .`
/// ponytail: rewrites the whole file per event (capped at 500 lines) — fine at a few events a minute.
@MainActor
enum EventLog {
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("events.log")
    private static let maxLines = 500
    private static var lines: [String] = (try? String(contentsOf: url, encoding: .utf8))
        .map { $0.split(separator: "\n").map(String.init) } ?? []

    static func log(_ message: String) {
        lines.append("\(Date.now.ISO8601Format(.iso8601(timeZone: .current))) \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
