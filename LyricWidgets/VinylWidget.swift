import WidgetKit
import SwiftUI
import LyricCore

/// Lock-screen circular widget: spinning vinyl record with the album cover as
/// its label. Spins while music plays; static (with a pause glyph) when paused.
struct VinylWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VinylWidget", provider: VinylProvider()) { entry in
            VinylWidgetView(entry: entry)
        }
        .configurationDisplayName("Vinyl")
        .description("A spinning record with the current album art.")
        .supportedFamilies([.accessoryCircular])
        .disfavoredLocations([.homeScreen], for: [.accessoryCircular])
    }
}

struct VinylEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artistName: String
    let albumImageURL: String?
    let isPlaying: Bool

    static let idle = VinylEntry(
        date: .now,
        trackTitle: "No music",
        artistName: "",
        albumImageURL: nil,
        isPlaying: false
    )
}

struct VinylProvider: TimelineProvider {
    func placeholder(in context: Context) -> VinylEntry { .idle }

    func getSnapshot(in context: Context, completion: @escaping (VinylEntry) -> Void) {
        completion(currentEntry() ?? .idle)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VinylEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry() ?? .idle], policy: .after(.now.addingTimeInterval(600))))
    }

    private func currentEntry() -> VinylEntry? {
        guard let s = SharedNowPlaying.load() else { return nil }
        return VinylEntry(
            date: .now,
            trackTitle: s.trackTitle,
            artistName: s.artistName,
            albumImageURL: s.albumImageURL,
            isPlaying: effectiveIsPlaying(s)
        )
    }
}

/// Rotates continuously while playing using a repeating linear animation.
/// WidgetKit renders this fine inside accessory widgets on iOS 17+.
struct SpinEffect: ViewModifier {
    let isPlaying: Bool

    func body(content: Content) -> some View {
        if isPlaying {
            content
                .rotationEffect(.zero)
                .modifier(ContinuousRotation())
        } else {
            content
        }
    }
}

struct ContinuousRotation: ViewModifier {
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

struct VinylWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VinylEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            if let urlString = entry.albumImageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        defaultLabel
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color.black.opacity(0.55), lineWidth: 3)
                )
                .modifier(SpinEffect(isPlaying: entry.isPlaying))
            } else {
                defaultLabel
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    /// Record-groove look used while art loads or nothing is playing.
    private var defaultLabel: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.black.opacity(0.85), Color(white: 0.15)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 26
                    )
                )
            Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

#Preview(as: .accessoryCircular) {
    VinylWidget()
} timeline: {
    VinylEntry(date: .now, trackTitle: "Song", artistName: "Artist", albumImageURL: nil, isPlaying: true)
}
