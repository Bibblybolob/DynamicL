import SwiftUI
import WidgetKit
import LyricCore

/// In-app picker for Live Activity appearance. Writes through the shared app
/// group, so the running activity re-renders with the new look within a tick.
struct AppearanceView: View {
    @Environment(AppModel.self) private var model
    @State private var prefs: LAStylePrefs = LAStyleStore.load()

    private let swatchColumns = [GridItem(.adaptive(minimum: 78), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                previewCard
                section(title: "Layout", icon: "rectangle.3.group") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Layout preset", selection: Binding(
                            get: { prefs.layout },
                            set: { newValue in setStyle { $0.layout = newValue } }
                        )) {
                            ForEach(LAStylePrefs.Layout.allCases, id: \.self) { layout in
                                Text(layout.label).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Artwork", selection: Binding(
                            get: { prefs.artworkStyle },
                            set: { newValue in setStyle { $0.artworkStyle = newValue } }
                        )) {
                            ForEach(LAStylePrefs.ArtworkStyle.allCases, id: \.self) { artwork in
                                Text(artwork.label).tag(artwork)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Lyric alignment", selection: Binding(
                            get: { prefs.textAlignment },
                            set: { newValue in setStyle { $0.textAlignment = newValue } }
                        )) {
                            ForEach(LAStylePrefs.TextAlignment.allCases, id: \.self) { alignment in
                                Text(alignment.label).tag(alignment)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(12)
                    .background(.tertiary.opacity(0.35), in: .rect(cornerRadius: 14))
                }
                section(title: "Surface", icon: "square.stack.3d.up") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(LAStylePrefs.SurfaceStyle.allCases, id: \.self) { surface in
                            SurfaceOption(
                                surface: surface,
                                palette: surfacePalette(for: surface),
                                isSelected: prefs.surfaceStyle == surface
                            ) {
                                setStyle { $0.surfaceStyle = surface }
                            }
                        }
                    }
                }
                section(title: "Theme", icon: "paintpalette") {
                    LazyVGrid(columns: swatchColumns, spacing: 10) {
                        ForEach(LAStylePrefs.Theme.allCases, id: \.self) { theme in
                            ThemeSwatch(
                                theme: theme,
                                isSelected: prefs.theme == theme
                            ) {
                                setStyle { $0.theme = theme }
                            }
                        }
                    }
                }
                section(title: "Font", icon: "textformat") {
                    LazyVGrid(columns: swatchColumns, spacing: 10) {
                        ForEach(LAStylePrefs.FontStyle.allCases, id: \.self) { style in
                            FontOption(style: style, isSelected: prefs.fontStyle == style) {
                                setStyle { $0.fontStyle = style }
                            }
                        }
                    }
                }
                section(title: "Lyric layout", icon: "text.alignleft") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { prefs.showTrackInfo },
                            set: { newValue in setStyle { $0.showTrackInfo = newValue } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show track details")
                                Text("Displays the song title and artist above the lyric.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { prefs.showControls },
                            set: { newValue in setStyle { $0.showControls = newValue } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show playback controls")
                                Text("Adds play/pause and skip buttons to supported surfaces.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("Lyric size", selection: Binding(
                            get: { prefs.lyricScale },
                            set: { newValue in setStyle { $0.lyricScale = newValue } }
                        )) {
                            ForEach(LAStylePrefs.LyricScale.allCases, id: \.self) { scale in
                                Text(scale.label).tag(scale)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle(isOn: Binding(
                            get: { prefs.showNextLine },
                            set: { newValue in setStyle { $0.showNextLine = newValue } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show next line")
                                Text("Keeps the upcoming lyric visible under the hero.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { prefs.showProgressBar },
                            set: { newValue in setStyle { $0.showProgressBar = newValue } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show progress")
                                Text("Uses the system clock so playback stays smooth.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(.tertiary.opacity(0.35), in: .rect(cornerRadius: 14))
                }
                section(title: "Motion", icon: "waveform.path.ecg") {
                    Toggle(isOn: Binding(
                        get: { prefs.animationsEnabled },
                        set: { newValue in setStyle { $0.animationsEnabled = newValue } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Animations")
                                .font(.subheadline.weight(.medium))
                            Text("Breathing live-dot, native waveform motion & auto-fit lyrics.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Color.accentColor)

                    Toggle(isOn: Binding(
                        get: { prefs.karaokeEnabled },
                        set: { newValue in setStyle { $0.karaokeEnabled = newValue } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Karaoke sweep")
                                .font(.subheadline.weight(.medium))
                            Text("Highlights the active lyric as the song plays.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Color.accentColor)
                }
                Text("Changes apply to the Live Activity and widgets. No need to restart playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset appearance") {
                    prefs = .default
                    LAStyleStore.save(.default)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .font(.caption.weight(.semibold))
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Preview

    private var previewPalette: LAPalette {
        let base = LAStyleStore.resolve(
            prefs: prefs,
            albumDominant: DominantColorExtractor.cached(for: model.provider?.lastAlbumImageURL ?? "")
        )
        return LAStyleStore.applySurface(prefs.surfaceStyle, to: base)
    }

    private func surfacePalette(for surface: LAStylePrefs.SurfaceStyle) -> LAPalette {
        let base = LAStyleStore.resolve(
            prefs: prefs,
            albumDominant: DominantColorExtractor.cached(for: model.provider?.lastAlbumImageURL ?? "")
        )
        return LAStyleStore.applySurface(surface, to: base)
    }

    private var previewCard: some View {
        let palette = previewPalette
        return VStack(alignment: .leading, spacing: 8) {
            if prefs.layout == .player && prefs.artworkStyle != .hidden {
                HStack {
                    Spacer()
                    LAAlbumDisc(
                        urlString: model.provider?.lastAlbumImageURL,
                        size: 54,
                        style: prefs.artworkStyle
                    )
                }
            }
            if prefs.showTrackInfo && prefs.layout != .minimal {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.caption2.bold())
                        .foregroundStyle(palette.accent.color)
                    if prefs.animationsEnabled {
                        LAPulseDot(color: palette.accent.color, animate: false)
                    }
                    Text("Track Title — Artist")
                        .font(prefs.fontStyle.laFont(.caption2, weight: .semibold))
                        .foregroundStyle(palette.text.color.opacity(0.7))
                        .lineLimit(1)
                    Spacer()
                }
            }
            LAMarquee(
                text: "This is how your lyrics will look",
                font: prefs.fontStyle.laFont(
                    fixedSize: CGFloat(prefs.lyricScale.pointSize),
                    weight: .bold
                ),
                color: palette.text.color,
                animations: false,
                pointSize: CGFloat(prefs.lyricScale.pointSize),
                minScale: CGFloat(prefs.lyricScale.minimumScale),
                lineHeight: CGFloat(prefs.lyricScale.totalHeight),
                maxLines: prefs.lyricScale.maximumLines,
                textAlignment: prefs.textAlignment == .center ? .center : .leading
            )
            if prefs.showProgressBar && prefs.layout != .minimal {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.text.color.opacity(0.25))
                        Capsule().fill(palette.accent.color).frame(width: geo.size.width * 0.62)
                    }
                }
                .frame(height: 8)
            }
            if prefs.showNextLine && prefs.layout != .minimal {
                Text("and the next line follows right here")
                    .font(prefs.fontStyle.laFont(.footnote))
                    .foregroundStyle(palette.text.color.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(prefs.textAlignment == .center ? .center : .leading)
            }
            if prefs.showControls && prefs.layout != .minimal {
                HStack(spacing: 0) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill")
                        .padding(.horizontal, 16)
                    Image(systemName: "forward.fill")
                }
                .font(.caption)
                .foregroundStyle(palette.text.color)
                .frame(maxWidth: .infinity,
                       alignment: prefs.textAlignment == .center ? .center : .leading)
            }
        }
        .padding(16)
        .background {
            surfacePreviewBackground(palette: palette, surface: prefs.surfaceStyle)
        }
        .clipShape(.rect(cornerRadius: 20))
    }

    @ViewBuilder
    private func surfacePreviewBackground(palette: LAPalette,
                                           surface: LAStylePrefs.SurfaceStyle) -> some View {
        switch surface {
        case .gradient:
            LinearGradient(
                colors: [palette.backgroundTop.color, palette.backgroundBottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .glass:
            ZStack {
                palette.backgroundBottom.color
                LinearGradient(
                    colors: [palette.backgroundTop.color.opacity(0.78),
                             palette.backgroundBottom.color.opacity(0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Color.white.opacity(0.08)
            }
        case .neon:
            ZStack {
                palette.backgroundBottom.color
                RadialGradient(
                    colors: [palette.accent.color.opacity(0.46), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 220
                )
                LinearGradient(
                    colors: [.clear, palette.accent.color.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        case .paper:
            LinearGradient(
                colors: [palette.backgroundTop.color, palette.backgroundBottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
        case .outline:
            ZStack {
                palette.backgroundBottom.color
                LinearGradient(
                    colors: [palette.backgroundTop.color.opacity(0.65),
                             palette.backgroundBottom.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RoundedRectangle(cornerRadius: 20)
                    .stroke(palette.accent.color.opacity(0.5), lineWidth: 1)
                    .padding(1)
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func setStyle(_ mutate: (inout LAStylePrefs) -> Void) {
        var updated = prefs
        mutate(&updated)
        prefs = updated
        LAStyleStore.save(updated)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct ThemeSwatch: View {
    let theme: LAStylePrefs.Theme
    let isSelected: Bool
    let action: () -> Void

    private var palette: LAPalette {
        theme.palette
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [palette.backgroundTop.color, palette.backgroundBottom.color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "music.note.fill")
                        .font(.body.bold())
                        .foregroundStyle(palette.accent.color)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white, lineWidth: 2.5)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .offset(x: 24, y: -24)
                    }
                }
                .frame(height: 58)
                Text(theme.label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct FontOption: View {
    let style: LAStylePrefs.FontStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("Aa")
                    .font(style.laFont(fixedSize: 26, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(style.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SurfaceOption: View {
    let surface: LAStylePrefs.SurfaceStyle
    let palette: LAPalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [palette.backgroundTop.color,
                                         palette.backgroundBottom.color],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: surface.icon)
                        .font(.body.bold())
                        .foregroundStyle(palette.accent.color)
                    if surface == .outline {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(palette.accent.color.opacity(0.7), lineWidth: 1.5)
                            .padding(2)
                    }
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white, lineWidth: 2.5)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .offset(x: 36, y: -24)
                    }
                }
                .frame(height: 52)
                Text(surface.label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

extension LAStylePrefs.Theme {
    var label: String {
        switch self {
        case .hotPink: return "Hot Pink"
        case .spotifyGreen: return "Spotify"
        case .mcRed: return "McRed"
        case .midnight: return "Midnight"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .mono: return "Mono"
        case .bubblegum: return "Bubblegum"
        case .forest: return "Forest"
        case .lavender: return "Lavender"
        case .luxeGold: return "Luxe Gold"
        case .vaporwave: return "Vaporwave"
        case .crimson: return "Crimson"
        case .arctic: return "Arctic"
        case .espresso: return "Espresso"
        case .album: return "Album"
        }
    }
}

extension LAStylePrefs.Layout {
    var label: String {
        switch self {
        case .player: return "Player"
        case .lyricsFocus: return "Lyrics"
        case .minimal: return "Minimal"
        }
    }
}

extension LAStylePrefs.ArtworkStyle {
    var label: String {
        switch self {
        case .vinyl: return "Vinyl"
        case .square: return "Square"
        case .hidden: return "None"
        }
    }
}

extension LAStylePrefs.SurfaceStyle {
    var label: String {
        switch self {
        case .gradient: return "Gradient"
        case .glass: return "Glass"
        case .neon: return "Neon"
        case .paper: return "Paper"
        case .outline: return "Outline"
        }
    }

    var icon: String {
        switch self {
        case .gradient: return "circle.lefthalf.filled"
        case .glass: return "square.on.square"
        case .neon: return "bolt.fill"
        case .paper: return "doc.text"
        case .outline: return "rectangle"
        }
    }
}

extension LAStylePrefs.TextAlignment {
    var label: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        }
    }
}

extension LAStylePrefs.FontStyle {
    var label: String {
        switch self {
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        case .standard: return "Default"
        case .bungee: return "Bungee"
        case .bebas: return "Bebas"
        case .baloo: return "Baloo"
        case .pacifico: return "Pacifico"
        case .playfair: return "Playfair"
        case .grotesk: return "Grotesk"
        }
    }
}

extension LAStylePrefs.LyricScale {
    var label: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .large: return "Large"
        }
    }
}
