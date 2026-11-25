import WidgetKit
import SwiftUI
import ActivityKit

/// The Live Activity that renders lyrics. On iOS 26 this automatically appears on the
/// CarPlay widgets page (Settings › General › CarPlay › [car] › Widgets) with no CarPlay
/// entitlement — that is the whole trick behind this app category.
struct LyricsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            // Presentation is family-aware: the full lock-screen layout on the phone, a
            // tighter one-line layout in CarPlay / Watch Smart Stack (the `.small` family).
            LyricsActivityView(state: context.state)
                .foregroundStyle(context.state.ink)
                .activityBackgroundTint(context.state.background?.color ?? .clear) // clear → the system glass shows
                .activitySystemActionForegroundColor(context.state.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        // No karaoke here: it's small, and every sweep costs the extension CPU.
                        ClockedText(lines: context.state.lines ?? [], fallback: context.state.currentLine,
                                    style: context.state.transition == .karaoke ? .instant : context.state.transition ?? .instant)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        NextLine(lines: context.state.lines ?? [], fallback: context.state.nextLine,
                                 style: context.state.transition ?? .instant)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } minimal: {
                Image(systemName: "music.note")
            }
        }
        // iOS 26: `.small` is the size class CarPlay (and the Watch Smart Stack) render.
        // Without this, CarPlay falls back to the Dynamic Island compact views (just an icon).
        .supplementalActivityFamilies([.small])
    }
}

/// Picks the presentation for the current context. CarPlay and the Watch Smart Stack report
/// the `.small` family; the phone lock screen reports `.medium`.
struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        switch family {
        case .small: LyricsSmallView(state: state)      // CarPlay / Watch
        default: LyricsLockScreenView(state: state)     // phone lock screen (.medium)
        }
    }
}

