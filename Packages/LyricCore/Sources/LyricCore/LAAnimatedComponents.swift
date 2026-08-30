#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
///   1. fit inside a bounded width, using up to `maxLines`,
///   2. scale down while preserving the selected layout,
///   3. for a deliberately single-line layout, ticker only when necessary.
///
/// The explicit width and clipping are intentional. Live Activity regions can
/// propose an unbounded ideal width to nested views, which otherwise lets a
/// long lyric escape the lock-screen card or Dynamic Island.
public struct LAMarquee: View {
    let text: String
    let font: Font
    let color: Color
    let animations: Bool
    /// Real point size of `font` — drives the overflow estimate.
    var pointSize: CGFloat
    var minScale: CGFloat = 0.55
    var lineHeight: CGFloat = 32
    var maxLines: Int = 2
    var textAlignment: SwiftUI.TextAlignment = .leading

    public init(text: String, font: Font, color: Color, animations: Bool,
                pointSize: CGFloat = 25, minScale: CGFloat = 0.55,
                lineHeight: CGFloat = 32, maxLines: Int = 2,
                textAlignment: SwiftUI.TextAlignment = .leading) {
        self.text = text
        self.font = font
        self.color = color
        self.animations = animations
        self.pointSize = pointSize
        self.minScale = minScale
        self.lineHeight = lineHeight
        self.maxLines = maxLines
        self.textAlignment = textAlignment
    }

    /// Custom display fonts vary substantially in width. This intentionally
    /// errs wide so we choose the bounded/multiline path before a glyph can be
    /// clipped by a Live Activity region.
    private var estimatedWidth: CGFloat { CGFloat(text.count) * pointSize * 0.76 }

    public var body: some View {
        GeometryReader { geo in
            // Some ActivityKit regions report an unbounded ideal width. A
            // finite cap keeps layout deterministic in previews and on-device.
            let width = min(max(geo.size.width, 1), 600)
            let estimated = estimatedWidth
            let lines = max(1, maxLines)
            let minimum = max(0.25, min(minScale, 1))
            let needsTicker = animations && lines == 1 && estimated * minimum > width
            Group {
                if !needsTicker {
                    // The fixed proposal below is the final guardrail. Even
                    // if the font estimate is wrong, SwiftUI must lay the text
                    // out inside this exact width.
                    fittedText(maxLines: lines)
                        .minimumScaleFactor(minimum)
                        .frame(width: width,
                               alignment: textAlignment == .center ? .center : .leading)
                } else {
                    ticker(travel: max(estimated - width + 16, 16), width: width)
                }
            }
            .frame(width: width, height: lineHeight, alignment: .leading)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: lineHeight)
        .clipped()
    }

    private func fittedText(maxLines: Int) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(maxLines)
            .lineSpacing(-1)
            .allowsTightening(true)
            .multilineTextAlignment(textAlignment)
    }

    /// Slow eased slide with dwell at both ends (~2s per pass).
    private func ticker(travel: CGFloat, width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.6)
            let cycleSteps = max(Int(travel / 24), 4) + 6 // includes end dwells
            let pos = Double(step % cycleSteps) / Double(cycleSteps)
            let progress = min(pos / 0.75, 1)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: -travel * progress)
                .frame(width: width,
                       alignment: textAlignment == .center ? .center : .leading)
                .clipped()
        }
        .frame(width: width, height: lineHeight, alignment: .leading)
        .clipped()
    }
}

/// Compact record-style artwork used by the mini-player Live Activity and
/// Home Screen widget. It intentionally works with a remote URL but always
/// has a local record fallback, so missing artwork never breaks layout.
public struct LAAlbumDisc: View {
    let urlString: String?
    let url: URL?
    let imageData: Data?
    let size: CGFloat
    let style: LAStylePrefs.ArtworkStyle

    public init(urlString: String?, size: CGFloat,
                imageData: Data? = nil,
                style: LAStylePrefs.ArtworkStyle = .vinyl) {
        self.urlString = urlString
        self.url = urlString.flatMap(URL.init(string:))
        self.imageData = imageData
        self.size = size
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .vinyl:
                vinyl
            case .square:
                square
            case .hidden:
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }

