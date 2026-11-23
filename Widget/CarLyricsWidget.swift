import WidgetKit
import SwiftUI

/// The lyrics widget for CarPlay's widget page (iOS 26+ shows any systemSmall widget there) and the
/// Home Screen: the current line big, the next two dimmed below, Apple Music style. The app hands it
/// the whole song once through the App Group (`WidgetFeed`); each line is its own timeline entry,
/// which iOS switches on its own schedule (see `WidgetFeed.timeline`).
struct CarLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFeed.kind, provider: LyricsTimeline()) { entry in
            CarLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyrics")
        .description("Synced lyrics in big type, with the next lines. Add it to CarPlay in Settings › General › CarPlay.")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(false) // black text on a light pick must keep its background
    }
}

struct LyricsEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeed
    let moment: WidgetFeed.Moment
}

struct LyricsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry { entries(.sample, context).first! }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        completion(entries(context.isPreview ? .sample : WidgetFeed.load() ?? .idle, context).first!)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        let feed = WidgetFeed.load() ?? .idle
        // The app reloads this on every song change. In case iOS drops one (it budgets reloads),
        // look again just after the song ends.
        let policy: TimelineReloadPolicy = feed.lines.last.map { .after($0.at.addingTimeInterval(20)) } ?? .never
        completion(Timeline(entries: entries(feed, context), policy: policy))
    }

    private func entries(_ feed: WidgetFeed, _ context: Context) -> [LyricsEntry] {
        // ponytail: the system content margins (16pt on iPhone) plus slack, since CarPlay adapts them.
        let width = context.displaySize.width - 40
        return feed.timeline(now: .now, width: width).map { LyricsEntry(date: $0.date, feed: feed, moment: $0) }
    }
}

struct CarLyricsWidgetView: View {
    let entry: LyricsEntry
    private var feed: WidgetFeed { entry.feed }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(feed.background.map { $0.wantsDarkText ? Color.black : .white } ?? .primary)
            .containerBackground(for: .widget) {
                if let background = feed.background { background.color } else { Color(.systemBackground) }
            }
    }

    @ViewBuilder private var content: some View {
        if feed.title.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Car Lyrics").font(.headline)
                Text(AppGroup.url == nil ? "Open Car Lyrics once to connect this widget."
                                         : "Play a song in Apple Music.")
                    .font(.caption).opacity(0.7)
            }
        } else if feed.lines.isEmpty && feed.currentLine.isEmpty {
            // Fetching, or no synced lyrics: the song instead.
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.title).font(.lyric(WidgetFeed.bigSize)).lineLimit(3)
                Text(feed.artist).font(.lyric(WidgetFeed.smallSize)).opacity(0.55).lineLimit(2)
            }
        } else {
            let next = entry.moment.next
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.moment.current.isEmpty ? "♪ ♪ ♪" : entry.moment.current)
                    .font(.lyric(WidgetFeed.bigSize))
                    .lineLimit(2)
                    .frame(height: Self.height(WidgetFeed.bigSize, rows: 2), alignment: .topLeading)
                Text(next.first ?? "")
                    .font(.lyric(WidgetFeed.smallSize))
                    .opacity(0.55)
                    .lineLimit(2)
                    .frame(height: Self.height(WidgetFeed.smallSize, rows: 2), alignment: .topLeading)
                // Whatever fits, faded out at the bottom edge like a scrolling list, instead of "…".
                Text(next.count > 1 ? next[1] : "")
                    .font(.lyric(WidgetFeed.smallSize))
                    .opacity(0.3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.3), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            // Lines move up into place as each entry takes over, like Apple Music's scroll.
            .id(entry.date)
            .transition(.push(from: .bottom))
        }
    }

    private static func height(_ size: CGFloat, rows: Int) -> CGFloat {
        (LyricFit.font(size).lineHeight * CGFloat(rows)).rounded(.up)
    }
}

extension WidgetFeed {
    /// The widget gallery's preview.
    static let sample = WidgetFeed(title: "Car Lyrics", artist: "", currentLine: "Lyrics show up here",
                                   nextLines: ["in time with the song,", "the next lines below"], background: nil)
}