/// CarPlay layout, Apple Music style: the current line, the next one smaller and dimmed below it
/// (lines slide up from one to the other, see ClockedText), then the progress bar and the song + time.
/// iOS gives it a fixed 227 × 90 pt box on CarPlay (2026-11-20 sysdiagnose), room for one row each. It's
/// the only lyrics surface that keeps time there: CarPlay draws plain widgets as still images.
struct LyricsSmallView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        // The bar (a Settings switch, on by default) costs a row, so the lyrics drop a size with it.
        let bar = state.showsProgress ?? true
        let (big, small): (CGFloat, CGFloat) = bar ? (18, 14) : (20, 16)
        VStack(alignment: .leading, spacing: 4) {
            // One row each at a fixed size: a line wider than the box is cut into parts shown in
            // turn (LyricFit), never shrunk.
            GeometryReader { geo in
                let style = state.transition ?? .instant
                let parts = LyricFit.split(state.lines ?? [], width: geo.size.width, font: LyricFit.font(big), rows: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ClockedText(lines: parts, fallback: state.currentLine, style: style, wordFontSize: big,
                                glow: !(state.background?.wantsDarkText ?? false))
                        .font(.lyric(big))
                        .lineLimit(1)
                    NextLine(lines: parts, fallback: state.nextLine, style: style)
                        .font(.lyric(small))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if bar { SongProgress(state: state) }
            HStack(spacing: 6) {
                SongTitle(state: state)
                Spacer(minLength: 0)
                SongTime(state: state).layoutPriority(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // CarPlay ignores `activityBackgroundTint` and always draws its glass (Akshat, 2026-11-25:
        // Album showed on the phone, never in the car), so paint Solid/Album here. The ShapeStyle
        // overload fills under any system margins too. Glass (nil) leaves CarPlay's own.
        .background { ArtBackdrop(state: state) }
    }
}

/// Behind the lyrics on CarPlay and the lock screen: the Album background's blurred artwork when the
/// app saved one, else the picked colour (CarPlay ignores `activityBackgroundTint`, so it's painted
/// here); nothing on Glass. A still image: no timers, no CPU after the first draw.
struct ArtBackdrop: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let name = state.art, let path = AppGroup.url?.appendingPathComponent(name).path,
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let color = state.background?.color {
            color
        }
    }
}

/// The large presentation used on the lock screen and CarPlay. Kept to 2–3 lines with a
/// large highlighted current line, per CarPlay's readability guidance.
struct LyricsLockScreenView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption)
                SongTitle(state: state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Fixed sizes: lines too long for two rows are cut into parts shown in turn (LyricFit).
            let style = state.transition ?? .instant
            let rows = style == .karaoke ? 1 : 2
            GeometryReader { geo in
                let lines = state.lines ?? []
                let parts = LyricFit.split(lines, width: geo.size.width, font: LyricFit.font(20), rows: rows)
                let words: CGFloat? = style == .karaoke ? 20 : nil
                if state.slide == true, let current = lines.first {
                    // The phone, away from CarPlay: the app pushes each line and iOS slides the next one
                    // up into place, like Apple Music's lyrics. Only the current line's parts are clocked.
                    let mine = lines.count > 1 ? parts.filter { $0.at < lines[1].at } : parts
                    VStack(alignment: .leading, spacing: 8) {
                        ClockedText(lines: mine, fallback: "", style: style, wordFontSize: words, revealFirst: false,
                                    glow: !(state.background?.wantsDarkText ?? false))
                            .font(.lyric(20))
                            .lineLimit(rows)
                        Text(lines.count > 1 ? lines[1].text : "")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .id(current.at)
                    .transition(.push(from: .bottom))
                    .animation(.smooth(duration: 0.45), value: current.at)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ClockedText(lines: parts, fallback: state.currentLine, style: style, wordFontSize: words,
                                    glow: !(state.background?.wantsDarkText ?? false))
                            .font(.lyric(20))
                            .lineLimit(rows)
                        NextLine(lines: parts, fallback: state.nextLine, style: style)
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .clipped()
            .frame(height: (LyricFit.font(20).lineHeight * CGFloat(rows) + 8 + UIFont.systemFont(ofSize: 17).lineHeight * 2).rounded(.up))
            if state.durationMs != nil {
                HStack(spacing: 8) {
                    SongProgress(state: state)
                    SongTime(state: state)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background { ArtBackdrop(state: state) }
    }
}

/// "1:23 / 3:54". While playing, the elapsed part is a SwiftUI timer that ticks on its own —
/// the app pushes only on line changes, never once a second. Hidden when the length is unknown.
struct SongTime: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let durationMs = state.durationMs, durationMs > 0 {
            let total = Self.clock(durationMs)
            if let start = state.songStart {
                Text("\(Text(timerInterval: start...start.addingTimeInterval(Double(durationMs) / 1000), countsDown: false)) / \(total)")
                    .monospacedDigit()
            } else {
                Text("\(Self.clock(state.pausedPositionMs ?? 0)) / \(total)")
                    .monospacedDigit()
            }
        }
    }

    static func clock(_ ms: Int) -> String {
        Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))
    }
}

/// Song progress bar; runs live from `songStart` like `SongTime`, static while paused.
struct SongProgress: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let durationMs = state.durationMs, durationMs > 0 {
            Group {
                if let start = state.songStart {
                    ProgressView(timerInterval: start...start.addingTimeInterval(Double(durationMs) / 1000),
                                 countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: Double(min(state.pausedPositionMs ?? 0, durationMs)), total: Double(durationMs))
                }
            }
            .tint(state.ink)
        }
    }
}

