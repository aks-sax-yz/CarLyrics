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
                        NextLine(state: context.state)
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

/// Compact one-glance layout for CarPlay: the current lyric line big, title tiny above it.
/// Drivers get one readable line, not a paragraph.
struct LyricsSmallView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SongTitle(state: state)
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Long lines wrap to 2 lines and shrink to fit rather than end in "…"; the lyric
            // wins the height over the title row.
            ClockedText(lines: state.lines ?? [], fallback: state.currentLine, style: state.transition ?? .instant)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
            Spacer(minLength: 0)
            // The song clock along the bottom (bar + "1:23 / 3:54"), so it doesn't take the title's room.
            HStack(spacing: 6) {
                SongProgress(state: state)
                SongTime(state: state)
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
            ClockedText(lines: state.lines ?? [], fallback: state.currentLine, style: state.transition ?? .instant)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
            NextLine(state: state)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
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
/// slides): `wipe` reveals the new line left → right over the old one; `karaoke` draws the line dim
/// and lights it left → right over its own duration.
struct ClockedText: View {
    let lines: [LyricsActivityAttributes.TimedLine]
    let fallback: String
    var placeholder = "♪ ♪ ♪" // for instrumental gaps
    var style: LyricsActivityAttributes.Transition = .instant

    var body: some View {
        if lines.isEmpty {
            // Pushed per line (Morph, paused, Listen): iOS morphs the old text into the new.
            Text(fallback.isEmpty ? placeholder : fallback)
                .contentTransition(.interpolate)
        } else {
            let sweep = style == .wipe ? 0.4 : 0.1
            ZStack(alignment: .leading) {
                ForEach(lines.indices, id: \.self) { i in
                    line(i)
                        .mask { Step(at: lines[i].at, duration: sweep) }
                        .mask {
                            // Hidden wherever the next line has already swept in.
                            if i + 1 < lines.count { Step(at: lines[i + 1].at, duration: sweep, inverted: true) } else { Color.black }
                        }
                }
            }
        }
    }

    @ViewBuilder private func line(_ i: Int) -> some View {
        let text = Text(lines[i].text.isEmpty ? placeholder : lines[i].text)
        if style == .karaoke {
            // One row, shrunk to fit: a left → right sweep can't follow text onto a second row (it
            // lit both rows at once), and a per-row sweep would need the wrap point, which the
            // widget can't know. Long lines are split at 32 chars anyway, so the shrink is mild.
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
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        let lines = state.lines ?? []
        if lines.isEmpty {
            if let next = state.nextLine, !next.isEmpty { Text(next).contentTransition(.interpolate) }
        } else {
            ClockedText(lines: lines.indices.map { .init(text: $0 + 1 < lines.count ? lines[$0 + 1].text : "", at: lines[$0].at) },
                        fallback: "", placeholder: "", style: state.transition == .wipe ? .wipe : .instant)
        }
    }
}

/// A mask revealed left → right from `at` over `duration` (`inverted`: hidden left → right instead):
/// a timer ProgressView stretched over the whole text. Its grey track would leak every other line as
/// a faint ghost, so it's flattened onto black and contrast-boosted: the white fill stays white
/// (opaque), the track drops to black (clear).
struct Step: View {
    let at: Date
    var duration: TimeInterval = 0.1
    var inverted = false

    var body: some View {
        let fill = ZStack {
            Color.black
            ProgressView(timerInterval: at...at.addingTimeInterval(duration), countsDown: false) {
                EmptyView()
            } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(.white)
                .scaleEffect(x: 1.1, y: 60)
        }
        .compositingGroup()
        .contrast(3)
        Group {
            if inverted { fill.colorInvert() } else { fill }
        }
        .luminanceToAlpha()
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

extension LyricsActivityAttributes.RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}
