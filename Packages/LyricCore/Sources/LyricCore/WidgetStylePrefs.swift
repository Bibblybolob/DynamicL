import Foundation

public struct WidgetColor: Codable, Equatable, Sendable {
    public var hex: String
    public var alpha: Double = 1
    public init(hex: String, alpha: Double = 1) { self.hex = hex; self.alpha = alpha }
    public var rgb: RGB {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        return RGB(r: Double((value >> 16) & 255) / 255, g: Double((value >> 8) & 255) / 255, b: Double(value & 255) / 255)
    }
    public init(_ rgb: RGB) {
        func byte(_ x: Double) -> Int { Int(((x.isFinite ? min(1, max(0, x)) : 0) * 255).rounded()) }
        hex = String(format: "%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }
}

public struct WidgetPalette: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var revision: Int
    public var colors: [String: WidgetColor]
    public var dynamic: String?
    public static let roles = ["background", "secondaryBackground", "tertiaryBackground", "accent", "primaryLyric", "secondaryLyric", "songTitle", "artist", "progressFill", "progressTrack", "border", "glow"]
    public subscript(_ role: String) -> WidgetColor { colors[role] ?? .init(hex: "FFFFFF") }
}

public enum WidgetPaletteCatalog {
    public static let all: [WidgetPalette] = {
        guard let url = Bundle.module.url(forResource: "WidgetPalettes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([WidgetPalette].self, from: data) else { return [] }
        return values
    }()
    public static func find(_ id: String) -> WidgetPalette {
        all.first { $0.id == id } ?? all.first ?? WidgetPalette(id: "midnight", name: "Midnight", category: "Dark", revision: 1, colors: [:])
    }
}

public struct WidgetTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public static let all: [Self] = [
        .init(id: "hero", name: "Lyric Hero", subtitle: "One line, center stage"),
        .init(id: "stack", name: "Lyric Stack", subtitle: "The lines before and after"),
        .init(id: "albumCard", name: "Album Card", subtitle: "A cover and a verse"),
        .init(id: "nowPlaying", name: "Now Playing", subtitle: "Your song at a glance"),
        .init(id: "minimal", name: "Minimal", subtitle: "Room to breathe"),
        .init(id: "poster", name: "Poster", subtitle: "Type with presence"),
        .init(id: "vinyl", name: "Vinyl", subtitle: "A record beside your lyrics"),
        .init(id: "editorial", name: "Editorial", subtitle: "An everyday music journal"),
        .init(id: "glass", name: "Glass", subtitle: "A soft panel over your cover"),
        .init(id: "neon", name: "Neon", subtitle: "A vivid frame after dark"),
        .init(id: "oled", name: "OLED", subtitle: "Pure black, clear lyrics"),
        .init(id: "karaoke", name: "Karaoke", subtitle: "This line and what comes next"),
        .init(id: "quote", name: "Quote", subtitle: "A verse worth keeping"),
        .init(id: "fullBleed", name: "Artwork Full Bleed", subtitle: "The cover sets the scene"),
        .init(id: "retro", name: "Retro Player", subtitle: "A pocket-sized music player")
    ]
}

public struct WidgetFont: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let family: String?
    public static let all: [Self] = [
        .init(id: "standard", name: "System", family: nil), .init(id: "rounded", name: "Rounded", family: nil),
        .init(id: "serif", name: "System Serif", family: nil), .init(id: "mono", name: "Monospaced", family: nil),
        .init(id: "bungee", name: "Bungee · Display", family: "Bungee"), .init(id: "bebas", name: "Bebas Neue · Condensed", family: "Bebas Neue"),
        .init(id: "baloo", name: "Baloo 2 · Playful", family: "Baloo 2"), .init(id: "pacifico", name: "Pacifico · Script", family: "Pacifico"),
        .init(id: "playfair", name: "Playfair · Editorial", family: "Playfair Display"), .init(id: "grotesk", name: "Space Grotesk", family: "Space Grotesk"),
        .init(id: "fraunces", name: "Fraunces · Retro", family: "Fraunces"),
        .init(id: "barlow", name: "Barlow Condensed", family: "Barlow Condensed"),
        .init(id: "dmSerif", name: "DM Serif Display", family: "DM Serif Display"),
        .init(id: "atkinson", name: "Atkinson Hyperlegible", family: "Atkinson Hyperlegible")
    ]
}

