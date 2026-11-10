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
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(context.state.currentLine.isEmpty ? "♪" : context.state.currentLine)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if let next = context.state.nextLine {
                            Text(next)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
        VStack(alignment: .leading, spacing: 2) {
            Text("\(state.title) — \(state.artist)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(state.currentLine.isEmpty ? "♪ ♪ ♪" : state.currentLine)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
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
                Text("\(state.title) — \(state.artist)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(state.currentLine.isEmpty ? "♪ ♪ ♪" : state.currentLine)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let next = state.nextLine, !next.isEmpty {
                Text(next)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
