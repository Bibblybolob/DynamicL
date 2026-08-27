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
        let style = WidgetStyle()
        switch family {
        case .accessoryCircular: circular(style: style)
        case .accessoryInline: inline(style: style)
        default: rectangular(style: style)
        }
    }

    private func rectangular(style: WidgetStyle) -> some View {
        VStack(alignment: style.prefs.textAlignment.horizontal, spacing: 3) {
            HStack(spacing: 4) {
                if style.showsTrackInfo {
                    Text(entry.trackTitle.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(style.palette.text.color.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if style.showsControls {
                    TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                        .tint(style.palette.text.color)
                }
            }
            Text("“\(entry.currentLine)”")
                .font(.system(.footnote, design: .serif, weight: .medium))
                .italic()
                .foregroundStyle(style.palette.text.color)
                .lineLimit(3)
                .allowsTightening(true)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(style.textAlignment)
                .frame(maxWidth: .infinity, alignment: style.prefs.textAlignment.alignment)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func circular(style: WidgetStyle) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(entry.isPlaying ? style.palette.accent.color : style.palette.text.color.opacity(0.55))
                Text(entry.isPlaying ? "PLAYING" : "PAUSED")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(style.palette.text.color.opacity(0.7))
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func inline(style: WidgetStyle) -> some View {
        Text(entry.isPlaying ? "♪ \(entry.currentLine)" : "❙❙ \(entry.currentLine)")
            .font(.system(.headline, design: .serif))
            .italic()
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