/// Stable catalog IDs select designs; enums describe only reusable rendering primitives.
public struct WidgetStylePrefs: Codable, Equatable, Sendable {
    public enum Fill: String, Codable, CaseIterable, Sendable { case system, solid, linear, radial, artwork, glow }
    public enum Direction: String, Codable, CaseIterable, Sendable { case vertical, horizontal, diagonal }
    public enum Treatment: String, Codable, CaseIterable, Sendable { case plain, frosted, paper, outline, neon }
    public enum Placement: String, Codable, CaseIterable, Sendable { case hidden, thumbnail, feature, background, fullBleed }
    public enum Shape: String, Codable, CaseIterable, Sendable { case square, rounded, circle, vinyl }
    public enum Emphasis: String, Codable, CaseIterable, Sendable { case plain, highlight, accent, gradient }
    public var schemaVersion = 2
    public var templateID = "minimal"
    /// Frozen palette values preserve a design when a bundled palette revision changes.
    public var palette = WidgetPaletteCatalog.find("midnight")
    public var background = BackgroundSpec()
    public var typography = TypographySpec()
    public var artwork = ArtworkSpec()
    public var details = DetailVisibility()
    public var cornerRadius: Double = 16
    public init() {}

    public static func preset(template: String, paletteID: String = "midnight") -> Self {
        var p = Self(); p.templateID = template; p.palette = WidgetPaletteCatalog.find(paletteID)
        switch template {
        case "hero": p.typography.scale = 1.3; p.typography.alignment = .center; p.details.title = false
        case "stack": p.details.previous = true; p.details.next = true; p.typography.emphasis = .highlight; p.typography.alignment = .center
        case "albumCard", "nowPlaying", "vinyl", "retro": p.artwork.placement = .feature; p.details.artist = true; p.details.progress = true
        case "poster": p.typography.fontID = "bebas"; p.typography.scale = 1.5; p.typography.uppercase = true
        case "editorial", "quote": p.typography.fontID = "playfair"; p.details.quotes = template == "quote"
        case "glass", "fullBleed": p.background.fill = .artwork; p.artwork.placement = .background; p.background.treatment = template == "glass" ? .frosted : .plain
        case "neon": p.background.treatment = .neon; p.typography.emphasis = .accent
        case "oled": p.palette = WidgetPaletteCatalog.find("oled"); p.background.fill = .solid; p.details.title = false
        case "karaoke": p.typography.scale = 1.25; p.details.next = true; p.typography.emphasis = .accent
        default: break
        }
        if template == "vinyl" { p.artwork.shape = .vinyl }
        return p
    }

    public init(legacy: WidgetAppearance) {
        self.init()
        let old = legacy.normalized
        templateID = old.preset == .lyricStack ? "stack" : (old.preset == .lyricsFocus ? "hero" : "minimal")
        typography.fontID = old.font.rawValue; typography.scale = old.size
        typography.weight = old.weight; typography.alignment = old.alignment
        typography.previousOpacity = old.contextOpacity; typography.nextOpacity = old.contextOpacity
        typography.emphasis = old.preset == .lyricStack ? .highlight : .plain
        details.title = old.showTitle; details.artist = old.showArtist
        details.previous = old.context == .surrounding; details.next = old.context != .current
        cornerRadius = old.roundedHighlight ? 14 : 3
        palette.colors["accent"] = WidgetColor(old.accent)
        palette.colors["background"] = WidgetColor(old.backgroundColor)
        switch old.background {
        case .system: background.fill = .system
        case .solid:
            background.fill = .solid
            let c = old.backgroundColor
            palette.colors["primaryLyric"] = .init(hex: c.r * 0.299 + c.g * 0.587 + c.b * 0.114 > 0.58 ? "000000" : "FFFFFF")
        case .gradient, .album:
            background.fill = .linear
            palette.colors["background"] = WidgetColor(RGB(r: old.accent.r * 0.45, g: old.accent.g * 0.45, b: old.accent.b * 0.45))
            palette.colors["secondaryBackground"] = .init(hex: "000000")
            if old.background == .album { palette.dynamic = "albumDominant" }
        }
    }

