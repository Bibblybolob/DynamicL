import Foundation

/// Pure rendering adaptation: never mutates saved choices or touches playback state.
public enum WidgetStyleResolver {
    public static func resolve(_ style: WidgetStylePrefs, album: RGB?, compact: Bool = false) -> WidgetStylePrefs {
        var p = style.normalized
        if !WidgetTemplate.all.contains(where: { $0.id == p.templateID }) { p.templateID = "minimal" }
        if !WidgetFont.all.contains(where: { $0.id == p.typography.fontID }) { p.typography.fontID = "rounded" }
        if let mode = p.palette.dynamic, let c = album, [c.r, c.g, c.b].allSatisfy(\.isFinite) {
            func scaled(_ factor: Double) -> WidgetColor { WidgetColor(RGB(r: c.r * factor, g: c.g * factor, b: c.b * factor)) }
            p.palette.colors["background"] = scaled(mode == "albumDarkened" ? 0.18 : 0.32)
            p.palette.colors["secondaryBackground"] = scaled(0.12)
            p.palette.colors["accent"] = mode == "albumComplementary"
                ? WidgetColor(RGB(r: 1 - c.r * 0.5, g: 1 - c.g * 0.5, b: 1 - c.b * 0.5))
                : WidgetColor(RGB(r: 0.6 + c.r * 0.4, g: 0.6 + c.g * 0.4, b: 0.6 + c.b * 0.4))
            if mode == "albumArt" { p.background.fill = .artwork }
        }
        if p.artwork.placement == .background || p.artwork.placement == .fullBleed { p.background.fill = .artwork }
        if p.background.fill == .artwork {
            // Arbitrary album pixels cannot guarantee contrast. Use a bounded dark
            // scrim and light semantic foregrounds without changing saved colors.
            p.palette.colors["primaryLyric"] = .init(hex: "FFFFFF")
            p.palette.colors["secondaryLyric"] = .init(hex: "E1E6EF")
            p.palette.colors["songTitle"] = .init(hex: "FFFFFF")
            p.palette.colors["artist"] = .init(hex: "D0D8E4")
            p.palette.colors["background"] = .init(hex: "11151D")
        }
        if compact { p.typography.scale = min(1.25, p.typography.scale); p.details.previous = false; p.typography.maxLines = min(3, p.typography.maxLines) }
        return p
    }
}
