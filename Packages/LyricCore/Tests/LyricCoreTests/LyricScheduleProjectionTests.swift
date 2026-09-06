import XCTest
@testable import LyricCore

final class LyricScheduleProjectionTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private var document: LyricsDocument {
        .init(track: .init(title: "Six minutes", artist: "Artist", duration: 400),
              lines: (0..<80).map { .init(time: Double($0 * 5), text: "line \($0)") })
    }

    private func snapshot(_ document: LyricsDocument, status: PlaybackStatus,
                          at date: Date, offset: Double = 0) -> WidgetLyricSnapshot {
        let projection = LyricScheduleProjection(
            document: document, status: status, offset: offset, at: date,
            horizon: 14_400, maxLines: 512
        )
        return .init(trackTitle: document.track.title, artistName: document.track.artist,
                     trackID: document.track.title, revision: 1,
                     playbackEndEpoch: PlaybackAnchors(status: status, duration: document.track.duration)
                        .endDate?.timeIntervalSince1970,
                     currentLine: projection.currentLine, isPlaying: status.state == .playing,
                     updatedAt: date, scheduledLines: projection.widgetLines)
    }

    func testSixMinutesWithoutPublicationOrNetworkMatchesScrollerAndWidgetTimeline() throws {
        let status = PlaybackStatus(state: .playing, position: 2, timestamp: anchor)
        let saved = snapshot(document, status: status, at: anchor)
        // A separate consumer, using only the encoded app-group contract.
        let loaded = try JSONDecoder().decode(WidgetLyricSnapshot.self, from: JSONEncoder().encode(saved))
        let engine = SyncEngine()
        engine.update(document: document)
        engine.update(status: status)
        let timeline = [anchor] + loaded.lyricTimelineDates(after: anchor)
        for second in 0...360 {
            let date = anchor.addingTimeInterval(Double(second))
            let entryDate = try XCTUnwrap(timeline.last { $0 <= date })
            XCTAssertEqual(loaded.resolvedCurrentLine(at: date), engine.currentLine(at: date)?.text)
            XCTAssertEqual(loaded.resolvedCurrentLine(at: entryDate), engine.currentLine(at: date)?.text)
        }
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertEqual(loaded.updatedAt, anchor)
    }

    func testDelayedProjectionUsesAnchorRatherThanCachedDisplayPosition() {
        for rate in [0.5, 1, 2] {
            for offset in [-1.25, 0, 2] {
                let status = PlaybackStatus(state: .playing, position: 9.98, rate: rate, timestamp: anchor)
                let publishedAt = anchor.addingTimeInterval(2.123)
                let saved = snapshot(document, status: status, at: publishedAt, offset: offset)
                let engine = SyncEngine(userOffset: offset)
                engine.update(document: document)
                engine.update(status: status)
                for delta in [0.0, 0.1, 6, 40, 120] {
                    let date = publishedAt.addingTimeInterval(delta)
                    XCTAssertEqual(saved.resolvedCurrentLine(at: date), engine.currentLine(at: date)?.text)
                }
            }
        }
    }

    func testPauseAndResumeReplaceTheOldSchedule() {
        let pausedAt = anchor.addingTimeInterval(100)
        let paused = snapshot(document, status: .init(state: .paused, position: 102, timestamp: pausedAt), at: pausedAt)
        XCTAssertTrue(paused.scheduledLines.isEmpty)
        XCTAssertTrue(paused.lyricTimelineDates(after: pausedAt).isEmpty)
        XCTAssertEqual(paused.resolvedCurrentLine(at: pausedAt.addingTimeInterval(180)), "line 20")
        let resumedAt = pausedAt.addingTimeInterval(180)
        let resumed = snapshot(document, status: .init(state: .playing, position: 102, timestamp: resumedAt), at: resumedAt)
        XCTAssertEqual(resumed.resolvedCurrentLine(at: resumedAt.addingTimeInterval(4)), "line 21")
        XCTAssertEqual(resumed.scheduledLines.first?.date, resumedAt.addingTimeInterval(-2))
    }

    func testBackwardSeekEvenWithinSameLineReanchorsFutureBoundaries() {
        let original = snapshot(document, status: .init(state: .playing, position: 101, timestamp: anchor), at: anchor)
        let seekAt = anchor.addingTimeInterval(2)
        let corrected = snapshot(document, status: .init(state: .playing, position: 100.5, timestamp: seekAt), at: seekAt)
        XCTAssertEqual(original.currentLine, corrected.currentLine)
        let later = anchor.addingTimeInterval(5)
        XCTAssertEqual(original.resolvedCurrentLine(at: later), "line 21")
        XCTAssertEqual(corrected.resolvedCurrentLine(at: later), "line 20")
        XCTAssertEqual(corrected.resolvedCurrentLine(at: seekAt.addingTimeInterval(5)), "line 21")
    }

    func testTrackAndCorrectedLyricsReplaceAllOldIntervals() {
        var newDocument = document
        newDocument.track.title = "New track"
        newDocument.lines[2].text = "corrected"
        let saved = snapshot(newDocument, status: .init(state: .playing, position: 0, timestamp: anchor), at: anchor)
        XCTAssertEqual(saved.trackID, "New track")
        XCTAssertEqual(saved.resolvedCurrentLine(at: anchor.addingTimeInterval(11)), "corrected")
    }

    func testBoundedScheduleAndTrackEndExpireWithoutNewSnapshot() {
        let projection = LyricScheduleProjection(
            document: document, status: .init(state: .playing, position: 0, timestamp: anchor),
            offset: 0, at: anchor, horizon: 20, maxLines: 2
        )
        let saved = WidgetLyricSnapshot(trackTitle: "Track", artistName: "Artist", currentLine: projection.currentLine,
                                       isPlaying: true, updatedAt: anchor, scheduledLines: projection.widgetLines)
        XCTAssertEqual(saved.resolvedCurrentLine(at: anchor.addingTimeInterval(11)), "line 2")
        XCTAssertEqual(saved.resolvedCurrentLine(at: anchor.addingTimeInterval(16)), "♪")
        XCTAssertTrue(saved.lyricTimelineDates(after: anchor).contains(anchor.addingTimeInterval(15)))
        let full = snapshot(document, status: .init(state: .playing, position: 0, timestamp: anchor), at: anchor)
        XCTAssertEqual(full.resolvedCurrentLine(at: anchor.addingTimeInterval(401)), "♪")
    }
}
