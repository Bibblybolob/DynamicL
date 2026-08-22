import WidgetKit
import SwiftUI

struct LyricEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let currentLine: String

    static let sample = LyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        currentLine: "Waiting for music…"
    )
}

struct CurrentLineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricEntry) -> Void) {
        completion(.sample)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricEntry>) -> Void) {
        let entry = LyricEntry(date: .now, trackTitle: "No music", currentLine: "Play something to see lyrics here.")
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct CurrentLineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.trackTitle)
                .font(family == .systemSmall ? .caption2 : .footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.currentLine)
                .font(family == .systemSmall ? .caption : .body)
                .fontWeight(.medium)
                .lineLimit(family == .systemSmall ? 3 : 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [.pink.opacity(0.25), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct CurrentLineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CurrentLineWidget", provider: CurrentLineProvider()) { entry in
            CurrentLineWidgetView(entry: entry)
        }
        .configurationDisplayName("Current Line")
        .description("Shows the live lyric line for the song you're playing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

#Preview(as: .systemMedium) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}