    private var vinyl: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.94))

            if let cachedArtworkImage {
                cachedArtworkImage
                    .resizable()
                    .scaledToFill()
                    .frame(width: size * 0.55, height: size * 0.55)
                    .clipShape(Circle())
            } else if let url {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size * 0.55, height: size * 0.55)
                            .clipShape(Circle())
                    } else {
                        fallbackLabel
                    }
                }
            } else {
                fallbackLabel
            }

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0.08), .black.opacity(0.7),
                                 .white.opacity(0.16), .black.opacity(0.72)],
                        center: .center
                    ),
                    lineWidth: max(4, size * 0.16)
                )
            Circle()
                .fill(Color.black.opacity(0.9))
                .frame(width: max(4, size * 0.075), height: max(4, size * 0.075))
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }

    private var square: some View {
        Group {
            if let cachedArtworkImage {
                cachedArtworkImage
                    .resizable()
                    .scaledToFill()
            } else if let url {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallbackLabel
                    }
                }
            } else {
                fallbackLabel
            }
        }
        .frame(width: size, height: size)
        .background(Color.black.opacity(0.55))
        .clipShape(.rect(cornerRadius: size * 0.2))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.2)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }

    private var fallbackLabel: some View {
        Image(systemName: "music.note")
            .font(.system(size: size * 0.22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
    }

    #if canImport(UIKit)
    private static let uiImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private var cachedArtworkImage: Image? {
        let data = imageData ?? SharedNowPlaying.cachedArtwork(for: urlString)
        guard let data else { return nil }

        if let urlString,
           let image = Self.uiImageCache.object(forKey: urlString as NSString) {
            return Image(uiImage: image)
        }

        guard let image = UIImage(data: data) else { return nil }
        if let urlString {
            Self.uiImageCache.setObject(
                image,
                forKey: urlString as NSString,
                cost: data.count
            )
        }
        return Image(uiImage: image)
    }
    #else
    private var cachedArtworkImage: Image? { nil }
    #endif
}

/// Renders a lyric line from a wall-clock schedule shared by the app and the
/// Live Activity. Lyric changes use their exact boundary dates. Karaoke uses
/// a nested local clock, so iOS can reduce animation cadence without changing
/// the schedule that selects the current line.
public struct LAScheduledLyricText: View {
    public enum Role {
        case current
        case next
    }

    let currentLine: String
    let nextLine: String?
    let scheduledLines: [WidgetLyricSnapshot.ScheduledLine]
    let role: Role
    let font: Font
    let color: Color
    let animations: Bool
    let pointSize: CGFloat
    let minScale: CGFloat
    let lineHeight: CGFloat
    let maxLines: Int
    let textAlignment: SwiftUI.TextAlignment
    let karaokeEnabled: Bool
    let karaokeStartDate: Date?
    let karaokeEndDate: Date?
    let frozenKaraokeProgress: Double?
    let highlightColor: Color

    public init(currentLine: String,
                nextLine: String?,
                scheduledLines: [WidgetLyricSnapshot.ScheduledLine],
                role: Role,
                font: Font,
                color: Color,
                animations: Bool,
                pointSize: CGFloat = 25,
                minScale: CGFloat = 0.55,
                lineHeight: CGFloat = 32,
                maxLines: Int = 2,
                textAlignment: SwiftUI.TextAlignment = .leading,
                karaokeEnabled: Bool = false,
                karaokeStartDate: Date? = nil,
                karaokeEndDate: Date? = nil,
                frozenKaraokeProgress: Double? = nil,
                highlightColor: Color? = nil) {
        self.currentLine = currentLine
        self.nextLine = nextLine
        self.scheduledLines = scheduledLines
        self.role = role
        self.font = font
        self.color = color
        self.animations = animations
        self.pointSize = pointSize
        self.minScale = minScale
        self.lineHeight = lineHeight
        self.maxLines = maxLines
        self.textAlignment = textAlignment
        self.karaokeEnabled = karaokeEnabled
        self.karaokeStartDate = karaokeStartDate
        self.karaokeEndDate = karaokeEndDate
        self.frozenKaraokeProgress = frozenKaraokeProgress
        self.highlightColor = highlightColor ?? color
    }

    public var body: some View {
        // Use the same absolute lyric boundaries as the widget timeline. A
        // periodic schedule can be throttled by the system while the device
        // is locked, which leaves the Live Activity on an old lyric even
        // though the widget has already advanced.
        TimelineView(.explicit(refreshDates)) { timeline in
            let pair = resolvedLines(at: timeline.date)
            if role == .current && karaokeEnabled && animations {
                TimelineView(.periodic(from: .now, by: 0.2)) { sweep in
                    content(pair: pair, at: sweep.date)
                }
            } else {
                content(pair: pair, at: timeline.date)
            }
        }
        .frame(height: lineHeight)
        .clipped()
    }

    private var refreshDates: [Date] {
        let now = Date.now
        let boundaries = scheduledLines.flatMap { line in
            [line.date, line.endDate].compactMap { $0 }
        }
        // ActivityKit can coalesce duplicate timeline dates. Give it an
        // ordered set of explicit line boundaries, including the final end,
        // so lyric selection does not depend on a throttled periodic timer.
        return Array(Set([now] + boundaries.filter { $0 > now })).sorted()
    }

    @ViewBuilder
    private func content(pair: ResolvedLines, at date: Date) -> some View {
        let text = role == .current ? pair.current : pair.next
        Group {
            if role == .current {
                if karaokeEnabled {
                    LAKaraokeSweepText(
                        text: pair.current,
                        progress: karaokeProgress(at: date, pair: pair),
                        font: font,
                        baseColor: color,
                        highlightColor: highlightColor,
                        animations: animations,
                        pointSize: pointSize,
                        minScale: minScale,
                        lineHeight: lineHeight,
                        maxLines: maxLines,
                        textAlignment: textAlignment
                    )
                } else {
                    LAMarquee(
                        text: pair.current,
                        font: font,
                        color: color,
                        animations: animations,
                        pointSize: pointSize,
                        minScale: minScale,
                        lineHeight: lineHeight,
                        maxLines: maxLines,
                        textAlignment: textAlignment
                    )
                }
            } else if let text {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: .infinity,
                           alignment: textAlignment == .center ? .center : .leading)
            }
        }
        .id(text ?? "")
        .animation(animations ? .spring(duration: 0.3) : nil, value: text)
    }

    private func resolvedLines(at date: Date) -> ResolvedLines {
        var current = currentLine
        var next = nextLine
        var passedCount = 0

        for line in scheduledLines {
            guard line.date <= date else { break }
            current = line.text
            passedCount += 1
        }

        var startDate = karaokeStartDate
        var endDate = karaokeEndDate
        if passedCount > 0 {
            next = passedCount < scheduledLines.count
                ? scheduledLines[passedCount].text
                : nil
            let active = scheduledLines[passedCount - 1]
            startDate = active.date
            endDate = active.endDate ?? (passedCount < scheduledLines.count
                ? scheduledLines[passedCount].date
                : nil)
        }
        return ResolvedLines(
            current: current,
            next: next,
            startDate: startDate,
            endDate: endDate
        )
    }

    private func karaokeProgress(at date: Date, pair: ResolvedLines) -> Double {
        if let frozenKaraokeProgress {
            return min(max(frozenKaraokeProgress, 0), 1)
        }
        guard let start = pair.startDate,
              let end = pair.endDate,
              end > start else {
            return 0
        }
        return min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }

    private struct ResolvedLines {
        let current: String
        let next: String?
        let startDate: Date?
        let endDate: Date?
    }
}