    public var normalized: Self {
        var p = self
        func clamp(_ x: Double, _ low: Double, _ high: Double, _ fallback: Double) -> Double { x.isFinite ? min(high, max(low, x)) : fallback }
        p.typography.scale = clamp(p.typography.scale, 0.7, 1.6, 1)
        p.typography.lineSpacing = clamp(p.typography.lineSpacing, 0, 12, 2)
        p.typography.maxLines = min(6, max(1, p.typography.maxLines))
        p.typography.currentOpacity = clamp(p.typography.currentOpacity, 0.5, 1, 1)
        p.typography.previousOpacity = clamp(p.typography.previousOpacity, 0.15, 1, 0.45)
        p.typography.nextOpacity = clamp(p.typography.nextOpacity, 0.15, 1, 0.55)
        p.artwork.opacity = clamp(p.artwork.opacity, 0, 1, 1)
        p.artwork.darkening = clamp(p.artwork.darkening, 0, 0.85, 0.5)
        p.artwork.tint = clamp(p.artwork.tint, 0, 0.8, 0)
        p.artwork.blur = clamp(p.artwork.blur, 0, 16, 0)
        p.artwork.size = clamp(p.artwork.size, 0.6, 1.4, 1)
        p.cornerRadius = clamp(p.cornerRadius, 0, 28, 16)
        return p
    }
}

