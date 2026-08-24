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
        .configurationDisplayName("Vinyl")
        .description("A spinning record with the current album art.")
        .supportedFamilies([.accessoryCircular])
        .disfavoredLocations([.homeScreen], for: [.accessoryCircular])
    }
}

struct VinylEntry: TimelineEntry {
    let date: Date
    let rotation: Double
    let imageData: Data?
    let isPlaying: Bool

    static let idle = VinylEntry(date: .now, rotation: 0, imageData: nil, isPlaying: false)
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
        guard let snapshot = SharedNowPlaying.load(),
              let base = await entry(from: snapshot, rotation: 0) else {
            return Timeline(entries: [.idle], policy: .after(.now.addingTimeInterval(600)))
        }

        // Paused / stopped: single static entry.
        guard base.isPlaying else {
            return Timeline(entries: [base], policy: .after(.now.addingTimeInterval(300)))
        }

        // Playing: 8° every 0.15s (one revolution ≈ 6.75s) — fine enough that
        // WidgetKit's entry-stepping reads as constant rotation. ~400 entries
        // ≈ 60s of motion per reload.
        var entries: [VinylEntry] = []
        entries.reserveCapacity(400)
        let start = Date.now
        for step in 0..<400 {
            if let e = await entry(from: snapshot, rotation: Double(step) * 8,
                                   date: start.addingTimeInterval(Double(step) * 0.15)) {
                entries.append(e)
            }
        }
        let refreshAt = (entries.last?.date ?? .now).addingTimeInterval(1)
        return Timeline(entries: entries.isEmpty ? [base] : entries, policy: .after(refreshAt))
    }

    private func currentEntry() async -> VinylEntry? {
        guard let snapshot = SharedNowPlaying.load() else { return nil }
        return await entry(from: snapshot, rotation: 0)
    }

    private func entry(from snapshot: WidgetLyricSnapshot, rotation: Double, date: Date = .now) async -> VinylEntry? {
        let data = await Self.artData(for: snapshot.albumImageURL)
        return VinylEntry(
            date: date,
            rotation: rotation,
            imageData: data,
            isPlaying: effectiveIsPlaying(snapshot)
        )
    }

    /// Album art bytes, cached in the app-group defaults per URL so each spin
    /// timeline fetches at most once per album.
    private static func artData(for urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let defaults = UserDefaults(suiteName: SharedNowPlaying.appGroupID)
        let key = "artCache|\(urlString)"
        if let cached = defaults?.data(forKey: key) { return cached }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let image = UIImage(data: data) else { return nil }

        let maxDim: CGFloat = 128
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let payload = small.jpegData(compressionQuality: 0.85)
        if let payload { defaults?.set(payload, forKey: key) }
        return payload
    }
}

struct VinylWidgetView: View {
    let entry: VinylEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            if let data = entry.imageData, let image = UIImage(data: data) {
                disc(image: image)
            } else {
                ZStack {
                    groovedRecord
                    Image(systemName: entry.isPlaying ? "music.quarternote.3" : "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private func disc(image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            .overlay(
                // Vinyl grooves: dark rim + subtle concentric rings, keeping
                // the album art fully visible in the label area.
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.black.opacity(0.85), .black.opacity(0.45),
                                     .black.opacity(0.8), .black.opacity(0.4),
                                     .black.opacity(0.85)],
                            center: .center
                        ),
                        lineWidth: 9
                    )
            )
            .overlay(Circle().fill(Color.black).frame(width: 7, height: 7))
            .overlay(Circle().fill(Color.white.opacity(0.25)).frame(width: 2, height: 2))
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5).frame(width: 30, height: 30))
            .rotationEffect(.degrees(entry.isPlaying ? entry.rotation : 0))
    }

    /// Fallback record look before any art has loaded.
    private var groovedRecord: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(white: 0.08), Color(white: 0.22)],
                    center: .center,
                    startRadius: 4,
                    endRadius: 26
                )
            )
    }
}

#Preview(as: .accessoryCircular) {
    VinylWidget()
} timeline: {
    VinylEntry(date: .now, rotation: 0, imageData: nil, isPlaying: true)
}