/// The current lyric. While playing synced lyrics, `lines` holds the upcoming lines with start
/// times and every one is drawn in the same spot, each masked to [its start, the next start) by
/// timer ProgressViews. iOS animates those on its own clock like the song timer, so lines switch on
/// time with no push per line. ponytail: masking with timer views isn't a documented use; if a future
/// iOS stops animating them, lines freeze until the next window push (every 8 lines).
///
/// `style` is built from the same sweep, since nothing else animates in a Live Activity (no fades or
/// moves): lines change by a 0.3s bottom → top sweep, the new line rising in under the old one as
/// both rows scroll up (Apple Music style; a real move would need a push per line, which CarPlay
/// throttles). `wipe` reveals the new line left → right instead; `karaoke` also draws the line dim
/// and lights it left → right over its own duration.
struct ClockedText: View {
    let lines: [LyricsActivityAttributes.TimedLine]
    let fallback: String
    var placeholder = "♪ ♪ ♪" // for instrumental gaps
    var style: LyricsActivityAttributes.Transition = .instant
    /// The lyric font size, given where Karaoke sweeps word by word (CarPlay, lock screen); nil = one
    /// sweep per line, from the first word's start to the last word's end when the words are known.
    var wordFontSize: CGFloat? = nil
    /// The first line is already on screen (the phone's per-line slide brought it in): no reveal sweep.
    var revealFirst = true
    /// Held words glow (white): off on light backgrounds, where the text is black.
    var glow = true

    var body: some View {
        if lines.isEmpty {
            // Pushed per line (Morph, paused): iOS morphs the old text into the new.
            // Paused / Morph only. ponytail: may still shrink; the clocked path below never does.
            Text(fallback.isEmpty ? placeholder : fallback)
                .minimumScaleFactor(0.6)
                .contentTransition(.interpolate)
        } else {
            let sweep = style == .wipe ? 0.4 : 0.3
            let upward = style != .wipe
            ZStack(alignment: .leading) {
                ForEach(lines.indices, id: \.self) { i in
                    line(i)
                        .mask {
                            if i == 0 && !revealFirst { Color.black } else { Step(at: lines[i].at, duration: sweep, upward: upward) }
                        }
                        .mask {
                            // Hidden wherever the next line has already swept in.
                            if i + 1 < lines.count {
                                Step(at: lines[i + 1].at, duration: sweep, inverted: true, upward: upward)
                            } else { Color.black }
                        }
                }
            }
        }
    }

