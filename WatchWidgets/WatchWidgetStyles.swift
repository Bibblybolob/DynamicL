import WidgetKit
import SwiftUI
import UIKit

/// A lyric-first watch complication for users who want the current line to
/// stand out at a glance.
struct WatchKaraokeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchKaraokeWidget", provider: WatchLyricProvider()) { entry in
            WatchKaraokeWidgetView(entry: entry)
        }
        .configurationDisplayName("Karaoke Lyrics")
        .description("Highlights the current lyric and previews the next line.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WatchKaraokeWidgetView: View {
    let entry: WatchLyricEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                Text(entry.trackTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(entry.currentLine)
                .font(.headline.weight(.bold))
                .lineLimit(2)
                .allowsTightening(true)
                .minimumScaleFactor(0.7)

            if let nextLine = entry.nextLine {
                Text(nextLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [.pink.opacity(0.35), .purple.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// An album-focused watch complication that keeps the track and artwork
/// visible while leaving the current lyric available on rectangular faces.
struct WatchAlbumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAlbumWidget", provider: WatchLyricProvider()) { entry in
            WatchAlbumWidgetView(entry: entry)
        }
        .configurationDisplayName("Album Player")
        .description("Shows album artwork and the current track on your watch.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct WatchAlbumWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchLyricEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        default:
            rectangular
        }
    }

    private var circular: some View {
        ZStack {
            WatchAlbumArtwork(data: entry.albumImageData)
                .clipShape(Circle())
            Circle()
                .fill(.black.opacity(0.3))
            Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
        .widgetLabel {
            Text(entry.trackTitle)
        }
    }

    private var rectangular: some View {
        HStack(spacing: 7) {
            WatchAlbumArtwork(data: entry.albumImageData)
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                    Text(entry.trackTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(entry.artistName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color.black.opacity(0.15)
        }
    }
}

private struct WatchAlbumArtwork: View {
    let data: Data?

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [.pink.opacity(0.8), .purple.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

#Preview(as: .accessoryRectangular) {
    WatchKaraokeWidget()
} timeline: {
    WatchLyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        currentLine: "Sing along to this line",
        isPlaying: true,
        nextLine: "The next line is ready"
    )
}

#Preview(as: .accessoryRectangular) {
    WatchAlbumWidget()
} timeline: {
    WatchLyricEntry(
        date: .now,
        trackTitle: "Sample Track",
        currentLine: "The current lyric",
        isPlaying: true,
        artistName: "OpenLyrics"
    )
}
