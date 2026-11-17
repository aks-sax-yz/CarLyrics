import Foundation

/// Append-only debug log in Documents (`events.log`, rotating into `events.1.log` at 2 MB, so about
/// 4 MB / several days of drives survive). Pull it off the phone with
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
///   --domain-identifier com.akshatsaxena01.carlyrics[.<TEAMID>] --source Documents/events.log --destination .`
/// or share it from the app (Share Logs). One line per event, millisecond timestamps.
@MainActor
enum EventLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("events.log")
    static let previousURL = url.deletingLastPathComponent().appendingPathComponent("events.1.log")
    private static let maxBytes: UInt64 = 2_000_000
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: .now)) \(message)\n"
        if handle == nil { open() }
        handle?.write(Data(line.utf8))
        if let size = try? handle?.offset(), size > maxBytes { rotate() }
    }

    private static func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: url, to: previousURL)
        open()
    }
}
