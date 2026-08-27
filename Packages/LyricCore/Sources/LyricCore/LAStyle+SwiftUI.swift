#if canImport(SwiftUI)
import SwiftUI

public extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

public extension LAStylePrefs.FontStyle {
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        default: return .default
        }
    }

    /// Point sizes mirroring the default Dynamic Type ladder, used to keep
    /// bundled custom fonts scaling like their TextStyle equivalents.
    func laFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                sizeOverride: CGFloat? = nil) -> Font {
        let base: (size: CGFloat, textStyle: Font.TextStyle) = switch style {
        case .largeTitle: (34, .largeTitle)
        case .title: (28, .title)
        case .title2: (22, .title2)
        case .title3: (20, .title3)
        case .headline: (17, .headline)
        case .body: (17, .body)
        case .callout: (16, .callout)
        case .subheadline: (15, .subheadline)
        case .footnote: (13, .footnote)
        case .caption: (12, .caption)
        case .caption2: (11, .caption2)
        default: (17, .body)
        }
        if let family = customFamily {
            return .custom(family, size: sizeOverride ?? base.size, relativeTo: base.textStyle)
                .weight(weight)
        }
        return .system(base.textStyle, design: design, weight: weight)
    }

    /// Fixed-size variant for hero text that ignores the type ladder.
    func laFont(fixedSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let family = customFamily {
            return .custom(family, size: fixedSize).weight(weight)
        }
        return .system(size: fixedSize, weight: weight, design: design)
    }
}

public extension LAStylePrefs.TextAlignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        }
    }

    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        }
    }
}
#endif
