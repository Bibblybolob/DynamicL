import WidgetKit
import SwiftUI
import LyricCore

struct LyricEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artistName: String
    let currentLine: String
    let nextLine: String?
    let albumImageURL: String?
    let albumImageData: Data?
    let isPlaying: Bool

    static let sample = LyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        artistName: "OpenLyrics",
        currentLine: "Waiting for music…",
        nextLine: "Play a song to begin",
        albumImageURL: nil,
        albumImageData: nil,
        isPlaying: true
    )

    static let idle = LyricEntry(
        date: .now,
        trackTitle: "No music",
        artistName: "OpenLyrics",
        currentLine: "Play something to see lyrics here.",
        nextLine: nil,
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
            artistName: snapshot.artistName,
            currentLine: line,
            nextLine: snapshot.scheduledLines.first(where: { $0.date > date })?.text,
            albumImageURL: snapshot.albumImageURL,
            albumImageData: snapshot.albumImageData
                ?? SharedNowPlaying.cachedArtwork(for: snapshot.albumImageURL),
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
        case .systemExtraLarge: 8
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
            .systemExtraLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Additional Home Screen layouts

/// A compact player layout for users who want album art and controls without
/// giving the widget most of the Home Screen.
struct AlbumPlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AlbumPlayerWidget", provider: CurrentLineProvider()) { entry in
            AlbumPlayerWidgetView(entry: entry)
        }
        .configurationDisplayName("Album Player")
        .description("Shows the current album, track, lyric, and controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AlbumPlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        HStack(spacing: family == .systemSmall ? 9 : 12) {
            if style.prefs.artworkStyle != .hidden {
                LAAlbumDisc(
                    urlString: entry.albumImageURL,
                    size: family == .systemSmall ? 58 : 76,
                    imageData: entry.albumImageData,
                    style: .square
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.trackTitle)
                    .font(family == .systemSmall ? .caption : .subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(style.palette.text.color)
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.caption2)
                    .foregroundStyle(style.palette.text.color.opacity(0.65))
                    .lineLimit(1)
                Text(entry.currentLine)
                    .font(family == .systemSmall ? .caption2 : .footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(style.palette.text.color)
                    .lineLimit(family == .systemSmall ? 2 : 2)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    SkipTrackButton(direction: .previous, font: .caption2)
                    TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                        .tint(style.palette.text.color)
                    SkipTrackButton(direction: .next, font: .caption2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(family == .systemSmall ? 9 : 12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [style.palette.backgroundTop.color,
                         style.palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// A lyric-first layout that shows the current line and the next scheduled
/// line. It is useful when reading is more important than album artwork.
struct LyricFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LyricFocusWidget", provider: CurrentLineProvider()) { entry in
            LyricFocusWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyric Focus")
        .description("Shows the current and next lyric lines.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct LyricFocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(style.palette.accent.color)
                Text(entry.trackTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.palette.text.color.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.artistName)
                    .font(.caption2)
                    .foregroundStyle(style.palette.text.color.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Text(entry.currentLine)
                .font(family == .systemLarge ? .title3 : .headline)
                .fontWeight(.bold)
                .foregroundStyle(style.palette.text.color)
                .lineLimit(family == .systemLarge ? 4 : 3)
                .allowsTightening(true)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
                .multilineTextAlignment(style.textAlignment)
            if let nextLine = entry.nextLine {
                Text(nextLine)
                    .font(.caption)
                    .foregroundStyle(style.palette.text.color.opacity(0.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
                    .multilineTextAlignment(style.textAlignment)
            }
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                SkipTrackButton(direction: .previous, font: .caption)
                TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption)
                    .tint(style.palette.text.color)
                SkipTrackButton(direction: .next, font: .caption)
            }
            .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [style.palette.backgroundTop.color,
                         style.palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// A clean text-only style for users who want lyrics without album artwork.
struct MinimalLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MinimalLyricsWidget", provider: CurrentLineProvider()) { entry in
            MinimalLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Minimal Lyrics")
        .description("Shows lyrics in a simple text-only layout.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MinimalLyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        VStack(alignment: style.prefs.textAlignment.horizontal, spacing: 6) {
            HStack(spacing: 5) {
                Text("OPENLYRICS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.palette.accent.color)
                Spacer(minLength: 0)
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(style.palette.text.color.opacity(0.65))
            }

            Spacer(minLength: 0)
            Text(entry.currentLine)
                .font(family == .systemSmall ? .headline : .title3)
                .fontWeight(.semibold)
                .foregroundStyle(style.palette.text.color)
                .lineLimit(family == .systemLarge ? 6 : 4)
                .allowsTightening(true)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
                .multilineTextAlignment(style.textAlignment)
            Spacer(minLength: 0)

            VStack(alignment: style.prefs.textAlignment.horizontal, spacing: 2) {
                Text(entry.trackTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.palette.text.color.opacity(0.75))
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.caption2)
                    .foregroundStyle(style.palette.text.color.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            style.palette.backgroundBottom.color
        }
    }
}

/// An artwork-first style for users who want the album to be the main visual.
struct AlbumCardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AlbumCardWidget", provider: CurrentLineProvider()) { entry in
            AlbumCardWidgetView(entry: entry)
        }
        .configurationDisplayName("Album Card")
        .description("Shows album artwork with the current track and lyric.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AlbumCardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        ZStack(alignment: .bottomLeading) {
            style.palette.backgroundTop.color
            LAAlbumDisc(
                urlString: entry.albumImageURL,
                size: family == .systemSmall ? 122 : 182,
                imageData: entry.albumImageData,
                style: .square
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                Text(entry.trackTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text(entry.currentLine)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .allowsTightening(true)
                if style.showsControls {
                    HStack(spacing: 0) {
                        SkipTrackButton(direction: .previous, font: .caption2)
                        TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                            .tint(.white)
                        SkipTrackButton(direction: .next, font: .caption2)
                    }
                }
            }
            .padding(11)
        }
        .clipShape(.rect(cornerRadius: 16))
        .containerBackground(for: .widget) {
            style.palette.backgroundBottom.color
        }
    }
}

/// A high-contrast style for users who want the active line to stand out.
struct KaraokeFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KaraokeFocusWidget", provider: CurrentLineProvider()) { entry in
            KaraokeFocusWidgetView(entry: entry)
        }
        .configurationDisplayName("Karaoke Focus")
        .description("Highlights the current lyric and shows the next line.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct KaraokeFocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        let style = WidgetStyle()
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                    .foregroundStyle(style.palette.accent.color)
                Text("NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(style.palette.text.color.opacity(0.7))
                Spacer(minLength: 0)
                Text(entry.trackTitle)
                    .font(.caption2)
                    .foregroundStyle(style.palette.text.color.opacity(0.55))
                    .lineLimit(1)
            }

            Text(entry.currentLine)
                .font(family == .systemLarge ? .title2 : .title3)
                .fontWeight(.heavy)
                .foregroundStyle(style.palette.text.color)
                .lineLimit(family == .systemLarge ? 5 : 3)
                .allowsTightening(true)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
                .multilineTextAlignment(style.textAlignment)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(style.palette.accent.color.opacity(0.18), in: .rect(cornerRadius: 12))

            if let nextLine = entry.nextLine {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(style.palette.accent.color)
                    Text(nextLine)
                        .font(.footnote)
                        .foregroundStyle(style.palette.text.color.opacity(0.6))
                        .lineLimit(2)
                        .allowsTightening(true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                SkipTrackButton(direction: .previous, font: .caption)
                TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption)
                    .tint(style.palette.text.color)
                SkipTrackButton(direction: .next, font: .caption)
            }
            .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [style.palette.backgroundTop.color,
                         style.palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview(as: .systemMedium) {
    CurrentLineWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .systemMedium) {
    AlbumPlayerWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .systemMedium) {
    LyricFocusWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .systemMedium) {
    MinimalLyricsWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .systemMedium) {
    AlbumCardWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .systemMedium) {
    KaraokeFocusWidget()
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
