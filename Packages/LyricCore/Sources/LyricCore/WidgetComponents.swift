#if canImport(SwiftUI)
import SwiftUI

/// Shared by the app's editor and WidgetKit. No timers, storage writes or network work.
public struct WidgetLyricCard: View {
    public enum Size: Sendable { case small, medium, large, rectangular }
    private let content: WidgetPresentation
    private let appearance: WidgetAppearance
    private let size: Size
    private let monochrome: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(content: WidgetPresentation, appearance: WidgetAppearance,
                size: Size, monochrome: Bool = false) {
        self.content = content
        self.appearance = appearance.normalized
        self.size = size
        self.monochrome = monochrome
    }

    private var alignment: HorizontalAlignment {
        switch appearance.alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private var textAlignment: TextAlignment {
        switch appearance.alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private var weight: Font.Weight {
        switch appearance.weight { case .regular: .regular; case .medium: .medium; case .bold: .bold; case .heavy: .heavy }
    }
    private var foreground: Color {
        if monochrome || appearance.background == .system { return .primary }
        if appearance.background == .solid {
            let c = appearance.backgroundColor
            return c.r * 0.299 + c.g * 0.587 + c.b * 0.114 > 0.58 ? .black : .white
        }
        return .white
    }
    private var compact: Bool { size == .small || size == .rectangular }
    private var baseSize: Double { size == .large ? 29 : (size == .rectangular ? 15 : (size == .small ? 20 : 23)) }
    private var opacity: Double { contrast == .increased ? max(0.65, appearance.contextOpacity) : appearance.contextOpacity }

    public var body: some View {
        VStack(alignment: alignment, spacing: size == .large ? 14 : 6) {
            if appearance.showTitle || appearance.showArtist {
                VStack(alignment: alignment, spacing: 2) {
                    if appearance.showTitle {
                        Text(content.title).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    if appearance.showArtist && size != .rectangular {
                        Text(content.artist).font(.caption2).lineLimit(1).opacity(0.7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .opacity(0.8)
            }
            if size != .rectangular { Spacer(minLength: 0) }
            if appearance.context == .surrounding && !compact, let previous = content.previous {
                contextLine(previous)
            }
            Text(content.current)
                .font(appearance.font.laFont(fixedSize: baseSize * appearance.size, weight: weight))
                .lineLimit(size == .large ? 5 : (size == .rectangular ? 2 : 3))
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: false)
                .padding(appearance.preset == .lyricStack && !compact ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .background {
                    if appearance.preset == .lyricStack && !compact {
                        RoundedRectangle(cornerRadius: appearance.roundedHighlight ? 14 : 3)
                            .fill((monochrome ? Color.primary : appearance.accent.color)
                                .opacity(reduceTransparency ? 0.12 : 0.18))
                    }
                }
                .accessibilityLabel("Current lyric: \(content.current)")
            if appearance.context != .current, size != .rectangular, let next = content.next {
                contextLine(next)
            }
            if size != .rectangular { Spacer(minLength: 0) }
        }
        .multilineTextAlignment(textAlignment)
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var frameAlignment: SwiftUI.Alignment {
        switch appearance.alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private func contextLine(_ text: String) -> some View {
        Text(text)
            .font(appearance.font.laFont(fixedSize: size == .large ? 17 : 12, weight: .medium))
            .lineLimit(compact ? 1 : 2)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .opacity(opacity)
    }
}

public struct WidgetCardBackground: View {
    let appearance: WidgetAppearance
    let albumColor: RGB?
    public init(appearance: WidgetAppearance, albumColor: RGB? = nil) {
        self.appearance = appearance.normalized
        self.albumColor = albumColor
    }
    public var body: some View {
        switch appearance.background {
        case .system: Color.clear
        case .solid: appearance.backgroundColor.color
        case .gradient, .album:
            let color = appearance.background == .album ? (albumColor ?? appearance.accent).color : appearance.accent.color
            LinearGradient(colors: [color.opacity(0.45), Color.black.opacity(0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Color.black)
        }
    }
}
#endif
