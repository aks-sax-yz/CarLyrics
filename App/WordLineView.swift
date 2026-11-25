import SwiftUI
import CarLyricsCore

/// The line being sung, word by word, Apple Music style: each word brightens as a soft edge sweeps
/// across it at its own pace and lifts slightly while sung. A word held for 1s or more (2–7
/// letters) swells letter by letter, spreads a little and glows, then settles.
///
/// Numbers from the published measurements of Apple's effect (AMLL, YouLy+, Spicy Lyrics agree);
/// written fresh. Only this one line redraws per frame (TimelineView(.animation) around it).
struct WordLineView: View {
    let words: [LyricsLine.Word]
    let lineEndMs: Int?
    /// The wall-clock moment the line starts (`lineDates`), and its song time.
    let lineStart: Date
    let lineTimeMs: Int
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let nowMs = lineTimeMs + Int(context.date.timeIntervalSince(lineStart) * 1000)
            words.enumerated().reduce(Text("")) { text, item in
                let (i, word) = item
                let piece = Text(word.text).customAttribute(WordIndex(i))
                return i == 0 ? piece : text + Text(" ") + piece
            }
            .font(.system(size: fontSize, weight: .bold))
            .textRenderer(WordLineRenderer(nowMs: nowMs, timings: timings, em: fontSize,
                                    swell: !ProcessInfo.processInfo.isLowPowerModeEnabled))
        }
    }

    /// Each word's [start, end): its own end, else the next word's start, else the line's end.
    private var timings: [(start: Int, end: Int)] {
        words.indices.map { i in
            let start = words[i].timeMs
            let next = i + 1 < words.count ? words[i + 1].timeMs : nil
            let end = words[i].endMs ?? next ?? lineEndMs ?? start + 600
            return (start, max(end, start + 1))
        }
    }
}

struct WordIndex: TextAttribute {
    let value: Int
    init(_ value: Int) { self.value = value }
}

struct WordLineRenderer: TextRenderer {
    let nowMs: Int
    let timings: [(start: Int, end: Int)]
    let em: CGFloat
    let swell: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let i = run[WordIndex.self]?.value, i < timings.count else {
                    context.opacity = 0.4
                    context.draw(run)
                    context.opacity = 1
                    continue
                }
                drawWord(run, timing: timings[i], in: context)
            }
        }
    }

    private func drawWord(_ run: Text.Layout.Run, timing: (start: Int, end: Int), in context: GraphicsContext) {
        let slices = Array(run)
        guard let first = slices.first, let last = slices.last else { return }
        let minX = first.typographicBounds.rect.minX
        let width = max(last.typographicBounds.rect.maxX - minX, 1)
        let duration = Double(timing.end - timing.start) / 1000
        let elapsed = Double(nowMs - timing.start) / 1000
        let p = min(max(elapsed / duration, 0), 1)

        // The bright edge: ±0.45em soft, crossing the word over its duration.
        let soft = em * 0.9
        let edge = p * (width + soft) - soft / 2
        // Lift while sung, settle by the end.
        let lift = -0.05 * em * sin(.pi * p)

        // Held word: 1s+, 2–7 letters (grapheme count ≈ glyphs once romanized).
        let n = slices.count
        let held = swell && duration >= 1 && (2...7).contains(n)
        let k = min(max(duration - 1, 0), 1)
        let glowMax = 0.45 * min(max((duration - 1) / 0.5, 0), 1)

        for (j, slice) in slices.enumerated() {
            let rect = slice.typographicBounds.rect
            var c = context
            let mid = rect.midX - minX
            c.opacity = 0.4 + 0.6 * min(max((edge - mid) / soft + 0.5, 0), 1)
            c.translateBy(x: 0, y: lift)
            if held {
                let stagger = min(0.4 * duration / Double(n), 0.4)
                let rise = max(2 * duration / Double(n), 0.05)
                let env = Self.envelope(elapsed - Double(j) * stagger, rise: rise, fall: min(duration, 3))
                if env > 0 {
                    let side = n > 1 ? (Double(j) - Double(n - 1) / 2) / (Double(n - 1) / 2) : 0
                    let scale = 1 + 0.1 * k * env
                    c.translateBy(x: 0.05 * em * k * env * side, y: -0.05 * em * k * env)
                    c.translateBy(x: rect.midX, y: rect.midY)
                    c.scaleBy(x: scale, y: scale)
                    c.translateBy(x: -rect.midX, y: -rect.midY)
                    if glowMax > 0 { c.addFilter(.shadow(color: .white.opacity(glowMax * env), radius: 0.18 * em)) }
                }
            }
            c.draw(slice)
        }
    }

    /// 0 → 1 over `rise` (smooth), then back to 0 over `fall`.
    static func envelope(_ t: Double, rise: Double, fall: Double) -> Double {
        func smooth(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
        guard t > 0 else { return 0 }
        return t < rise ? smooth(t / rise) : 1 - smooth((t - rise) / fall)
    }
}
