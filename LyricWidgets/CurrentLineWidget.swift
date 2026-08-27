import WidgetKit
import SwiftUI
import LyricCore

struct LyricEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let currentLine: String
    let isPlaying: Bool

    static let sample = LyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        currentLine: "Waiting for music…",
        isPlaying: true
    )

    static let idle = LyricEntry(
        date: .now,
        trackTitle: "No music",
        currentLine: "Play something to see lyrics here.",
        isPlaying: false
    )
}

/// Applies the optimistic play/pause flip (if any) written by the widget's
/// toggle button, so widgets react instantly instead of waiting for Spotify.
func effectiveIsPlaying(_ snapshot: WidgetLyricSnapshot) -> Bool {
    if let override = SharedNowPlaying.playingOverride() {
        return override
    }
    return snapshot.isPlaying
}

struct CurrentLineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricEntry) -> Void) {
        if let snapshot = SharedNowPlaying.load() {
            completion(LyricEntry(snapshot: snapshot, date: .now, line: snapshot.currentLine))
        } else {
            completion(.idle)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricEntry>) -> Void) {
        guard let snapshot = SharedNowPlaying.load() else {
            completion(Timeline(entries: [.idle], policy: .after(.now.addingTimeInterval(900))))
            return
        }

        var entries = [LyricEntry(snapshot: snapshot, date: .now, line: snapshot.currentLine)]
        for line in snapshot.scheduledLines where line.date > .now {
            entries.append(LyricEntry(snapshot: snapshot, date: line.date, line: line.text))
        }

        let lastDate = entries.last?.date ?? .now
        let refresh = lastDate.addingTimeInterval(snapshot.isPlaying ? 30 : 900)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

private extension LyricEntry {
    init(snapshot: WidgetLyricSnapshot, date: Date, line: String) {
        self.init(date: date, trackTitle: snapshot.trackTitle, currentLine: line, isPlaying: effectiveIsPlaying(snapshot))
    }
}

// MARK: - Home Screen families (systemSmall / systemMedium / systemLarge)

struct HomeScreenLyricView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(entry.trackTitle)
                    .font(family == .systemSmall ? .caption2 : .footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                TogglePlaybackButton(isPlaying: entry.isPlaying, font: family == .systemSmall ? .footnote : .title3)
                    .tint(.pink)
            }
            Text(entry.currentLine)
                .font(family == .systemSmall ? .caption : .body)
                .fontWeight(.medium)
                .lineLimit(lineLimit)
                .allowsTightening(true)
                .minimumScaleFactor(family == .systemSmall ? 0.7 : 0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [.pink.opacity(0.25), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var lineLimit: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 6
        }
    }
}

// MARK: - Lock Screen accessory families

struct AccessoryRectangularLyricView: View {
    let entry: LyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "music.quarternote.3")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                    .symbolRenderingMode(.monochrome)
                Text(entry.trackTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.currentLine)
                .font(.footnote.weight(.medium))
                .lineLimit(3)
                .allowsTightening(true)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
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

struct AccessoryCircularLyricView: View {
    let entry: LyricEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(entry.isPlaying ? .pink : .secondary)
                    .symbolRenderingMode(.monochrome)
                Text(entry.trackTitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct AccessoryInlineLyricView: View {
    let entry: LyricEntry

    var body: some View {
        Text(entry.isPlaying ? "♪ \(entry.currentLine)" : "❙❙ \(entry.currentLine)")
            .font(.headline)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .containerBackground(for: .widget) {
                Color.clear
            }
    }
}

struct CurrentLineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            AccessoryRectangularLyricView(entry: entry)
        case .accessoryCircular:
            AccessoryCircularLyricView(entry: entry)
        case .accessoryInline:
            AccessoryInlineLyricView(entry: entry)
        default:
            HomeScreenLyricView(entry: entry)
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
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

#Preview(as: .systemMedium) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .accessoryRectangular) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .accessoryCircular) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .accessoryInline) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}
