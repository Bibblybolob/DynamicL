import WidgetKit
import SwiftUI
import LyricCore

struct WatchLyricEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artistName: String
    let currentLine: String
    let nextLine: String?
    let albumImageData: Data?
    let isPlaying: Bool

    init(
        date: Date,
        trackTitle: String,
        currentLine: String,
        isPlaying: Bool,
        artistName: String = "OpenLyrics",
        nextLine: String? = nil,
        albumImageData: Data? = nil
    ) {
        self.date = date
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.currentLine = currentLine
        self.nextLine = nextLine
        self.albumImageData = albumImageData
        self.isPlaying = isPlaying
    }

    static let idle = WatchLyricEntry(
        date: .now,
        trackTitle: "No music",
        currentLine: "Play something",
        isPlaying: false
    )
}

struct WatchLyricProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchLyricEntry {
        WatchLyricEntry(date: .now, trackTitle: "Sample Track", currentLine: "La la la…", isPlaying: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchLyricEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchLyricEntry>) -> Void) {
        guard let snapshot = SharedNowPlaying.load() else {
            completion(Timeline(entries: [WatchLyricEntry.idle], policy: .after(.now.addingTimeInterval(900))))
            return
        }

        var entries = [entry(from: snapshot, at: .now)]
        for line in snapshot.scheduledLines where line.date > .now {
            entries.append(entry(from: snapshot, at: line.date, line: line.text))
        }

        let lastDate = entries.last?.date ?? .now
        let refresh = lastDate.addingTimeInterval(snapshot.isPlaying ? 30 : 900)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    private func currentEntry() -> WatchLyricEntry {
        guard let snapshot = SharedNowPlaying.load() else { return .idle }
        return entry(from: snapshot, at: .now)
    }

    private func entry(from snapshot: WidgetLyricSnapshot, at date: Date, line: String? = nil) -> WatchLyricEntry {
        WatchLyricEntry(
            date: date,
            trackTitle: snapshot.trackTitle,
            currentLine: line ?? snapshot.currentLine,
            isPlaying: snapshot.isPlaying,
            artistName: snapshot.artistName,
            nextLine: snapshot.scheduledLines.first(where: { $0.date > date })?.text,
            albumImageData: snapshot.albumImageData
                ?? SharedNowPlaying.cachedArtwork(for: snapshot.albumImageURL)
        )
    }
}

// MARK: - Complication views

struct AccessoryCircularLyricView: View {
    let entry: WatchLyricEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                    .font(.title3)
                Text(entry.trackTitle)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct AccessoryRectangularLyricView: View {
    let entry: WatchLyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.trackTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.currentLine)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            if !entry.isPlaying {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct AccessoryInlineLyricView: View {
    let entry: WatchLyricEntry

    var body: some View {
        Text(entry.isPlaying ? "♪ \(entry.currentLine)" : "❙❙ \(entry.currentLine)")
            .font(.headline)
            .lineLimit(1)
            .containerBackground(for: .widget) {
                Color.clear
            }
    }
}

struct AccessoryCornerLyricView: View {
    let entry: WatchLyricEntry

    var body: some View {
        Text(entry.currentLine)
            .font(.headline)
            .lineLimit(1)
            .containerBackground(for: .widget) {
                Color.clear
            }
            .widgetLabel {
                Text(entry.trackTitle)
            }
    }
}

struct WatchLyricComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchLyricEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularLyricView(entry: entry)
        case .accessoryInline:
            AccessoryInlineLyricView(entry: entry)
        case .accessoryCorner:
            AccessoryCornerLyricView(entry: entry)
        default:
            AccessoryRectangularLyricView(entry: entry)
        }
    }
}

struct WatchLyricComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchLyricComplication", provider: WatchLyricProvider()) { entry in
            WatchLyricComplicationView(entry: entry)
        }
        .configurationDisplayName("Current Line")
        .description("Shows the live lyric line on your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

#Preview(as: .accessoryRectangular) {
    WatchLyricComplication()
} timeline: {
    WatchLyricEntry(date: .now, trackTitle: "Sample Track", currentLine: "La la la…", isPlaying: true)
}