/// Fills the active lyric from left to right using the exact line interval
/// supplied by the app. Both layers share the same bounded marquee layout, so
/// long lyrics retain the auto-fit/clipping protections already used by the
/// Live Activity.
private struct LAKaraokeSweepText: View {
    let text: String
    let progress: Double
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    let animations: Bool
    let pointSize: CGFloat
    let minScale: CGFloat
    let lineHeight: CGFloat
    let maxLines: Int
    let textAlignment: SwiftUI.TextAlignment

    init(text: String, progress: Double, font: Font, baseColor: Color,
         highlightColor: Color, animations: Bool, pointSize: CGFloat,
         minScale: CGFloat, lineHeight: CGFloat, maxLines: Int,
         textAlignment: SwiftUI.TextAlignment = .leading) {
        self.text = text
        self.progress = progress
        self.font = font
        self.baseColor = baseColor
        self.highlightColor = highlightColor
        self.animations = animations
        self.pointSize = pointSize
        self.minScale = minScale
        self.lineHeight = lineHeight
        self.maxLines = maxLines
        self.textAlignment = textAlignment
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LAMarquee(
                text: text,
                font: font,
                color: baseColor,
                animations: animations,
                pointSize: pointSize,
                minScale: minScale,
                lineHeight: lineHeight,
                maxLines: maxLines,
                textAlignment: textAlignment
            )
            LAMarquee(
                text: text,
                font: font,
                color: highlightColor,
                animations: animations,
                pointSize: pointSize,
                minScale: minScale,
                lineHeight: lineHeight,
                maxLines: maxLines,
                textAlignment: textAlignment
            )
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(
                            width: proxy.size.width * min(max(progress, 0), 1),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: lineHeight)
        .clipped()
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
