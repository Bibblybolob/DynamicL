#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension WidgetColor {
    var color: Color { rgb.color.opacity(alpha.isFinite ? min(1, max(0, alpha)) : 1) }
}

/// The app preview and WidgetKit use this exact composition, with no refresh machinery.
public struct WidgetTemplateView: View {
    public enum Size: String, CaseIterable, Sendable { case small, medium, large, inline, circular, rectangular }
    let content: WidgetPresentation
    let style: WidgetStylePrefs
    let size: Size
    let monochrome: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    public init(content: WidgetPresentation, style: WidgetStylePrefs, size: Size, monochrome: Bool = false) {
        self.content = content; self.size = size; self.monochrome = monochrome
        self.style = WidgetStyleResolver.resolve(style, album: content.albumColor, compact: size == .small || size == .rectangular)
    }
    private var compact: Bool { size == .small || size == .rectangular }
    private var alignment: HorizontalAlignment { style.typography.alignment == .center ? .center : (style.typography.alignment == .trailing ? .trailing : .leading) }
    private var frameAlignment: Alignment { style.typography.alignment == .center ? .center : (style.typography.alignment == .trailing ? .trailing : .leading) }
    private var weight: Font.Weight {
        switch style.typography.weight { case .regular: .regular; case .medium: .medium; case .bold: .bold; case .heavy: .heavy }
    }
    private func color(_ role: String) -> Color {
        monochrome || style.background.fill == .system ? .primary : style.palette[role].color
    }
    private func font(_ points: Double) -> Font {
        if let family = WidgetFont.all.first(where: { $0.id == style.typography.fontID })?.family {
            return .custom(family, size: points).weight(weight)
        }
        let design: Font.Design = style.typography.fontID == "serif" ? .serif : (style.typography.fontID == "mono" ? .monospaced : (style.typography.fontID == "rounded" ? .rounded : .default))
        return .system(size: points, weight: weight, design: design)
    }
    private var baseSize: Double {
        if size == .large { return 30 }
        if size == .rectangular { return 15 }
        if size == .small { return ["albumCard", "vinyl", "nowPlaying", "retro", "quote", "editorial"].contains(style.templateID) ? 18 : 20 }
        return 22
    }
    private var lyricColor: Color { color(style.typography.emphasis == .accent ? "accent" : "primaryLyric") }
    private var line: String { style.typography.uppercase ? content.current.uppercased(with: .current) : content.current }
    private var lyric: some View {
        Text(line)
            .font(font(baseSize * style.typography.scale))
            .foregroundStyle(lyricGradient)
            .lineSpacing(style.typography.lineSpacing)
            .lineLimit(size == .large ? style.typography.maxLines : min(size == .small ? 3 : 2, style.typography.maxLines))
            .minimumScaleFactor(0.65).allowsTightening(true)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(contrast == .increased ? 1 : style.typography.currentOpacity)
            .shadow(color: style.typography.shadow && !monochrome ? .black.opacity(0.3) : .clear, radius: 1, y: 1)
            .padding(style.typography.emphasis == .highlight && !compact ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background {
                if style.typography.emphasis == .highlight && !compact {
                    RoundedRectangle(cornerRadius: style.cornerRadius).fill(color("accent").opacity(0.16))
                }
            }
            .layoutPriority(1)
            .accessibilityLabel("Current lyric: \(content.current)")
    }
    private var lyricGradient: LinearGradient {
        LinearGradient(colors: [lyricColor, style.typography.emphasis == .gradient && !monochrome ? color("accent") : lyricColor], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private func context(_ text: String?, opacity: Double) -> some View {
        Group {
            if let text {
                Text(text).font(font(size == .large ? 17 : 12)).lineLimit(size == .large ? 2 : 1)
                    .foregroundStyle(color("secondaryLyric"))
                    .opacity(contrast == .increased ? max(0.75, opacity) : opacity)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
    }
    private var metadata: some View {
        VStack(alignment: alignment, spacing: 2) {
            if style.details.title { Text(content.title).font(.caption.weight(.semibold)).foregroundStyle(color("songTitle")).lineLimit(1) }
            if style.details.artist && size != .rectangular { Text(content.artist).font(.caption2).foregroundStyle(color("artist")).lineLimit(1) }
            if style.details.album && !compact, let album = content.album { Text(album).font(.caption2).foregroundStyle(color("artist")).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: frameAlignment)
    }
    private var lines: some View {
        VStack(alignment: alignment, spacing: size == .large ? 12 : 5) {
            if style.details.previous && !compact { context(content.previous, opacity: style.typography.previousOpacity) }
            lyric
            if style.details.next && size != .rectangular { context(content.next, opacity: style.typography.nextOpacity) }
        }
    }
    @ViewBuilder private var footer: some View {
        if style.details.progress || style.details.elapsed || style.details.remaining || style.details.playbackIcon {
            VStack(spacing: 4) {
                if style.details.progress {
                    if let interval = content.progressInterval, content.isPlaying {
                        ProgressView(timerInterval: interval, countsDown: false).labelsHidden().tint(color("progressFill")).background(color("progressTrack").opacity(0.2), in: Capsule())
                    } else if let value = content.frozenProgress {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(color("progressTrack").opacity(0.25))
                                Capsule().fill(color("progressFill")).frame(width: geometry.size.width * min(1, max(0, value)))
                            }
                        }.frame(height: 4)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(value * 100)) percent")
                    }
                }
                HStack {
                    if style.details.playbackIcon { Image(systemName: content.isPlaying ? "play.fill" : "pause.fill") }
                    if style.details.elapsed { timeLabel(remaining: false) }
                    Spacer(minLength: 0)
                    if style.details.remaining { timeLabel(remaining: true) }
                }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color("artist"))
            }
        }
    }
    @ViewBuilder private func timeLabel(remaining: Bool) -> some View {
        if let interval = content.progressInterval, content.isPlaying {
            Text(timerInterval: interval, countsDown: remaining).monospacedDigit()
        } else if let elapsed = content.elapsedSeconds, let duration = content.durationSeconds {
            let seconds = Int(max(0, remaining ? duration - elapsed : elapsed))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
    private func art(_ side: Double) -> some View {
        WidgetArtwork(content: content, style: style, monochrome: monochrome)
            .frame(width: min(size == .small ? 56 : 160, side * (style.artwork.placement == .thumbnail ? 0.6 : 1) * style.artwork.size), height: min(size == .small ? 56 : 160, side * (style.artwork.placement == .thumbnail ? 0.6 : 1) * style.artwork.size))
    }
    public var body: some View {
        Group {
            if size == .inline { Text(line).font(font(14)).lineLimit(1) }
            else if size == .circular {
                VStack(spacing: 3) {
                    Image(systemName: content.isPlaying ? "music.note" : "pause.fill")
                    Text(content.isPlaying ? "PLAYING" : "PAUSED").font(.system(size: 7, weight: .semibold))
                }
            } else if size == .rectangular { VStack(alignment: alignment, spacing: 3) { metadata; lyric } }
            else {
                if !["albumCard", "vinyl", "nowPlaying", "retro"].contains(style.templateID),
                   style.artwork.placement == .thumbnail || style.artwork.placement == .feature {
                    HStack(spacing: 12) { art(compact ? 32 : 64); composition }
                } else { composition }
            }
        }
        .multilineTextAlignment(style.typography.alignment == .center ? .center : (style.typography.alignment == .trailing ? .trailing : .leading))
        .foregroundStyle(color("primaryLyric"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var composition: some View {
        switch style.templateID {
        case "albumCard", "vinyl":
            if size == .small {
                VStack(spacing: 6) {
                    HStack(spacing: 8) { if style.artwork.placement != .hidden { art(28) }; metadata }
                    Spacer(minLength: 0); lines; Spacer(minLength: 0); footer
                }
            } else if size == .medium {
                HStack(spacing: 16) { if style.artwork.placement != .hidden { art(90) }; VStack(alignment: alignment, spacing: 8) { metadata; lines; footer } }
            } else {
                VStack(alignment: alignment, spacing: 10) { if style.artwork.placement != .hidden { art(size == .large ? 120 : 42) }; lines; metadata; footer }
            }
        case "nowPlaying":
            VStack(spacing: 8) {
                HStack(spacing: 10) { if style.artwork.placement != .hidden { art(compact ? 28 : 42) }; metadata }
                Spacer(minLength: 0); lines; Spacer(minLength: 0); footer
            }
        case "poster":
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(color("accent")).frame(width: 4)
                VStack(alignment: alignment, spacing: 8) { lines; Spacer(minLength: 0); metadata; footer }
            }
        case "editorial":
            VStack(alignment: alignment, spacing: 8) {
                metadata; Rectangle().fill(color("border")).frame(height: 1)
                Spacer(minLength: 0); lines; Spacer(minLength: 0); footer
            }
        case "glass":
            VStack(alignment: alignment, spacing: 8) { metadata; Spacer(minLength: 0); lines; footer }
                .padding(12).background(color("background").opacity(monochrome ? 0.08 : 0.9), in: .rect(cornerRadius: style.cornerRadius))
        case "neon":
            VStack(spacing: 8) { metadata; Spacer(minLength: 0); lines; Spacer(minLength: 0); footer }
                .padding(10).overlay(RoundedRectangle(cornerRadius: style.cornerRadius).stroke(color("accent"), lineWidth: 2))
        case "quote":
            VStack(alignment: alignment, spacing: 4) {
                if style.details.quotes { Text("“").font(.system(size: size == .large ? 56 : 28, design: .serif)).foregroundStyle(color("accent")).accessibilityHidden(true) }
                lines; Spacer(minLength: 0); metadata; footer
            }
        case "fullBleed":
            VStack(alignment: alignment, spacing: 8) {
                Spacer(minLength: 0); lines; metadata; footer
            }.padding(8).background(.black.opacity(monochrome ? 0 : 0.55), in: .rect(cornerRadius: style.cornerRadius))
        case "retro":
            VStack(spacing: 8) {
                HStack { if style.artwork.placement != .hidden { art(28) }; metadata }
                lines.padding(8).background(color("accent").opacity(0.12), in: .rect(cornerRadius: 4))
                footer
                if !compact { HStack(spacing: 24) { Image(systemName: "backward.end.fill"); Image(systemName: content.isPlaying ? "play.fill" : "pause.fill"); Image(systemName: "forward.end.fill") }.font(.caption).accessibilityLabel("Playback decoration") }
            }
        case "karaoke":
            VStack(alignment: alignment, spacing: 10) {
                metadata; Spacer(minLength: 0); lyric; Spacer(minLength: 0)
                if style.details.next { context(content.next, opacity: style.typography.nextOpacity) }; footer
            }
        default:
            VStack(alignment: alignment, spacing: 8) {
                if style.templateID != "hero" { metadata }
                Spacer(minLength: 0); lines; Spacer(minLength: 0)
                if style.templateID == "hero" { metadata }; footer
            }
        }
    }
}

public struct WidgetArtwork: View {
    let content: WidgetPresentation
    let style: WidgetStylePrefs
    var monochrome = false
    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                style.palette["secondaryBackground"].color
                #if canImport(UIKit)
                if let data = content.artworkData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                } else {
                    Image(systemName: "music.note").font(.system(size: min(proxy.size.width, proxy.size.height) * 0.35)).foregroundStyle(.white.opacity(0.75))
                }
                #else
                Image(systemName: "music.note")
                #endif
                if style.artwork.shape == .vinyl {
                    Circle().stroke(.black.opacity(0.6), lineWidth: min(proxy.size.width, proxy.size.height) * 0.18).padding(5)
                    Circle().fill(.black).frame(width: 8, height: 8)
                }
                style.palette["accent"].color.opacity(style.artwork.tint)
            }
            .blur(radius: style.artwork.blur)
            .clipShape(RoundedRectangle(cornerRadius: style.artwork.shape == .square ? 0 : (style.artwork.shape == .rounded ? style.cornerRadius : min(proxy.size.width, proxy.size.height) / 2)))
            .opacity(style.artwork.opacity).saturation(monochrome ? 0 : 1)
        }
    }
}

public struct WidgetStudioBackground: View {
    let style: WidgetStylePrefs
    let content: WidgetPresentation
    public init(style: WidgetStylePrefs, content: WidgetPresentation) {
        self.style = WidgetStyleResolver.resolve(style, album: content.albumColor); self.content = content
    }
    private var backgroundArtworkStyle: WidgetStylePrefs {
        var p = style; p.artwork.shape = .square
        return p
    }
    private var colors: [Color] {
        var result = [style.palette["background"].color, style.palette["secondaryBackground"].color]
        if style.background.threeColors { result.append(style.palette["tertiaryBackground"].color) }
        return result
    }
    public var body: some View {
        ZStack {
            switch style.background.fill {
            case .system: Color.clear
            case .solid: colors[0]
            case .linear:
                LinearGradient(colors: colors, startPoint: style.background.direction == .horizontal ? .leading : (style.background.direction == .vertical ? .top : .topLeading), endPoint: style.background.direction == .horizontal ? .trailing : (style.background.direction == .vertical ? .bottom : .bottomTrailing))
            case .radial: RadialGradient(colors: colors, center: .topLeading, startRadius: 0, endRadius: 350)
            case .glow:
                colors[0]
                RadialGradient(colors: [style.palette["glow"].color.opacity(0.3), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
                RadialGradient(colors: [colors[1], .clear], center: .bottomLeading, startRadius: 0, endRadius: 240)
            case .artwork:
                colors[0]
                WidgetArtwork(content: content, style: backgroundArtworkStyle)
                Color.black.opacity(max(0.55, style.artwork.darkening))
            }
            if style.background.treatment == .frosted { Color.white.opacity(0.08) }
            if style.background.treatment == .paper { Color.white.opacity(0.05) }
            if style.background.treatment == .outline || style.background.treatment == .neon {
                RoundedRectangle(cornerRadius: style.cornerRadius).stroke(style.palette["border"].color.opacity(0.7), lineWidth: 1).padding(4)
            }
        }
    }
}
#endif
