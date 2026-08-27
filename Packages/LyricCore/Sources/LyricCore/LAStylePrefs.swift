import Foundation

/// Live Activity appearance preferences, chosen in-app and shared with the
/// widget extension through the app group so restyling needs no content push.
public struct LAStylePrefs: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case hotPink
        case spotifyGreen
        case mcRed
        case midnight
        case ocean
        case sunset
        case mono
        case bubblegum
        case forest
        case lavender
        case luxeGold
        case vaporwave
        case crimson
        case arctic
        case espresso
        /// Tint everything from the current song's album-art dominant color.
        case album
    }

    /// Presets that change the information density of the Live Activity and
    /// the larger home-screen widgets.
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case player
        case lyricsFocus
        case minimal
    }

    /// How artwork is presented when the selected layout includes it.
    public enum ArtworkStyle: String, Codable, CaseIterable, Sendable {
        case vinyl
        case square
        case hidden
    }

    public enum TextAlignment: String, Codable, CaseIterable, Sendable {
        case leading
        case center
    }

    public enum FontStyle: String, Codable, CaseIterable, Sendable {
        case rounded
        case serif
        case mono
        case standard
        // Bundled open-license typefaces.
        case bungee
        case bebas
        case baloo
        case pacifico
        case playfair
        case grotesk
    }

    /// Controls how much vertical space the hero lyric can use. Balanced and
    /// large allow a second line, which is safer than letting a long lyric
    /// escape the Live Activity's width.
    public enum LyricScale: String, Codable, CaseIterable, Sendable {
        case compact
        case balanced
        case large

        public var pointSize: Double {
            switch self {
            case .compact: return 20
            case .balanced: return 23
            case .large: return 27
            }
        }

        public var minimumScale: Double {
            switch self {
            case .compact: return 0.46
            case .balanced: return 0.42
            case .large: return 0.38
            }
        }

        public var maximumLines: Int {
            self == .compact ? 1 : 2
        }

        /// Total height reserved for the hero, not the height of each line.
        public var totalHeight: Double {
            self == .compact ? 29 : (self == .balanced ? 52 : 60)
        }
    }

    public var theme: Theme
    public var layout: Layout
    public var artworkStyle: ArtworkStyle
    public var textAlignment: TextAlignment
    public var fontStyle: FontStyle
    public var lyricScale: LyricScale
    /// Shows the title and artist row above the active lyric.
    public var showTrackInfo: Bool
    /// Shows transport buttons wherever the surface supports them.
    public var showControls: Bool
    /// Optional secondary context under the current lyric.
    public var showNextLine: Bool
    /// Optional self-advancing playback progress capsule.
    public var showProgressBar: Bool
    /// Stepped widget animations (equalizer bars, marquee, shimmer, pulse).
    public var animationsEnabled: Bool
    /// Proportionally highlights the active lyric in the main lyrics view.
    /// LRC supplies line timestamps, so the app sweeps across each line.
    public var karaokeEnabled: Bool

    public init(theme: Theme = .hotPink,
                layout: Layout = .player,
                artworkStyle: ArtworkStyle = .vinyl,
                textAlignment: TextAlignment = .leading,
                fontStyle: FontStyle = .rounded,
                lyricScale: LyricScale = .balanced,
                showTrackInfo: Bool = true,
                showControls: Bool = true,
                showNextLine: Bool = true,
                showProgressBar: Bool = true,
                animationsEnabled: Bool = true,
                karaokeEnabled: Bool = true) {
        self.theme = theme
        self.layout = layout
        self.artworkStyle = artworkStyle
        self.textAlignment = textAlignment
        self.fontStyle = fontStyle
        self.lyricScale = lyricScale
        self.showTrackInfo = showTrackInfo
        self.showControls = showControls
        self.showNextLine = showNextLine
        self.showProgressBar = showProgressBar
        self.animationsEnabled = animationsEnabled
        self.karaokeEnabled = karaokeEnabled
    }

    public static let `default` = LAStylePrefs()

    /// Custom decoding so prefs saved before a field existed don't nuke the
    /// whole record back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .hotPink
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .player
        artworkStyle = try c.decodeIfPresent(ArtworkStyle.self, forKey: .artworkStyle) ?? .vinyl
        textAlignment = try c.decodeIfPresent(TextAlignment.self, forKey: .textAlignment) ?? .leading
        fontStyle = try c.decodeIfPresent(FontStyle.self, forKey: .fontStyle) ?? .rounded
        lyricScale = try c.decodeIfPresent(LyricScale.self, forKey: .lyricScale) ?? .balanced
        showTrackInfo = try c.decodeIfPresent(Bool.self, forKey: .showTrackInfo) ?? true
        showControls = try c.decodeIfPresent(Bool.self, forKey: .showControls) ?? true
        showNextLine = try c.decodeIfPresent(Bool.self, forKey: .showNextLine) ?? true
        showProgressBar = try c.decodeIfPresent(Bool.self, forKey: .showProgressBar) ?? true
        animationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? true
        karaokeEnabled = try c.decodeIfPresent(Bool.self, forKey: .karaokeEnabled) ?? true
    }
}

