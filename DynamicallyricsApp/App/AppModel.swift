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

struct VinylProvider: TimelineProvider {
    func placeholder(in context: Context) -> VinylEntry { .idle }

    func getSnapshot(in context: Context, completion: @escaping (VinylEntry) -> Void) {
        Task { completion(await currentEntry() ?? .idle) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VinylEntry>) -> Void) {
        Task {
            guard let snapshot = SharedNowPlaying.load(),
                  let base = await entry(from: snapshot, rotation: 0) else {
                completion(Timeline(entries: [.idle], policy: .after(.now.addingTimeInterval(600))))
                return
            }

            // Paused / stopped: single static entry.
            guard base.isPlaying else {
                completion(Timeline(entries: [base], policy: .after(.now.addingTimeInterval(300))))
                return
            }

            // Playing: 20° every 0.3s (one revolution ≈ 5.4s), ~200 entries ≈
            // 60s of motion per reload.
            var entries: [VinylEntry] = []
            entries.reserveCapacity(200)
            for step in 0..<200 {
                if let e = await entry(from: snapshot, rotation: Double(step) * 20,
                                       date: Date.now.addingTimeInterval(Double(step) * 0.3)) {
                    entries.append(e)
                }
            }
            let refreshAt = (entries.last?.date ?? .now).addingTimeInterval(1)
            completion(Timeline(entries: entries.isEmpty ? [base] : entries, policy: .after(refreshAt)))
        }
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
                    if !entry.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        Image(systemName: "music.quarternote.3")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private func disc(image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 4))
            .overlay(
                Circle().fill(Color.black.opacity(0.9)).frame(width: 6, height: 6)
            )
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
