#if canImport(SwiftUI)
import SwiftUI

// Shared Live Activity chrome components. Motion here is deliberately
// minimal: Live Activities render discrete snapshots, so anything stepped by
// TimelineView reads as choppy. Only slow, intentional cycles live here —
// genuinely smooth motion (waveform symbols, timer-interval progress) is
// handled natively by the system at the call sites.
// Public because both the widget extension and the app's style preview use them.

/// Small breathing dot marking "live" playback. Slow 4-step cycle (~2s) so it
/// reads as a calm heartbeat instead of a flicker.
public struct LAPulseDot: View {
    public var color: Color
    public var animate: Bool

    private let opacities: [Double] = [0.35, 0.7, 1.0, 0.7]

    public init(color: Color, animate: Bool) {
        self.color = color
        self.animate = animate
    }

    public var body: some View {
        Group {
            if animate {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5)
                    dot(opacity: opacities[phase % opacities.count])
                }
            } else {
                dot(opacity: 0.8)
            }
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle().fill(color).opacity(opacity).frame(width: 5, height: 5)
    }
}

/// Hero lyric text with an auto-fit ladder:
///   1. fits at base size → static,
///   2. fits scaled down (to `minScale`) → static smaller,
///   3. still overflowing → gentle ticker scroll (rare fallback).
public struct LAMarquee: View {
    let text: String
    let font: Font
    let color: Color
    let animations: Bool
    /// Real point size of `font` — drives the overflow estimate.
    var pointSize: CGFloat
    var minScale: CGFloat = 0.55
    var lineHeight: CGFloat = 32

    public init(text: String, font: Font, color: Color, animations: Bool,
                pointSize: CGFloat = 25, minScale: CGFloat = 0.55,
                lineHeight: CGFloat = 32) {
        self.text = text
        self.font = font
        self.color = color
        self.animations = animations
        self.pointSize = pointSize
        self.minScale = minScale
        self.lineHeight = lineHeight
    }

    /// Wide display caps run ~0.66em/char; grotesques ~0.52em. Estimating
    /// generously errs toward auto-shrink rather than clipped letters.
    private var charWidth: CGFloat { pointSize * 0.62 }

    public var body: some View {
        GeometryReader { geo in
            let estimated = CGFloat(text.count) * charWidth
            if estimated <= geo.size.width || !animations {
                // Always allow shrinking — the width estimate is heuristic,
                // and SwiftUI only shrinks when actually needed.
                fittedText()
                    .minimumScaleFactor(minScale)
            } else if estimated * minScale <= geo.size.width {
                // Auto-shrink to fit; no motion needed.
                fittedText().minimumScaleFactor(minScale)
            } else {
                ticker(travel: estimated - geo.size.width + 16)
            }
        }
        .frame(height: lineHeight)
    }

    private func fittedText() -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// Slow eased slide with dwell at both ends (~2s per pass).
    private func ticker(travel: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.6)
            let cycleSteps = max(Int(travel / 24), 4) + 6 // includes end dwells
            let pos = Double(step % cycleSteps) / Double(cycleSteps)
            let progress = min(pos / 0.75, 1)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .offset(x: -travel * progress)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }
}

/// Thick rounded progress capsule that advances itself via a local
/// TimelineView (once/sec on the widget's own clock — zero update budget).
/// While paused, renders the frozen fraction statically instead.
public struct LAThickBar: View {
    let start: Date?
    let end: Date?
    let frozen: Double?
    let accent: Color
    let track: Color

    public init(start: Date?, end: Date?, frozen: Double?,
                accent: Color, track: Color) {
        self.start = start
        self.end = end
        self.frozen = frozen
        self.accent = accent
        self.track = track
    }

    public var body: some View {
        Group {
            if let start, let end {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    bar(fraction: Self.fraction(at: timeline.date, start: start, end: end))
                }
            } else if let frozen {
                bar(fraction: frozen)
            }
        }
        .frame(height: 8)
    }

    public static func fraction(at date: Date, start: Date, end: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / span, 0), 1)
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(accent)
                    .frame(width: max(8, geo.size.width * fraction))
            }
        }
    }
}
#endif
