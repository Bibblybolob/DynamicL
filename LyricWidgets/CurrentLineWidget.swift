import WidgetKit
import SwiftUI
import LyricCore

struct LyricEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let currentLine: String
    let albumImageURL: String?
    let albumImageData: Data?
    let isPlaying: Bool

    static let sample = LyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        currentLine: "Waiting for music…",
        albumImageURL: nil,
        albumImageData: nil,
        isPlaying: true
    )

    static let idle = LyricEntry(
        date: .now,
        trackTitle: "No music",
        currentLine: "Play something to see lyrics here.",
        albumImageURL: nil,
        albumImageData: nil,
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

struct WidgetStyle {
    let prefs: LAStylePrefs
    let palette: LAPalette

    init() {
        prefs = LAStyleStore.load()
        palette = LAStyleStore.resolve(prefs: prefs, albumDominant: nil)
    }

    var showsArtwork: Bool {
        prefs.layout == .player && prefs.artworkStyle != .hidden
    }

    var showsTrackInfo: Bool {
        prefs.layout != .minimal && prefs.showTrackInfo
    }

    var showsControls: Bool {
        prefs.layout != .minimal && prefs.showControls
    }

    var textAlignment: SwiftUI.TextAlignment {
        prefs.textAlignment == .center ? .center : .leading
    }
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
        self.init(
            date: date,
            trackTitle: snapshot.trackTitle,
            currentLine: line,
            albumImageURL: snapshot.albumImageURL,
            albumImageData: SharedNowPlaying.cachedArtwork(for: snapshot.albumImageURL),
            isPlaying: effectiveIsPlaying(snapshot)
        )
    }
}

// MARK: - Home Screen families (systemSmall / systemMedium / systemLarge)

struct HomeScreenLyricView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        HStack(alignment: .center, spacing: family == .systemSmall ? 8 : 12) {
            VStack(alignment: style.prefs.textAlignment.horizontal, spacing: 5) {
                if style.showsTrackInfo {
                    HStack(spacing: 4) {
                        Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(style.palette.accent.color)
                        Text(entry.trackTitle)
                            .font(family == .systemSmall ? .caption2 : .footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(style.palette.text.color.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Text(entry.currentLine)
                    .font(family == .systemSmall ? .caption : .body)
                    .fontWeight(.medium)
                    .foregroundStyle(style.palette.text.color)
                    .lineLimit(lineLimit)
                    .allowsTightening(true)
                    .minimumScaleFactor(family == .systemSmall ? 0.7 : 0.75)
                    .multilineTextAlignment(style.textAlignment)
                    .frame(maxWidth: .infinity,
                           alignment: style.prefs.textAlignment.alignment)
                    .clipped()
                if style.showsControls {
                    HStack(spacing: 0) {
                        SkipTrackButton(direction: .previous, font: .caption2)
                        TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                            .tint(style.palette.text.color)
                        SkipTrackButton(direction: .next, font: .caption2)
                    }
                    .frame(height: 24, alignment: style.prefs.textAlignment.alignment)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if style.showsArtwork {
                LAAlbumDisc(
                    urlString: entry.albumImageURL,
                    size: family == .systemSmall ? 62 : 82,
                    imageData: entry.albumImageData,
                    style: style.prefs.artworkStyle
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(family == .systemSmall ? 8 : 12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [style.palette.backgroundTop.color,
                         style.palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
        let style = WidgetStyle()
        VStack(alignment: style.prefs.textAlignment.horizontal, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "music.quarternote.3")
                    .font(.caption2)
                    .foregroundStyle(style.palette.accent.color)
                    .symbolRenderingMode(.monochrome)
                if style.showsTrackInfo {
                    Text(entry.trackTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(style.palette.text.color.opacity(0.75))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if style.showsControls {
                    TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                        .tint(style.palette.text.color)
                }
            }
            Text(entry.currentLine)
                .font(.footnote.weight(.medium))
                .foregroundStyle(style.palette.text.color)
                .lineLimit(3)
                .allowsTightening(true)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(style.textAlignment)
                .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
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
        let style = WidgetStyle()
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(entry.isPlaying ? style.palette.accent.color : style.palette.text.color.opacity(0.55))
                    .symbolRenderingMode(.monochrome)
                Text(entry.trackTitle)
                    .font(.system(size: 8))
                    .foregroundStyle(style.palette.text.color.opacity(0.75))
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
        let style = WidgetStyle()
        Text(entry.isPlaying ? "♪ \(entry.currentLine)" : "❙❙ \(entry.currentLine)")
            .font(.headline)
            .foregroundStyle(style.palette.text.color)
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
