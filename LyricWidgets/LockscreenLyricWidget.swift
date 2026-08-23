import WidgetKit
import SwiftUI

/// A separate, minimal lyric widget that only appears on the Lock Screen.
/// Styling is deliberately different from "Current Line": no pink accents,
/// a serif italic "lyric card" look, and monochrome-friendly glyphs so it
/// follows whatever tint the user picked for their Lock Screen.
struct LockscreenLyricWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LockscreenLyricWidget", provider: CurrentLineProvider()) { entry in
            LockscreenLyricView(entry: entry)
        }
        .configurationDisplayName("Lock Screen Lyrics")
        .description("A quiet lyric card that lives only on your Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
        .disfavoredLocations([.homeScreen, .standBy], for: [.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct LockscreenLyricView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(entry.trackTitle.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
            }
            Text("“\(entry.currentLine)”")
                .font(.system(.footnote, design: .serif, weight: .medium))
                .italic()
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text(entry.isPlaying ? "PLAYING" : "PAUSED")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var inline: some View {
        Text(entry.isPlaying ? "♪ \(entry.currentLine)" : "❙❙ \(entry.currentLine)")
            .font(.system(.headline, design: .serif))
            .italic()
            .lineLimit(1)
            .containerBackground(for: .widget) {
                Color.clear
            }
    }
}

#Preview(as: .accessoryRectangular) {
    LockscreenLyricWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .accessoryCircular) {
    LockscreenLyricWidget()
} timeline: {
    LyricEntry.sample
}

#Preview(as: .accessoryInline) {
    LockscreenLyricWidget()
} timeline: {
    LyricEntry.sample
}
