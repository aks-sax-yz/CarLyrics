import UIKit

/// Keeps lyric text at one size: instead of shrinking a long line to fit, it's cut into parts that
/// each fit `rows` rows of the real width at the real font, shown one after another on the clock.
/// Done in the widget, where the width is known (each place fits its own: CarPlay, lock screen,
/// the CarPlay widget page).
enum LyricFit {
    typealias Line = LyricsActivityAttributes.TimedLine

    /// The lyric font everywhere the widget fits lines. A fixed size (not a text style) so the
    /// measurement here is exactly what SwiftUI draws.
    static func font(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .bold) }

    /// Part k of a line shows at the line's start plus its share (by characters) of the time to the
    /// next line. A line with no next one (the song's last) is given ~12 characters a second.
    static func split(_ lines: [Line], width: CGFloat, font: UIFont, rows: Int) -> [Line] {
        guard width > 0 else { return lines }
        var out: [Line] = []
        for (i, line) in lines.enumerated() {
            let parts = parts(of: line.text, width: width, font: font, rows: rows)
            guard parts.count > 1 else { out.append(line); continue }
            let end = i + 1 < lines.count ? lines[i + 1].at : line.at.addingTimeInterval(Double(line.text.count) / 12)
            let span = end.timeIntervalSince(line.at)
            var before = 0
            for part in parts {
                out.append(.init(text: part, at: line.at.addingTimeInterval(span * Double(before) / Double(line.text.count))))
                before += part.count + 1
            }
        }
        return out
    }

    /// Word-wraps the way Text does (greedy, at spaces), then takes `rows` rows per part.
    /// ponytail: a single word wider than the row still wraps mid-word in Text; lyrics don't have those.
    static func parts(of text: String, width: CGFloat, font: UIFont, rows: Int) -> [String] {
        let room = width * 0.95 // NSString's measure and SwiftUI's wrap differ by a point or two
        var wrapped: [String] = []
        for word in text.split(separator: " ") {
            if let last = wrapped.last, measure(last + " " + word, font) <= room {
                wrapped[wrapped.count - 1] = last + " " + word
            } else {
                wrapped.append(String(word))
            }
        }
        let rows = max(rows, 1)
        return stride(from: 0, to: wrapped.count, by: rows).map {
            wrapped[$0..<min($0 + rows, wrapped.count)].joined(separator: " ")
        }
    }

    /// Rows of `font` that fit in `height`.
    static func rows(in height: CGFloat, font: UIFont) -> Int { max(1, Int(height / font.lineHeight)) }

    private static func measure(_ text: String, _ font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// During line i, the line `offset` places ahead ("" past the end): the read-ahead rows.
    static func ahead(_ lines: [Line], by offset: Int) -> [Line] {
        lines.indices.map { .init(text: $0 + offset < lines.count ? lines[$0 + offset].text : "", at: lines[$0].at) }
    }
}
