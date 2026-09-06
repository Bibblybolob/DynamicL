import Foundation

/// Widget-only preferences. Never writes the Live Activity preference record.
public struct WidgetAppearance: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        case minimal, lyricsFocus, lyricStack
        public var title: String {
            switch self {
            case .minimal: "Minimal"
            case .lyricsFocus: "Lyrics Focus"
            case .lyricStack: "Lyric Stack"
            }
        }
    }
    public enum Alignment: String, Codable, CaseIterable, Sendable { case leading, center, trailing }
    public enum Weight: String, Codable, CaseIterable, Sendable { case regular, medium, bold, heavy }
    public enum Background: String, Codable, CaseIterable, Sendable { case system, solid, gradient, album }
    public enum Context: String, Codable, CaseIterable, Sendable { case current, next, surrounding }

    public var preset: Preset
    public var font: LAStylePrefs.FontStyle = .rounded
    public var size: Double = 1
    public var weight: Weight = .bold
    public var alignment: Alignment = .leading
    public var context: Context = .current
    public var contextOpacity: Double = 0.45
    public var background: Background = .gradient
    public var accent: RGB = .init(r: 0.95, g: 0.35, b: 0.60)
    public var backgroundColor: RGB = .init(r: 0.08, g: 0.08, b: 0.13)
    public var showTitle: Bool = true
    public var showArtist: Bool = false
    public var roundedHighlight: Bool = true

    public init(preset: Preset = .minimal) {
        self.preset = preset
        switch preset {
        case .minimal:
            background = .system
            weight = .medium
        case .lyricsFocus:
            context = .next
            size = 1.1
        case .lyricStack:
            context = .surrounding
            alignment = .center
        }
    }

    public var normalized: Self {
        var result = self
        result.size = size.isFinite ? min(1.3, max(0.8, size)) : 1
        result.contextOpacity = contextOpacity.isFinite ? min(0.8, max(0.2, contextOpacity)) : 0.45
        result.accent = Self.clamp(accent)
        result.backgroundColor = Self.clamp(backgroundColor)
        return result
    }

    private static func clamp(_ color: RGB) -> RGB {
        func channel(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        return .init(r: channel(color.r), g: channel(color.g), b: channel(color.b))
    }
}

public struct WidgetDesign: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var appearance: WidgetAppearance
    public var revision: Int
    public var style: WidgetStylePrefs?
    public var resolvedStyle: WidgetStylePrefs { (style ?? WidgetStylePrefs(legacy: appearance)).normalized }

    public init(id: String = UUID().uuidString, name: String, appearance: WidgetAppearance, revision: Int = 1) {
        self.id = id
        self.name = name
        self.appearance = appearance.normalized
        self.revision = revision
    }
}

public enum WidgetDesignStore {
    private static let key = "widgetDesignCatalog.v2"
    private static let legacyKey = "widgetDesignCatalog.v1"
    private static func records(_ defaults: UserDefaults?) -> [Any] {
        for name in [key, legacyKey] {
            if let data = defaults?.data(forKey: name), data.count <= 2_000_000,
               let values = try? JSONSerialization.jsonObject(with: data) as? [Any] { return values }
        }
        return []
    }
    public static func load(defaults: UserDefaults? = UserDefaults(suiteName: SharedNowPlaying.appGroupID)) -> [WidgetDesign] {
        records(defaults).compactMap { raw in
            guard let record = raw as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: record),
                  var design = try? JSONDecoder().decode(WidgetDesign.self, from: data),
                  design.style?.schemaVersion ?? 2 <= 2 else { return nil }
            design.appearance = design.appearance.normalized
            return design
        }
    }
    /// Single app writer. Keep the v1 rollback copy and unsupported v2 records intact.
    @discardableResult
    public static func save(_ design: WidgetDesign, defaults: UserDefaults? = UserDefaults(suiteName: SharedNowPlaying.appGroupID)) throws -> Bool {
        guard let defaults else { throw CocoaError(.fileWriteUnknown) }
        var raw = records(defaults)
        var saved = design
        saved.appearance = design.appearance.normalized
        saved.style = design.style?.normalized
        saved.name = String(design.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if saved.name.isEmpty { saved.name = "My Design" }
        if let existing = load(defaults: defaults).first(where: { $0.id == saved.id }) {
            if existing.name == saved.name && existing.appearance == saved.appearance && existing.style == saved.style { return false }
            saved.revision = existing.revision + 1
        }
        let encoded = try JSONEncoder().encode(saved)
        guard try JSONDecoder().decode(WidgetDesign.self, from: encoded) == saved,
              let record = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw CocoaError(.fileWriteUnknown) }
        if let index = raw.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == saved.id }) { raw[index] = record }
        else { guard raw.count < 100 else { throw CocoaError(.fileWriteOutOfSpace) }; raw.append(record) }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        guard data.count <= 2_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        defaults.set(data, forKey: key)
        return true
    }
    public static func resolve(id: String?, fallback: WidgetAppearance.Preset) -> WidgetAppearance {
        load().first(where: { $0.id == id })?.appearance ?? WidgetAppearance(preset: fallback)
    }
    public static func resolveStyle(id: String?, fallback: WidgetAppearance.Preset) -> WidgetStylePrefs {
        load().first(where: { $0.id == id })?.resolvedStyle ?? WidgetStylePrefs(legacy: WidgetAppearance(preset: fallback))
    }
}

public enum CustomWidgetPaletteStore {
    private static let key = "customWidgetPalettes.v1"
    public static func load(defaults: UserDefaults? = UserDefaults(suiteName: SharedNowPlaying.appGroupID)) -> [WidgetPalette] {
        guard let data = defaults?.data(forKey: key), data.count <= 1_000_000,
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard let data = try? JSONSerialization.data(withJSONObject: record) else { return nil }
            return try? JSONDecoder().decode(WidgetPalette.self, from: data)
        }
    }
    public static func save(_ palette: WidgetPalette, defaults: UserDefaults? = UserDefaults(suiteName: SharedNowPlaying.appGroupID)) throws {
        guard let defaults else { throw CocoaError(.fileWriteUnknown) }
        var values = load(defaults: defaults)
        var saved = palette
        saved.name = String(saved.name.prefix(60)); saved.category = "Custom"
        if let index = values.firstIndex(where: { $0.id == palette.id }) {
            saved.revision = values[index].revision + 1; values[index] = saved
        } else { guard values.count < 100 else { throw CocoaError(.fileWriteOutOfSpace) }; values.append(saved) }
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }
}
