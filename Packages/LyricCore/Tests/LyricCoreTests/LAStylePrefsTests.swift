import XCTest
@testable import LyricCore

final class LAStylePrefsTests: XCTestCase {
    func testNewDefaultsFavorReadableLayout() {
        let prefs = LAStylePrefs.default

        XCTAssertEqual(prefs.layout, .player)
        XCTAssertEqual(prefs.artworkStyle, .vinyl)
        XCTAssertEqual(prefs.textAlignment, .leading)
        XCTAssertEqual(prefs.lyricScale, .balanced)
        XCTAssertTrue(prefs.showTrackInfo)
        XCTAssertTrue(prefs.showControls)
        XCTAssertTrue(prefs.showNextLine)
        XCTAssertTrue(prefs.showProgressBar)
    }

    func testLegacyPreferencesDecodeWithNewDefaults() throws {
        let data = Data(#"{"theme":"ocean","fontStyle":"serif","animationsEnabled":false}"#.utf8)

        let prefs = try JSONDecoder().decode(LAStylePrefs.self, from: data)

        XCTAssertEqual(prefs.theme, .ocean)
        XCTAssertEqual(prefs.fontStyle, .serif)
        XCTAssertEqual(prefs.layout, .player)
        XCTAssertEqual(prefs.artworkStyle, .vinyl)
        XCTAssertEqual(prefs.textAlignment, .leading)
        XCTAssertEqual(prefs.lyricScale, .balanced)
        XCTAssertTrue(prefs.showTrackInfo)
        XCTAssertTrue(prefs.showControls)
        XCTAssertTrue(prefs.showNextLine)
        XCTAssertTrue(prefs.showProgressBar)
        XCTAssertFalse(prefs.animationsEnabled)
    }

    func testScalePresetsHaveSafeHeights() {
        XCTAssertEqual(LAStylePrefs.LyricScale.compact.maximumLines, 1)
        XCTAssertEqual(LAStylePrefs.LyricScale.balanced.maximumLines, 2)
        XCTAssertLessThan(LAStylePrefs.LyricScale.large.minimumScale, 0.4)
        XCTAssertGreaterThan(LAStylePrefs.LyricScale.large.totalHeight,
                             LAStylePrefs.LyricScale.balanced.totalHeight)
    }

    func testCustomizationRoundTrips() throws {
        let original = LAStylePrefs(
            theme: .album,
            layout: .lyricsFocus,
            artworkStyle: .square,
            textAlignment: .center,
            fontStyle: .grotesk,
            lyricScale: .large,
            showTrackInfo: false,
            showControls: false,
            showNextLine: false,
            showProgressBar: false,
            animationsEnabled: false,
            karaokeEnabled: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LAStylePrefs.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