/// A color carried as raw components so both processes (app + extension)
/// share one definition without importing SwiftUI.
public struct RGB: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }
}

/// Full color scheme for the Live Activity chrome.
public struct LAPalette: Equatable, Sendable {
    public var backgroundTop: RGB
    public var backgroundBottom: RGB
    public var accent: RGB
    /// Primary text color — dark on bright palettes, white elsewhere.
    public var text: RGB

    public init(backgroundTop: RGB, backgroundBottom: RGB, accent: RGB, text: RGB) {
        self.backgroundTop = backgroundTop
        self.backgroundBottom = backgroundBottom
        self.accent = accent
        self.text = text
    }
}

public extension LAStylePrefs.Theme {
    var palette: LAPalette {
        switch self {
        case .hotPink:
            return LAPalette(
                backgroundTop: RGB(r: 1.00, g: 0.18, b: 0.47),
                backgroundBottom: RGB(r: 0.62, g: 0.05, b: 0.42),
                accent: RGB(r: 1.00, g: 0.92, b: 0.98),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .spotifyGreen:
            return LAPalette(
                backgroundTop: RGB(r: 0.10, g: 0.90, b: 0.55),
                backgroundBottom: RGB(r: 0.02, g: 0.35, b: 0.22),
                accent: RGB(r: 0.06, g: 0.05, b: 0.05),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .mcRed:
            // Order-tracking energy: red field, golden-yellow accents.
            return LAPalette(
                backgroundTop: RGB(r: 0.85, g: 0.16, b: 0.11),
                backgroundBottom: RGB(r: 0.55, g: 0.07, b: 0.05),
                accent: RGB(r: 1.00, g: 0.78, b: 0.18),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .midnight:
            return LAPalette(
                backgroundTop: RGB(r: 0.24, g: 0.13, b: 0.55),
                backgroundBottom: RGB(r: 0.06, g: 0.04, b: 0.18),
                accent: RGB(r: 0.64, g: 0.55, b: 1.00),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .ocean:
            return LAPalette(
                backgroundTop: RGB(r: 0.02, g: 0.55, b: 0.90),
                backgroundBottom: RGB(r: 0.01, g: 0.20, b: 0.45),
                accent: RGB(r: 0.55, g: 0.95, b: 1.00),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .sunset:
            return LAPalette(
                backgroundTop: RGB(r: 1.00, g: 0.45, b: 0.20),
                backgroundBottom: RGB(r: 0.70, g: 0.12, b: 0.25),
                accent: RGB(r: 1.00, g: 0.85, b: 0.40),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .mono:
            return LAPalette(
                backgroundTop: RGB(r: 0.14, g: 0.14, b: 0.16),
                backgroundBottom: RGB(r: 0.04, g: 0.04, b: 0.05),
                accent: RGB(r: 0.95, g: 0.95, b: 0.97),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .bubblegum:
            return LAPalette(
                backgroundTop: RGB(r: 1.00, g: 0.55, b: 0.78),
                backgroundBottom: RGB(r: 0.62, g: 0.16, b: 0.66),
                accent: RGB(r: 1.00, g: 0.95, b: 0.55),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .forest:
            return LAPalette(
                backgroundTop: RGB(r: 0.10, g: 0.45, b: 0.28),
                backgroundBottom: RGB(r: 0.03, g: 0.15, b: 0.11),
                accent: RGB(r: 0.72, g: 1.00, b: 0.55),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .lavender:
            return LAPalette(
                backgroundTop: RGB(r: 0.68, g: 0.58, b: 1.00),
                backgroundBottom: RGB(r: 0.30, g: 0.22, b: 0.60),
                accent: RGB(r: 1.00, g: 0.90, b: 1.00),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .luxeGold:
            return LAPalette(
                backgroundTop: RGB(r: 0.12, g: 0.10, b: 0.06),
                backgroundBottom: RGB(r: 0.03, g: 0.02, b: 0.01),
                accent: RGB(r: 0.92, g: 0.75, b: 0.35),
                text: RGB(r: 0.98, g: 0.94, b: 0.86)
            )
        case .vaporwave:
            return LAPalette(
                backgroundTop: RGB(r: 0.95, g: 0.25, b: 0.65),
                backgroundBottom: RGB(r: 0.10, g: 0.30, b: 0.85),
                accent: RGB(r: 0.20, g: 1.00, b: 0.95),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .crimson:
            return LAPalette(
                backgroundTop: RGB(r: 0.70, g: 0.05, b: 0.15),
                backgroundBottom: RGB(r: 0.25, g: 0.01, b: 0.05),
                accent: RGB(r: 1.00, g: 0.55, b: 0.50),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .arctic:
            return LAPalette(
                backgroundTop: RGB(r: 0.65, g: 0.85, b: 1.00),
                backgroundBottom: RGB(r: 0.10, g: 0.35, b: 0.65),
                accent: RGB(r: 0.05, g: 0.15, b: 0.30),
                text: RGB(r: 0.04, g: 0.09, b: 0.18)
            )
        case .espresso:
            return LAPalette(
                backgroundTop: RGB(r: 0.42, g: 0.27, b: 0.17),
                backgroundBottom: RGB(r: 0.12, g: 0.07, b: 0.04),
                accent: RGB(r: 0.90, g: 0.72, b: 0.48),
                text: RGB(r: 1, g: 1, b: 1)
            )
        case .album:
            // Real colors arrive per-song via ContentState; this fallback
            // renders until the extractor's first sample lands.
            return LAPalette(
                backgroundTop: RGB(r: 0.30, g: 0.30, b: 0.34),
                backgroundBottom: RGB(r: 0.08, g: 0.08, b: 0.10),
                accent: RGB(r: 1.00, g: 0.75, b: 0.85),
                text: RGB(r: 1, g: 1, b: 1)
            )
        }
    }
}

public extension LAStylePrefs.FontStyle {
    /// SwiftUI `Font.Design` for the four system styles; bundled fonts ignore it.
    var designName: String {
        switch self {
        case .rounded: return "rounded"
        case .serif: return "serif"
        case .mono: return "mono"
        default: return "standard"
        }
    }

    /// PostScript family name of a bundled typeface; nil for system styles.
    var customFamily: String? {
        switch self {
        case .bungee: return "Bungee"
        case .bebas: return "Bebas Neue"
        case .baloo: return "Baloo 2"
        case .pacifico: return "Pacifico"
        case .playfair: return "Playfair Display"
        case .grotesk: return "Space Grotesk"
        default: return nil
        }
    }
}

public enum LAStyleStore {
    static let key = "laStylePrefs"

    public static func load() -> LAStylePrefs {
        guard let data = UserDefaults(suiteName: SharedNowPlaying.appGroupID)?.data(forKey: key),
              let prefs = try? JSONDecoder().decode(LAStylePrefs.self, from: data) else {
            return .default
        }
        return prefs
    }

    public static func save(_ prefs: LAStylePrefs) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults(suiteName: SharedNowPlaying.appGroupID)?.set(data, forKey: key)
    }

    /// Palette for the given prefs, substituting the song's extracted album
    /// color when Album mode is active and a sample is available.
    public static func resolve(prefs: LAStylePrefs, albumDominant: RGB?) -> LAPalette {
        guard prefs.theme == .album, let dominant = albumDominant else {
            return prefs.theme.palette
        }
        return adaptivePalette(from: dominant)
    }

    /// Builds a gradient palette around one dominant color: the top edge is
    /// the boosted color itself, the bottom is a heavily darkened variant,
    /// and the accent is pushed toward pastel so it pops on both.
    public static func adaptivePalette(from color: RGB) -> LAPalette {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let boosted = RGB(
            r: clamp(color.r * 1.15 + 0.05),
            g: clamp(color.g * 1.15 + 0.05),
            b: clamp(color.b * 1.15 + 0.05)
        )
        let darkened = RGB(r: boosted.r * 0.28, g: boosted.g * 0.28, b: boosted.b * 0.32)
        let pastel = RGB(
            r: clamp(boosted.r * 0.35 + 0.65),
            g: clamp(boosted.g * 0.35 + 0.65),
            b: clamp(boosted.b * 0.35 + 0.68)
        )
        // Very dark or very bright sources still need readable contrast.
        let luminance = 0.299 * boosted.r + 0.587 * boosted.g + 0.114 * boosted.b
        let textColor = luminance > 0.72
            ? RGB(r: 0.07, g: 0.07, b: 0.09)
            : RGB(r: 1, g: 1, b: 1)
        return LAPalette(backgroundTop: boosted, backgroundBottom: darkened, accent: pastel, text: textColor)
    }
}
