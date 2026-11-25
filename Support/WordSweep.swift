import UIKit

/// Word-by-word karaoke for CarPlay, made of the only thing a Live Activity animates: timer
/// ProgressViews. One bar per word would be dozens of timers per window (the 2026-11-16 CPU kill),
/// so words sung at an even pace share one straight sweep: a bar runs from the first word's start
/// to the last one's end across their whole width. Pace changes, held words and gaps start a new
/// piece. Typical rows need 1–2 pieces, never more than 4.
///
/// Payload (`TimedLine.w`): "chars.startMs.endMs" per word, space-separated, times relative to the
/// line's `at`. The line's text is the words joined by single spaces.
enum WordSweep {
    struct Word: Equatable {
        var chars: Int
        var start: Double // seconds after the line's `at`
        var end: Double
    }

    struct Segment: Equatable {
        var x0, x1: CGFloat
        var t0, t1: Double
    }

    static let tolerance = 0.1 // s: how far a word may be off the shared sweep
    static let maxGap = 0.15   // s: a longer pause between words starts a new piece
    static let maxSegments = 4

    static func encode(_ words: [Word]) -> String {
        let ms = { (t: Double) in Int((max(t, 0) * 1000).rounded()) }
        return words.map { "\($0.chars).\(ms($0.start)).\(ms($0.end))" }.joined(separator: " ")
    }

    /// Ends default to the next word's start (the last word: +0.3s).
    static func decode(_ w: String) -> [Word] {
        let raw = w.split(separator: " ").compactMap { item -> (Int, Double, Double?)? in
            let f = item.split(separator: ".").compactMap { Int($0) }
            guard f.count >= 2 else { return nil }
            return (f[0], Double(f[1]) / 1000, f.count > 2 ? Double(f[2]) / 1000 : nil)
        }
        return raw.indices.map { i in
            let next = i + 1 < raw.count ? raw[i + 1].1 : raw[i].1 + 0.3
            return Word(chars: raw[i].0, start: raw[i].1, end: max(raw[i].2 ?? next, raw[i].1 + 0.05))
        }
    }

    /// Each word's place and time in the row: `text` is the words joined by spaces, measured in `font`.
    static func spans(_ words: [Word], text: String, font: UIFont) -> [Segment] {
        let chars = Array(text)
        var out: [Segment] = []
        var at = 0
        for w in words {
            let end = min(at + w.chars, chars.count)
            out.append(Segment(x0: width(chars[..<min(at, chars.count)], font), x1: width(chars[..<end], font), t0: w.start, t1: w.end))
            at = end + 1
        }
        return out
    }

    /// Held words (sung 1s+, 2–7 letters): they get Apple Music's glow (the swell can't be drawn here).
    static func held(_ words: [Word], text: String, font: UIFont) -> [Segment] {
        zip(words, spans(words, text: text, font: font)).filter { w, _ in w.end - w.start >= 1 && (2...7).contains(w.chars) }.map(\.1)
    }

    /// The pieces for one row: `text` is the words joined by spaces, measured in `font`.
    static func segments(_ words: [Word], text: String, font: UIFont) -> [Segment] {
        guard !words.isEmpty else { return [] }
        let spans = spans(words, text: text, font: font).map { (x0: $0.x0, x1: $0.x1, t0: $0.t0, t1: $0.t1) }
        // Greedy: extend the current piece while every word stays on its straight line.
        var groups: [[Int]] = []
        for k in spans.indices {
            if let last = groups.last, spans[k].t0 - spans[last.last!].t1 <= maxGap, error(last + [k], spans) <= tolerance {
                groups[groups.count - 1].append(k)
            } else {
                groups.append([k])
            }
        }
        while groups.count > maxSegments {
            let j = (0..<groups.count - 1).min { error(groups[$0] + groups[$0 + 1], spans) < error(groups[$1] + groups[$1 + 1], spans) }!
            groups[j] += groups.remove(at: j + 1)
        }
        return groups.map { g in
            Segment(x0: spans[g.first!].x0, x1: spans[g.last!].x1, t0: spans[g.first!].t0, t1: spans[g.last!].t1)
        }
    }

    /// The worst time error (s) of the words' edges against one straight sweep over all of them.
    private static func error(_ g: [Int], _ s: [(x0: CGFloat, x1: CGFloat, t0: Double, t1: Double)]) -> Double {
        let (x0, x1, t0, t1) = (s[g.first!].x0, s[g.last!].x1, s[g.first!].t0, s[g.last!].t1)
        guard x1 > x0 else { return 0 }
        let time = { (x: CGFloat) in t0 + Double((x - x0) / (x1 - x0)) * (t1 - t0) }
        return g.map { max(abs(time(s[$0].x0) - s[$0].t0), abs(time(s[$0].x1) - s[$0].t1)) }.max() ?? 0
    }

    private static func width(_ chars: ArraySlice<Character>, _ font: UIFont) -> CGFloat {
        (String(chars) as NSString).size(withAttributes: [.font: font]).width
    }
}