public extension WidgetStylePrefs {
    struct BackgroundSpec: Codable, Equatable, Sendable {
        public var fill: Fill = .linear
        public var direction: Direction = .diagonal
        public var threeColors: Bool = false
        public var treatment: Treatment = .plain
        public init() {}
        private enum CodingKeys: String, CodingKey { case fill, direction, threeColors, treatment }
        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fill = (try? c.decodeIfPresent(Fill.self, forKey: .fill)) ?? .linear
            direction = (try? c.decodeIfPresent(Direction.self, forKey: .direction)) ?? .diagonal
            threeColors = (try? c.decodeIfPresent(Bool.self, forKey: .threeColors)) ?? false
            treatment = (try? c.decodeIfPresent(Treatment.self, forKey: .treatment)) ?? .plain
        }
    }
    struct TypographySpec: Codable, Equatable, Sendable {
        public var fontID: String = "rounded"
        public var weight: WidgetAppearance.Weight = .bold
        public var scale: Double = 1
        public var alignment: WidgetAppearance.Alignment = .leading
        public var uppercase: Bool = false
        public var lineSpacing: Double = 2
        public var maxLines: Int = 4
        public var currentOpacity: Double = 1
        public var previousOpacity: Double = 0.45
        public var nextOpacity: Double = 0.55
        public var emphasis: Emphasis = .plain
        public var shadow: Bool = false
        public init() {}
        private enum CodingKeys: String, CodingKey { case fontID, weight, scale, alignment, uppercase, lineSpacing, maxLines, currentOpacity, previousOpacity, nextOpacity, emphasis, shadow }
        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontID = (try? c.decodeIfPresent(String.self, forKey: .fontID)) ?? "rounded"
            weight = (try? c.decodeIfPresent(WidgetAppearance.Weight.self, forKey: .weight)) ?? .bold
            scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? 1
            alignment = (try? c.decodeIfPresent(WidgetAppearance.Alignment.self, forKey: .alignment)) ?? .leading
            uppercase = (try? c.decodeIfPresent(Bool.self, forKey: .uppercase)) ?? false
            lineSpacing = (try? c.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? 2
            maxLines = (try? c.decodeIfPresent(Int.self, forKey: .maxLines)) ?? 4
            currentOpacity = (try? c.decodeIfPresent(Double.self, forKey: .currentOpacity)) ?? 1
            previousOpacity = (try? c.decodeIfPresent(Double.self, forKey: .previousOpacity)) ?? 0.45
            nextOpacity = (try? c.decodeIfPresent(Double.self, forKey: .nextOpacity)) ?? 0.55
            emphasis = (try? c.decodeIfPresent(Emphasis.self, forKey: .emphasis)) ?? .plain
            shadow = (try? c.decodeIfPresent(Bool.self, forKey: .shadow)) ?? false
        }
    }
    struct ArtworkSpec: Codable, Equatable, Sendable {
        public var placement: Placement = .hidden
        public var shape: Shape = .rounded
        public var size: Double = 1
        public var opacity: Double = 1
        public var darkening: Double = 0.5
        public var tint: Double = 0
        public var blur: Double = 0
        public init() {}
        private enum CodingKeys: String, CodingKey { case placement, shape, size, opacity, darkening, tint, blur }
        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            placement = (try? c.decodeIfPresent(Placement.self, forKey: .placement)) ?? .hidden
            shape = (try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? .rounded
            size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 1
            opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1
            darkening = (try? c.decodeIfPresent(Double.self, forKey: .darkening)) ?? 0.5
            tint = (try? c.decodeIfPresent(Double.self, forKey: .tint)) ?? 0
            blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0
        }
    }
    struct DetailVisibility: Codable, Equatable, Sendable {
        public var title: Bool = true
        public var artist: Bool = false
        public var album: Bool = false
        public var previous: Bool = false
        public var next: Bool = false
        public var progress: Bool = false
        public var elapsed: Bool = false
        public var remaining: Bool = false
        public var playbackIcon: Bool = false
        public var quotes: Bool = false
        public init() {}
        private enum CodingKeys: String, CodingKey { case title, artist, album, previous, next, progress, elapsed, remaining, playbackIcon, quotes }
        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decodeIfPresent(Bool.self, forKey: .title)) ?? true
            album = (try? c.decodeIfPresent(Bool.self, forKey: .album)) ?? false
            artist = (try? c.decodeIfPresent(Bool.self, forKey: .artist)) ?? false
            previous = (try? c.decodeIfPresent(Bool.self, forKey: .previous)) ?? false
            next = (try? c.decodeIfPresent(Bool.self, forKey: .next)) ?? false
            progress = (try? c.decodeIfPresent(Bool.self, forKey: .progress)) ?? false
            elapsed = (try? c.decodeIfPresent(Bool.self, forKey: .elapsed)) ?? false
            remaining = (try? c.decodeIfPresent(Bool.self, forKey: .remaining)) ?? false
            playbackIcon = (try? c.decodeIfPresent(Bool.self, forKey: .playbackIcon)) ?? false
            quotes = (try? c.decodeIfPresent(Bool.self, forKey: .quotes)) ?? false
        }
    }
}

public extension WidgetStylePrefs {
    private enum CodingKeys: String, CodingKey { case schemaVersion, templateID, palette, background, typography, artwork, details, cornerRadius }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) { schemaVersion = value }
        if let value = try c.decodeIfPresent(String.self, forKey: .templateID) { templateID = value }
        if let value = try c.decodeIfPresent(WidgetPalette.self, forKey: .palette) { palette = value }
        if let value = try c.decodeIfPresent(BackgroundSpec.self, forKey: .background) { background = value }
        if let value = try c.decodeIfPresent(TypographySpec.self, forKey: .typography) { typography = value }
        if let value = try c.decodeIfPresent(ArtworkSpec.self, forKey: .artwork) { artwork = value }
        if let value = try c.decodeIfPresent(DetailVisibility.self, forKey: .details) { details = value }
        if let value = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) { cornerRadius = value }
    }
}
