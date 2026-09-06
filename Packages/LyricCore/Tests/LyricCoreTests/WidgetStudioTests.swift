import XCTest
@testable import LyricCore

final class WidgetStudioTests: XCTestCase {
    func testPaletteCatalogIsCompleteUniqueAndReadable() {
        let palettes = WidgetPaletteCatalog.all
        XCTAssertEqual(palettes.count, 50)
        XCTAssertEqual(Set(palettes.map(\.id)).count, 50)
        for palette in palettes {
            XCTAssertEqual(Set(palette.colors.keys), Set(WidgetPalette.roles), palette.id)
            for color in palette.colors.values {
                XCTAssertEqual(color.hex.count, 6)
                XCTAssertNotNil(UInt32(color.hex, radix: 16))
            }
            for bg in ["background", "secondaryBackground", "tertiaryBackground"] {
                XCTAssertGreaterThanOrEqual(contrast(palette["primaryLyric"].rgb, palette[bg].rgb), 4.5, "\(palette.id): \(bg)")
            }
        }
    }

    func testLegacyCatalogMigrationPreservesSelectionsAndRollback() throws {
        try withDefaults { defaults in
            var first = WidgetDesign(id: "existing-widget-id", name: "Old Style", appearance: .init(preset: .lyricStack), revision: 7)
            first.appearance.font = .playfair; first.appearance.contextOpacity = 0.7
            let legacy = try JSONEncoder().encode([first])
            defaults.set(legacy, forKey: "widgetDesignCatalog.v1")
            let loaded = try XCTUnwrap(WidgetDesignStore.load(defaults: defaults).first)
            XCTAssertEqual(loaded.id, first.id)
            XCTAssertEqual(loaded.resolvedStyle.typography.fontID, "playfair")
            XCTAssertEqual(loaded.resolvedStyle.typography.previousOpacity, 0.7)
            XCTAssertTrue(loaded.resolvedStyle.details.previous)
            var migrated = loaded; migrated.style = loaded.resolvedStyle
            XCTAssertTrue(try WidgetDesignStore.save(migrated, defaults: defaults))
            XCTAssertEqual(WidgetDesignStore.load(defaults: defaults).first?.revision, 8)
            XCTAssertFalse(try WidgetDesignStore.save(migrated, defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: "widgetDesignCatalog.v1"), legacy)
            XCTAssertNil(defaults.data(forKey: "laStylePrefs"))
            XCTAssertNil(defaults.data(forKey: "sharedPlaybackSnapshot.v2"))
        }
    }

