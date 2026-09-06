import WidgetKit
import SwiftUI
import LyricCore

struct ConfiguredLyricEntry: TimelineEntry {
    let lyric: LyricEntry
    let appearance: WidgetStylePrefs
    var date: Date { lyric.date }
    var presentation: WidgetPresentation {
        var value = lyric.presentation ?? .init(current: lyric.currentLine, next: lyric.nextLine,
                                    title: lyric.trackTitle, artist: lyric.artistName)
        value.artworkData = lyric.albumImageData
        value.isPlaying = lyric.isPlaying
        if !lyric.isPlaying, let elapsed = value.elapsedSeconds, let duration = value.durationSeconds {
            value.frozenProgress = min(1, max(0, elapsed / duration)); value.progressInterval = nil
        }
        return value
    }
}

struct ConfiguredLyricProvider: AppIntentTimelineProvider {
    typealias Intent = LyricWidgetConfiguration
    func placeholder(in context: Context) -> ConfiguredLyricEntry {
        .init(lyric: .sample, appearance: .init())
    }
    func snapshot(for configuration: Intent, in context: Context) async -> ConfiguredLyricEntry {
        await withCheckedContinuation { continuation in
            CurrentLineProvider().getSnapshot(in: context) { entry in
                continuation.resume(returning: .init(lyric: entry, appearance: configuration.resolvedStyle))
            }
        }
    }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<ConfiguredLyricEntry> {
        let appearance = configuration.resolvedStyle
        let timeline = CurrentLineProvider().makeTimeline()
        return Timeline(entries: timeline.entries.map {
            ConfiguredLyricEntry(lyric: $0, appearance: appearance)
        }, policy: timeline.policy)
    }
}

struct ConfigurableLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OpenLyricsCustomHome", intent: LyricWidgetConfiguration.self,
                               provider: ConfiguredLyricProvider()) { entry in
            ConfiguredLyricView(entry: entry)
        }
        .configurationDisplayName("OpenLyrics Widgets")
        .description("Your lyrics, your style. Choose a Widget Studio design, then customize this widget independently.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ConfigurableLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "OpenLyricsCustomLock", intent: LyricWidgetConfiguration.self,
                               provider: ConfiguredLyricProvider()) { entry in
            ConfiguredLyricView(entry: entry)
        }
        .configurationDisplayName("OpenLyrics Lock Screen")
        .description("A compact lyric with independent typography and a saved design.")
        .supportedFamilies([.accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct ConfiguredLyricView: View {
    let entry: ConfiguredLyricEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    private var size: WidgetTemplateView.Size {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        case .accessoryRectangular: .rectangular
        default: .medium
        }
    }
    private var accessory: Bool {
        [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family)
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(entry.presentation.current)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 3) {
                        Image(systemName: entry.lyric.isPlaying ? "music.note" : "pause.fill")
                            .widgetAccentable()
                        Text(entry.lyric.isPlaying ? "PLAYING" : "PAUSED")
                            .font(.system(size: 7, weight: .semibold))
                    }
                }
            default:
                WidgetTemplateView(content: entry.presentation, style: entry.appearance, size: size,
                                monochrome: accessory || !showsBackground || renderingMode != .fullColor)
            }
        }
        .containerBackground(for: .widget) {
            if !accessory {
                WidgetStudioBackground(style: entry.appearance, content: entry.presentation)
            }
        }
        .widgetURL(URL(string: "dynamicallyrics://widgets"))
    }
}
