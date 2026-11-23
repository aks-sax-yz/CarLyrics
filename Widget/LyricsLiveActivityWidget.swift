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
                        ClockedText(lines: context.state.lines ?? [], fallback: context.state.currentLine,
                                    style: context.state.transition ?? .instant)
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
/// (lines slide up from one to the other, see ClockedText), and the song along the bottom. iOS gives
/// it a fixed 227 × 90 pt box on CarPlay (2026-11-20 sysdiagnose), room for one row of each. It's
/// the only lyrics surface that keeps time there: CarPlay draws plain widgets as still images.
struct LyricsSmallView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // One row each at a fixed size: a line wider than the box is cut into parts shown in
            // turn (LyricFit), never shrunk.
            GeometryReader { geo in
                let style = state.transition ?? .instant
                let parts = LyricFit.split(state.lines ?? [], width: geo.size.width, font: LyricFit.font(20), rows: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ClockedText(lines: parts, fallback: state.currentLine, style: style)
                        .font(.lyric(20))
                        .lineLimit(1)
                    NextLine(lines: parts, fallback: state.nextLine, style: style)
                        .font(.lyric(16))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
                let parts = LyricFit.split(state.lines ?? [], width: geo.size.width, font: LyricFit.font(20), rows: rows)
                VStack(alignment: .leading, spacing: 8) {
                    ClockedText(lines: parts, fallback: state.currentLine, style: style)
                        .font(.lyric(20))
                        .lineLimit(rows)
                    NextLine(lines: parts, fallback: state.nextLine, style: style)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
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

    var body: some View {
        if lines.isEmpty {
            // Pushed per line (Morph, paused, Listen): iOS morphs the old text into the new.
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
                        .mask { Step(at: lines[i].at, duration: sweep, upward: upward) }
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
            let sung = max(i + 1 < lines.count ? lines[i + 1].at.timeIntervalSince(lines[i].at) : 3, 0.2)
            let row = text.lineLimit(1)
            row.opacity(0.4)
                .overlay { row.mask { Step(at: lines[i].at, duration: sung) } }
                .frame(maxWidth: .infinity, alignment: .leading)
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
