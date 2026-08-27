import WidgetKit
import SwiftUI
import UIKit
import LyricCore

/// Lock-screen circular widget: vinyl record with the album cover as its label.
/// Spins while music plays via timeline-driven rotation (WidgetKit cannot run
/// infinite SwiftUI animations — motion must come from successive entries).
struct VinylWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VinylWidget", provider: VinylProvider()) { entry in
            VinylWidgetView(entry: entry)
        }
        .configurationDisplayName("Vinyl Player")
        .description("A spinning record with the current album art and track.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
        .disfavoredLocations([.homeScreen], for: [.accessoryCircular])
    }
}

struct VinylEntry: TimelineEntry {
    let date: Date
    let rotation: Double
    let imageData: Data?
    let trackTitle: String
    let artistName: String
    let isPlaying: Bool

    static let idle = VinylEntry(
        date: .now,
        rotation: 0,
        imageData: nil,
        trackTitle: "No music",
        artistName: "OpenLyrics",
        isPlaying: false
    )
}

/// WidgetKit completions aren't Sendable; box them so the async provider can
/// hand results back from inside a Task (called exactly once).
private final class CompletionBox<T> : @unchecked Sendable {
    let apply: (T) -> Void
    init(_ apply: @escaping (T) -> Void) { self.apply = apply }
}

struct VinylProvider: TimelineProvider {
    func placeholder(in context: Context) -> VinylEntry { .idle }

    func getSnapshot(in context: Context, completion: @escaping (VinylEntry) -> Void) {
        let box = CompletionBox(completion)
        Task { box.apply(await currentEntry() ?? .idle) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VinylEntry>) -> Void) {
        let box = CompletionBox(completion)
        Task { box.apply(await buildTimeline()) }
    }

    private func buildTimeline() async -> Timeline<VinylEntry> {
        let style = WidgetStyle()
        guard let snapshot = SharedNowPlaying.load(),
              let base = await entry(
                  from: snapshot,
                  rotation: 0,
                  showArtwork: style.prefs.artworkStyle != .hidden
              ) else {
            return Timeline(entries: [.idle], policy: .after(.now.addingTimeInterval(600)))
        }

        // Paused / stopped: single static entry.
        guard base.isPlaying, style.prefs.animationsEnabled else {
            return Timeline(entries: [base], policy: .after(.now.addingTimeInterval(300)))
        }

        // WidgetKit cannot run an unbounded animation. A one-second timeline
        // is a lighter, more reliable compromise for the small widget while
        // still giving the record a visible 15-second revolution.
        var entries: [VinylEntry] = []
        entries.reserveCapacity(60)
        let start = Date.now
        for step in 0..<60 {
            if let e = await entry(from: snapshot, rotation: Double(step) * 24,
                                   date: start.addingTimeInterval(Double(step)),
                                   showArtwork: style.prefs.artworkStyle != .hidden) {
                entries.append(e)
            }
        }
        let refreshAt = (entries.last?.date ?? .now).addingTimeInterval(1)
        return Timeline(entries: entries.isEmpty ? [base] : entries, policy: .after(refreshAt))
    }

    private func currentEntry() async -> VinylEntry? {
        guard let snapshot = SharedNowPlaying.load() else { return nil }
        let style = WidgetStyle()
        return await entry(
            from: snapshot,
            rotation: 0,
            showArtwork: style.prefs.artworkStyle != .hidden
        )
    }

    private func entry(from snapshot: WidgetLyricSnapshot, rotation: Double,
                       date: Date = .now, showArtwork: Bool = true) async -> VinylEntry? {
        let data = await Self.artData(for: showArtwork ? snapshot.albumImageURL : nil)
        return VinylEntry(
            date: date,
            rotation: rotation,
            imageData: data,
            trackTitle: snapshot.trackTitle,
            artistName: snapshot.artistName,
            isPlaying: effectiveIsPlaying(snapshot)
        )
    }

    /// Album art bytes, cached in the app-group defaults per URL so each spin
    /// timeline fetches at most once per album.
    private static func artData(for urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let cached = SharedNowPlaying.cachedArtwork(for: urlString) { return cached }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let image = UIImage(data: data) else { return nil }

        let maxDim: CGFloat = 128
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let payload = small.jpegData(compressionQuality: 0.85)
        if let payload { SharedNowPlaying.saveArtwork(payload, for: urlString) }
        return payload
    }
}

struct VinylWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VinylEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                homeScreen
            } else {
                accessoryCircular
            }
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            record(size: 46)
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var homeScreen: some View {
        let style = WidgetStyle()
        return ZStack(alignment: .bottomLeading) {
            record(size: 130)
                .padding(.top, 2)
            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption2.bold())
                    Text(entry.trackTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if style.showsControls {
                        TogglePlaybackButton(isPlaying: entry.isPlaying, font: .caption2)
                            .tint(.white)
                    }
                }
                Text(entry.artistName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .clipShape(.rect(cornerRadius: 18))
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [style.palette.backgroundTop.color, style.palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func record(size: CGFloat) -> some View {
        if let data = entry.imageData, let image = UIImage(data: data) {
            disc(image: image, size: size)
        } else {
            ZStack {
                groovedRecord(size: size)
                Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                    .font(size < 60 ? .caption2 : .title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func disc(image: UIImage, size: CGFloat) -> some View {
        let artwork = Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
        return artwork
            .overlay(grooveOverlay(size: size))
            .overlay(spindleOverlay(size: size))
            .rotationEffect(.degrees(entry.isPlaying ? entry.rotation : 0))
    }

    private func grooveOverlay(size: CGFloat) -> some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [.black.opacity(0.85), .black.opacity(0.45),
                             .black.opacity(0.8), .black.opacity(0.4),
                             .black.opacity(0.85)],
                    center: .center
                ),
                lineWidth: max(5, size * 0.18)
            )
    }

    private func spindleOverlay(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: max(7, size * 0.14), height: max(7, size * 0.14))
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: max(2, size * 0.04), height: max(2, size * 0.04))
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
                .frame(width: size * 0.65, height: size * 0.65)
        }
    }

    /// Fallback record look before any art has loaded.
    private func groovedRecord(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(white: 0.08), Color(white: 0.22)],
                    center: .center,
                    startRadius: 4,
                    endRadius: size / 2
                )
            )
    }
}

#Preview(as: .accessoryCircular) {
    VinylWidget()
} timeline: {
    VinylEntry(date: .now, rotation: 0, imageData: nil, trackTitle: "Sample Track", artistName: "OpenLyrics", isPlaying: true)
}
