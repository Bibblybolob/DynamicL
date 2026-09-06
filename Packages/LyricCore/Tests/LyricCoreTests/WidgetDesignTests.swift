import XCTest
@testable import LyricCore

final class WidgetDesignTests: XCTestCase {
    func testIndependentDesignsNoOpSaveAndDuplicate() throws {
        let suite = "WidgetDesignTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var first = WidgetDesign(name: "Reading", appearance: .init(preset: .lyricStack))
        let second = WidgetDesign(name: "Quiet", appearance: .init(preset: .minimal))
        XCTAssertTrue(try WidgetDesignStore.save(first, defaults: defaults))
        XCTAssertTrue(try WidgetDesignStore.save(second, defaults: defaults))
        XCTAssertFalse(try WidgetDesignStore.save(first, defaults: defaults))
        first.appearance.size = 1.2
        XCTAssertTrue(try WidgetDesignStore.save(first, defaults: defaults))
        let saved = WidgetDesignStore.load(defaults: defaults)
        XCTAssertEqual(saved.first?.revision, 2)
        XCTAssertEqual(saved.last, second)
        first.id = UUID().uuidString
        XCTAssertTrue(try WidgetDesignStore.save(first, defaults: defaults))
        XCTAssertEqual(WidgetDesignStore.load(defaults: defaults).count, 3)
        XCTAssertNil(defaults.data(forKey: "laStylePrefs"))
    }

    func testAppearanceClampsUntrustedStoredValues() {
        var appearance = WidgetAppearance()
        appearance.size = .infinity
        appearance.contextOpacity = -12
        appearance.accent = .init(r: -1, g: 3, b: .nan)
        XCTAssertEqual(appearance.normalized.size, 1)
        XCTAssertEqual(appearance.normalized.contextOpacity, 0.2)
        XCTAssertEqual(appearance.normalized.accent, .init(r: 0, g: 1, b: 0))
    }

    func testSixMinutesOfContextWithoutNewPublication() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = (0..<37).map { index in
            WidgetLyricSnapshot.ScheduledLine(date: now.addingTimeInterval(Double(index) * 10),
                text: "Line \(index)", endDate: now.addingTimeInterval(Double(index + 1) * 10))
        }
        let original = WidgetLyricSnapshot(trackTitle: "Song", artistName: "Artist",
            trackID: "a", revision: 10, playbackEndEpoch: now.addingTimeInterval(370).timeIntervalSince1970,
            previousLine: "Earlier", nextLine: "Line 1", currentLine: "Line 0", isPlaying: true,
            updatedAt: now, scheduledLines: lines)
        let snapshot = try JSONDecoder().decode(WidgetLyricSnapshot.self, from: JSONEncoder().encode(original))
        for second in 0...360 {
            let date = now.addingTimeInterval(Double(second))
            let presentation = WidgetPresentation(snapshot: snapshot, at: date)
            let index = second / 10
            XCTAssertEqual(presentation.current, snapshot.resolvedCurrentLine(at: date))
            XCTAssertEqual(presentation.previous, index == 0 ? "Earlier" : "Line \(index - 1)")
            XCTAssertEqual(presentation.next, index == 36 ? nil : "Line \(index + 1)")
        }
        XCTAssertEqual(snapshot.lyricTimelineDates(after: now), original.lyricTimelineDates(after: now))
        let ended = WidgetPresentation(snapshot: snapshot, at: now.addingTimeInterval(370))
        XCTAssertEqual(ended.current, "♪")
        XCTAssertNil(ended.previous)
        XCTAssertNil(ended.next)
    }

    func testPauseSeekTrackChangeAndOlderRevision() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let paused = WidgetLyricSnapshot(trackTitle: "A", artistName: "Artist", trackID: "a",
            revision: 10, previousLine: "Before", nextLine: "After", currentLine: "Paused",
            isPlaying: false, updatedAt: now)
        XCTAssertEqual(WidgetPresentation(snapshot: paused, at: now.addingTimeInterval(120)).current, "Paused")
        XCTAssertEqual(WidgetPresentation(snapshot: paused, at: now.addingTimeInterval(120)).next, "After")
        XCTAssertTrue(paused.lyricTimelineDates(after: now).isEmpty)
        let seek = WidgetLyricSnapshot(trackTitle: "A", artistName: "Artist", trackID: "a",
            revision: 11, previousLine: "New before", nextLine: "New after", currentLine: "Seeked",
            isPlaying: true, updatedAt: now, scheduledLines: [
                .init(date: now, text: "Seeked", endDate: now.addingTimeInterval(10)),
                .init(date: now.addingTimeInterval(10), text: "New after", endDate: now.addingTimeInterval(20))
            ])
        XCTAssertEqual(WidgetPresentation(snapshot: seek, at: now).previous, "New before")
        XCTAssertEqual(WidgetPresentation(snapshot: seek, at: now.addingTimeInterval(12)).current, "New after")
        XCTAssertTrue(seek.isNewer(than: paused))
        var newTrack = seek
        newTrack.trackID = "b"
        newTrack.revision = 12
        XCTAssertTrue(newTrack.isNewer(than: seek))
        XCTAssertFalse(seek.isNewer(than: newTrack))
    }

    func testLegacyDecodeAndV2ContextRoundTrip() throws {
        let original = WidgetLyricSnapshot(trackTitle: "Song", artistName: "Artist",
            previousLine: "Before", nextLine: "After", currentLine: "Now", isPlaying: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "previousLine")
        json.removeValue(forKey: "nextLine")
        let legacy = try JSONDecoder().decode(WidgetLyricSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.previousLine)
        XCTAssertNil(legacy.nextLine)
        XCTAssertEqual(legacy.currentLine, "Now")
        let suite = "WidgetV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SharedPlaybackSnapshotV2Store.saveWidget(original, defaults: defaults)
        let v2 = try XCTUnwrap(SharedPlaybackSnapshotV2Store.load(defaults: defaults))
        XCTAssertEqual(v2.previousLine, "Before")
        XCTAssertEqual(v2.nextLine, "After")
    }
}