    @ViewBuilder private func line(_ i: Int) -> some View {
        let text = Text(lines[i].text.isEmpty ? placeholder : lines[i].text)
        if style == .karaoke {
            // One row: a left → right sweep can't follow text onto a second row (it lit both rows at
            // once). Callers cut lines to one row's worth (LyricFit, rows: 1) for karaoke.
            let row = text.lineLimit(1)
            let words = lines[i].words
            if let size = wordFontSize, let words {
                let font = LyricFit.font(size)
                let pieces = WordSweep.segments(words, text: lines[i].text, font: font)
                let held = WordSweep.held(words, text: lines[i].text, font: font)
                row.opacity(0.4)
                    .overlay { row.mask { WordMask(at: lines[i].at, segments: pieces) } }
                    .overlay {
                        // Held words glow while sung (Apple Music's swell can't be drawn here: only
                        // timers animate). The glow follows the sweep in, and wipes off when the word ends.
                        // Drawn with 2× its radius of room all round, so the mask's edges fall where the
                        // glow has already faded (a tight mask showed as a box).
                        if glow {
                            let g = size * 0.22
                            ForEach(held.indices, id: \.self) { h in
                                let w = held[h]
                                let span = WordSweep.Segment(x0: w.x0, x1: w.x1 + 4 * g, t0: w.t0, t1: w.t1)
                                row.shadow(color: .white.opacity(0.85), radius: g)
                                    .padding(2 * g)
                                    // Timer masks have hard edges; blurred, the glow fades in and out softly.
                                    .mask { WordMask(at: lines[i].at, segments: [span]).blur(radius: g) }
                                    .mask {
                                        HStack(spacing: 0) {
                                            Color.black.frame(width: w.x0)
                                            Step(at: lines[i].at.addingTimeInterval(w.t1), duration: 0.35, inverted: true)
                                                .frame(width: max(span.x1 - span.x0, 1))
                                            Color.black
                                        }
                                        .blur(radius: g)
                                    }
                                    .padding(-2 * g)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let start = words?.first?.start ?? 0
                let sung = words.map { $0.last!.end - start }
                    ?? (i + 1 < lines.count ? lines[i + 1].at.timeIntervalSince(lines[i].at) : 3)
                row.opacity(0.4)
                    .overlay { row.mask { Step(at: lines[i].at.addingTimeInterval(start), duration: max(sung, 0.2)) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The dimmed read-ahead line: during line i it shows line i+1 (nothing after the last). Same
/// transition as the current line, except karaoke, which only makes sense on the line being sung.
struct NextLine: View {
    let lines: [LyricsActivityAttributes.TimedLine]
    let fallback: String?
    let style: LyricsActivityAttributes.Transition

    var body: some View {
        if lines.isEmpty {
            if let fallback, !fallback.isEmpty { Text(fallback).contentTransition(.interpolate) }
        } else {
            ClockedText(lines: LyricFit.ahead(lines, by: 1), fallback: "", placeholder: "",
                        style: style == .wipe ? .wipe : .instant)
        }
    }
}

/// A mask revealed left → right from `at` over `duration` (`inverted`: hidden left → right instead;
/// `upward`: bottom → top): a timer ProgressView stretched over the whole text. Its grey track would
/// leak every other line as a faint ghost, so it's flattened onto black and contrast-boosted: the
/// white fill stays white (opaque), the track drops to black (clear).
struct Step: View {
    let at: Date
    var duration: TimeInterval = 0.1
    var inverted = false
    var upward = false

    var body: some View {
        let fill = ZStack {
            Color.black
            if upward {
                // The same bar stood on end: its leading (filling) end turned to the bottom.
                GeometryReader { g in
                    bar.frame(width: g.size.height)
                        .scaleEffect(x: 1.1, y: 150)
                        .rotationEffect(.degrees(-90))
                        .frame(width: g.size.width, height: g.size.height)
                }
            } else {
                bar.scaleEffect(x: 1.1, y: 60)
            }
        }
        .compositingGroup()
        .contrast(3)
        Group {
            if inverted { fill.colorInvert() } else { fill }
        }
        .luminanceToAlpha()
    }

    private var bar: some View {
        ProgressView(timerInterval: at...at.addingTimeInterval(duration), countsDown: false) {
            EmptyView()
        } currentValueLabel: { EmptyView() }
            .progressViewStyle(.linear)
            .tint(.white)
    }
}

/// Karaoke word by word (CarPlay): one timer bar per WordSweep piece, each laid over its words'
/// width and clipped to it, all flattened once (not once per piece) like `Step`. A bar fills only its
/// middle 1/1.1 inside the frame (the 1.1 overscan that hides its rounded ends), so each runs 5% of
/// its time early and late to cross its words exactly on [t0, t1].
struct WordMask: View {
    let at: Date
    let segments: [WordSweep.Segment]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(segments.indices, id: \.self) { j in
                    let s = segments[j]
                    let d = max(s.t1 - s.t0, 0.05)
                    let w = max(s.x1 - s.x0, 1)
                    ProgressView(timerInterval: at.addingTimeInterval(s.t0 - 0.05 * d)...at.addingTimeInterval(s.t1 + 0.05 * d),
                                 countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: w)
                        .scaleEffect(x: 1.1, y: 60)
                        .frame(width: w, height: g.size.height)
                        .clipped()
                        .offset(x: s.x0)
                }
            }
            .compositingGroup()
            .contrast(3)
            .luminanceToAlpha()
        }
    }
}

/// "Title — Artist" when it fits, else just the title, shrunk as a last resort, so the song name
/// is never what gets cut. (A Live Activity can't scroll text: only system timers animate.)
struct SongTitle: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(state.title) — \(state.artist)")
            Text(state.title)
            Text(state.title).minimumScaleFactor(0.6)
        }
        .lineLimit(1)
    }
}

extension LyricsActivityAttributes.ContentState {
    /// Text colour for the background: the system's primary on glass, else black or white.
    var ink: Color { background.map { $0.wantsDarkText ? .black : .white } ?? .primary }
}

extension Font {
    /// Matches `LyricFit.font`, which measures the lines.
    static func lyric(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

extension LyricsActivityAttributes.RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}
