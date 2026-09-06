import AppIntents
import LyricCore

enum LyricWidgetPreset: String, AppEnum {
    case minimal, lyricsFocus, lyricStack
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .minimal: "Minimal", .lyricsFocus: "Lyrics Focus", .lyricStack: "Lyric Stack"
    ]
    var appearancePreset: WidgetAppearance.Preset { .init(rawValue: rawValue) ?? .minimal }
}

enum LyricWidgetTextSize: String, AppEnum {
    case design, smaller, regular, larger
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Text size"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .design: "Use design", .smaller: "Smaller", .regular: "Regular", .larger: "Larger"
    ]
}

struct WidgetDesignEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved design"
    static let defaultQuery = WidgetDesignQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct WidgetDesignQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetDesignEntity] {
        WidgetDesignStore.load().filter { identifiers.contains($0.id) }.map { .init(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [WidgetDesignEntity] {
        WidgetDesignStore.load().map { .init(id: $0.id, name: $0.name) }
    }
}

struct LyricWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Customize lyrics"
    static let description = IntentDescription("Choose a preset or a design saved in OpenLyrics. Each widget keeps its own selection.")
    @Parameter(title: "Preset", default: .minimal) var preset: LyricWidgetPreset
    @Parameter(title: "Saved design") var design: WidgetDesignEntity?
    @Parameter(title: "Text size", default: .design) var textSize: LyricWidgetTextSize

    @Parameter(title: "Template override") var template: WidgetTemplateEntity?
    @Parameter(title: "Palette override") var palette: WidgetPaletteEntity?
    @Parameter(title: "Font override") var font: WidgetFontEntity?
    @Parameter(title: "Surface", default: .design) var surface: WidgetSurfaceOverride
    @Parameter(title: "Artwork", default: .design) var artwork: WidgetArtworkOverride
    @Parameter(title: "Density", default: .design) var density: WidgetDensityOverride

    var resolvedStyle: WidgetStylePrefs {
        var appearance = WidgetDesignStore.resolveStyle(id: design?.id, fallback: preset.appearancePreset)
        switch textSize {
        case .design: break
        case .smaller: appearance.typography.scale = 0.8
        case .regular: appearance.typography.scale = 1
        case .larger: appearance.typography.scale = 1.2
        }
        if let template { appearance.templateID = template.id }
        if let palette {
            appearance.palette = CustomWidgetPaletteStore.load().first(where: { $0.id == palette.id }) ?? WidgetPaletteCatalog.find(palette.id)
        }
        if let font { appearance.typography.fontID = font.id }
        if surface != .design { appearance.background.fill = .init(rawValue: surface.rawValue) ?? .linear }
        if artwork != .design {
            switch artwork {
            case .hidden: appearance.artwork.placement = .hidden
            case .background: appearance.artwork.placement = .background; appearance.background.fill = .artwork
            case .thumbnail: appearance.artwork.placement = .thumbnail
            default: appearance.artwork.placement = .feature; appearance.artwork.shape = .init(rawValue: artwork.rawValue) ?? .rounded
            }
        }
        if density != .design {
            appearance.details.title = density != .minimal
            appearance.details.artist = density == .detailed
            appearance.details.previous = density == .detailed
            appearance.details.next = density != .minimal
            appearance.details.progress = density == .detailed
        }
        return appearance.normalized
    }
}

struct WidgetTemplateEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Template"
    static let defaultQuery = WidgetTemplateQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct WidgetTemplateQuery: EntityQuery {
    private var all: [WidgetTemplateEntity] { WidgetTemplate.all.map { .init(id: $0.id, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [WidgetTemplateEntity] { all.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [WidgetTemplateEntity] { all }
}
struct WidgetPaletteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Palette"
    static let defaultQuery = WidgetPaletteQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct WidgetPaletteQuery: EntityQuery {
    private var all: [WidgetPaletteEntity] { (WidgetPaletteCatalog.all + CustomWidgetPaletteStore.load()).map { .init(id: $0.id, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [WidgetPaletteEntity] { all.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [WidgetPaletteEntity] { all }
}
struct WidgetFontEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Font"
    static let defaultQuery = WidgetFontQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct WidgetFontQuery: EntityQuery {
    private var all: [WidgetFontEntity] { WidgetFont.all.map { .init(id: $0.id, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [WidgetFontEntity] { all.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [WidgetFontEntity] { all }
}
enum WidgetSurfaceOverride: String, AppEnum {
    case design, system, solid, linear, radial, artwork, glow
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Surface"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .design: "Use design",
        .system: "System",
        .solid: "Solid",
        .linear: "Linear",
        .radial: "Radial",
        .artwork: "Artwork",
        .glow: "Glow"
    ]
}
enum WidgetArtworkOverride: String, AppEnum {
    case design, hidden, thumbnail, square, rounded, circle, vinyl, background
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artwork"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .design: "Use design",
        .hidden: "Hidden",
        .thumbnail: "Thumbnail",
        .square: "Square",
        .rounded: "Rounded",
        .circle: "Circle",
        .vinyl: "Vinyl",
        .background: "Background"
    ]
}
enum WidgetDensityOverride: String, AppEnum {
    case design, minimal, balanced, detailed
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Density"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .design: "Use design",
        .minimal: "Minimal",
        .balanced: "Balanced",
        .detailed: "Detailed"
    ]
}