    func testUnreadableRecordIsRetainedWhenAnotherDesignIsSaved() throws {
        try withDefaults { defaults in
            let bad: [String: Any] = ["id": "future", "unknown": ["keep": true]]
            defaults.set(try JSONSerialization.data(withJSONObject: [bad]), forKey: "widgetDesignCatalog.v2")
            let good = WidgetDesign(name: "Good", appearance: .init())
            XCTAssertTrue(try WidgetDesignStore.save(good, defaults: defaults))
            XCTAssertEqual(WidgetDesignStore.load(defaults: defaults).map(\.id), [good.id])
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "widgetDesignCatalog.v2"))) as? [[String: Any]])
            XCTAssertEqual(raw.count, 2)
            XCTAssertEqual(raw.first?["id"] as? String, "future")
        }
    }

    func testDefaultDecodingAndUnknownCatalogIDsDoNotErasePreferences() throws {
        let json = Data(#"{"templateID":"future","typography":{"fontID":"future","scale":1.4},"background":{"fill":"future"}}"#.utf8)
        let style = try JSONDecoder().decode(WidgetStylePrefs.self, from: json)
        XCTAssertEqual(style.typography.scale, 1.4)
        XCTAssertEqual(style.typography.maxLines, 4)
        XCTAssertEqual(style.background.fill, .linear)
        let resolved = WidgetStyleResolver.resolve(style, album: nil)
        XCTAssertEqual(resolved.templateID, "minimal")
        XCTAssertEqual(resolved.typography.fontID, "rounded")
        XCTAssertEqual(style.templateID, "future")
        XCTAssertEqual(style.typography.fontID, "future")
    }

    func testAppearanceDoesNotChangeScheduleAndFamiliesAdaptIndependently() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetLyricSnapshot(trackTitle: "Song", artistName: "Artist", currentLine: "Start", isPlaying: true,
            updatedAt: now, scheduledLines: (0..<37).map { .init(date: now.addingTimeInterval(Double($0) * 10), text: "Line \($0)") })
        let dates = snapshot.lyricTimelineDates(after: now)
        for template in WidgetTemplate.all {
            let style = WidgetStylePrefs.preset(template: template.id, paletteID: "vaporwave")
            let small = WidgetStyleResolver.resolve(style, album: nil, compact: true)
            XCTAssertFalse(small.details.previous)
            XCTAssertEqual(snapshot.lyricTimelineDates(after: now), dates)
            XCTAssertEqual(WidgetPresentation(snapshot: snapshot, at: now.addingTimeInterval(360)).current, "Line 36")
        }
        XCTAssertEqual(WidgetTemplate.all.count, 15)
    }

    func testNativeProgressUsesUnixAnchorsAndPausedProgressStaysFrozen() throws {
        let epoch = 1_800_000_000.0
        let playing = WidgetLyricSnapshot(trackTitle: "Song", artistName: "Artist", trackDuration: 240,
            playbackEndEpoch: epoch + 240, playbackAnchorEpoch: epoch,
            albumName: "Album", currentLine: "Now", isPlaying: true)
        let presentation = WidgetPresentation(snapshot: playing, at: Date(timeIntervalSince1970: epoch + 120))
        XCTAssertEqual(presentation.elapsedSeconds, 120)
        XCTAssertEqual(presentation.progressInterval?.lowerBound.timeIntervalSince1970, epoch)
        let paused = WidgetLyricSnapshot(trackTitle: "Song", artistName: "Artist", trackDuration: 240,
            albumName: "Album", frozenPositionSeconds: 120, currentLine: "Now", isPlaying: false)
        for second in [0.0, 60, 120, 600] {
            let value = WidgetPresentation(snapshot: paused, at: Date(timeIntervalSince1970: epoch + second))
            XCTAssertNil(value.progressInterval)
            XCTAssertEqual(value.frozenProgress, 0.5)
        }
        try withDefaults { defaults in
            SharedPlaybackSnapshotV2Store.saveWidget(paused, defaults: defaults)
            let v2 = try XCTUnwrap(SharedPlaybackSnapshotV2Store.load(defaults: defaults))
            XCTAssertEqual(v2.albumName, "Album")
            XCTAssertEqual(v2.frozenPositionSeconds, 120)
        }
    }

    func testCustomPaletteRoundTripAndDesignIsolation() throws {
        try withDefaults { defaults in
            var palette = WidgetPaletteCatalog.find("vaporwave")
            palette.id = "custom-a"; palette.name = "Mine"; palette.colors["artist"] = .init(hex: "AAEEFF")
            try CustomWidgetPaletteStore.save(palette, defaults: defaults)
            XCTAssertEqual(CustomWidgetPaletteStore.load(defaults: defaults).first?.colors["artist"]?.hex, "AAEEFF")
            var a = WidgetDesign(name: "A", appearance: .init()); a.style = .preset(template: "stack"); a.style?.palette = palette
            var b = a; b.id = "independent"; b.name = "B"
            try WidgetDesignStore.save(a, defaults: defaults); try WidgetDesignStore.save(b, defaults: defaults)
            a.style?.typography.scale = 1.5; try WidgetDesignStore.save(a, defaults: defaults)
            XCTAssertEqual(WidgetDesignStore.load(defaults: defaults).first(where: { $0.id == b.id })?.resolvedStyle.typography.scale, 1)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "WidgetStudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        func luminance(_ c: RGB) -> Double {
            func f(_ n: Double) -> Double { n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
            return f(c.r) * 0.2126 + f(c.g) * 0.7152 + f(c.b) * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
