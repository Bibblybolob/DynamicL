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
                }
                Text("Changes apply to the Live Activity instantly — no need to restart playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Live Activity Style")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Preview

    private var previewPalette: LAPalette {
        LAStyleStore.resolve(prefs: prefs, albumDominant: DominantColorExtractor.cached(for: model.provider?.lastAlbumImageURL ?? ""))
    }

    private var previewCard: some View {
        let palette = previewPalette
        return VStack(alignment: .leading, spacing: 8) {
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
                Image(systemName: "pause.fill")
                    .font(.footnote)
                    .foregroundStyle(palette.text.color)
            }
            Text("This is how your lyrics will look")
                .font(prefs.fontStyle.laFont(fixedSize: 22, weight: .bold))
                .foregroundStyle(palette.text.color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.text.color.opacity(0.25))
                    Capsule().fill(palette.accent.color).frame(width: geo.size.width * 0.62)
                }
            }
            .frame(height: 8)
            Text("and the next line follows right here")
                .font(prefs.fontStyle.laFont(.footnote))
                .foregroundStyle(palette.text.color.opacity(0.5))
        }
        .padding(16)
        .background(
            LinearGradient(colors: [palette.backgroundTop.color, palette.backgroundBottom.color],
                           startPoint: .top, endPoint: .bottom),
            in: .rect(cornerRadius: 20)
        )
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
