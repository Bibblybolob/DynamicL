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
        guard let snapshot = SharedNowPlaying.loadWatch() else {
            completion(Timeline(entries: [WatchLyricEntry.idle], policy: .after(.now.addingTimeInterval(900))))
            return
        }

        let now = Date.now
        let isPlaying = SharedNowPlaying.effectiveIsPlaying(snapshot)
        if isPlaying,
           let endEpoch = snapshot.playbackEndEpoch,
           Date(timeIntervalSince1970: endEpoch) <= now {
            completion(Timeline(entries: [WatchLyricEntry.idle], policy: .after(now.addingTimeInterval(900))))
            return
        }

        var entries = [entry(from: snapshot, at: now)]
        if isPlaying {
            for line in snapshot.scheduledLines where line.date > now {
            entries.append(entry(from: snapshot, at: line.date, line: line.text))
            }
        }

        if isPlaying,
           let endEpoch = snapshot.playbackEndEpoch {
            let endDate = Date(timeIntervalSince1970: endEpoch)
            if endDate > now {
                entries.removeAll { $0.date >= endDate }
                entries.append(.init(
                    date: endDate,
                    trackTitle: "No music",
                    currentLine: "Play something",
                    isPlaying: false
                ))
            }
        }

        let lastDate = entries.last?.date ?? .now
        let normalRefresh = lastDate.addingTimeInterval(entries.last?.isPlaying == false ? 900 : 30)
        let refresh = [normalRefresh, SharedNowPlaying.playingOverrideExpiration()]
            .compactMap { date in
                guard let date, date > now else { return nil }
                return date
            }
            .min() ?? normalRefresh
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    private func currentEntry() -> WatchLyricEntry {
        guard let snapshot = SharedNowPlaying.loadWatch() else { return .idle }
        let now = Date.now
        if SharedNowPlaying.effectiveIsPlaying(snapshot),
           let endEpoch = snapshot.playbackEndEpoch,
           endEpoch <= now.timeIntervalSince1970 {
            return .idle
        }
        return entry(from: snapshot, at: now)
    }

    private func entry(from snapshot: WidgetLyricSnapshot, at date: Date, line: String? = nil) -> WatchLyricEntry {
        WatchLyricEntry(
            date: date,
            trackTitle: snapshot.trackTitle,
            currentLine: line ?? snapshot.currentLine,
            isPlaying: SharedNowPlaying.effectiveIsPlaying(snapshot),
            artistName: snapshot.artistName,
            nextLine: snapshot.scheduledLines.first(where: { $0.date > date })?.text,
            albumImageData: snapshot.albumImageData
                ?? snapshot.albumImageURL.flatMap(ArtworkFileCache.data(for:))
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
#if os(watchOS)
        case .accessoryCorner:
            AccessoryCornerLyricView(entry: entry)
#endif
        default:
            AccessoryRectangularLyricView(entry: entry)
        }
    }
}

struct WatchLyricComplication: Widget {
    private var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ]
#if os(watchOS)
        families.append(.accessoryCorner)
#endif
        return families
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchLyricComplication", provider: WatchLyricProvider()) { entry in
            WatchLyricComplicationView(entry: entry)
        }
        .configurationDisplayName("Current Line")
        .description("Shows the live lyric line on your watch face.")
        .supportedFamilies(supportedFamilies)
    }
}

#Preview(as: .accessoryRectangular) {
    WatchLyricComplication()
} timeline: {
    WatchLyricEntry(date: .now, trackTitle: "Sample Track", currentLine: "La la la…", isPlaying: true)
}
