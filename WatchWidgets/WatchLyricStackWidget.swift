import WidgetKit
import SwiftUI
import LyricCore

// MARK: - Apple Watch Smart Stack widget (watchOS 10+ accessory families)

struct WatchStackLyricView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchLyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                Text(entry.trackTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.currentLine)
                .font(.footnote.weight(.medium))
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [.pink.opacity(0.25), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct WatchLyricStackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchLyricStackWidget", provider: WatchLyricProvider()) { entry in
            WatchStackLyricView(entry: entry)
        }
        .configurationDisplayName("Lyrics Stack Card")
        .description("A lyrics card for your watch's Smart Stack.")
        .supportedFamilies([.accessoryRectangular])
    }
}

#Preview(as: .accessoryRectangular) {
    WatchLyricStackWidget()
} timeline: {
    WatchLyricEntry(date: .now, trackTitle: "Sample Track", currentLine: "La la la…", isPlaying: true)
}
