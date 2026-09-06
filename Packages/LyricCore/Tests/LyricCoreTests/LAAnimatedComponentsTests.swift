#if canImport(SwiftUI)
import XCTest
@testable import LyricCore

@MainActor
final class LAAnimatedComponentsTests: XCTestCase {
    func testExportedScheduleMatchesScrollerAcrossAnImminentBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let document = LyricsDocument(
            track: .init(title: "Trace", artist: "Artist", duration: 30),
            lines: [.init(time: 0, text: "intro"), .init(time: 10, text: "verse"), .init(time: 20, text: "chorus")]
        )
        for offset in [-2.0, 0, 1.25] {
            for rate in [0.5, 1, 2] {
                let status = PlaybackStatus(state: .playing, position: 9.98 + offset, rate: rate, timestamp: now)
                let engine = SyncEngine(userOffset: offset)
                engine.update(document: document)
                engine.update(status: status)
                let batch = LyricBatchBuilder.make(
                    document: document, position: try XCTUnwrap(engine.currentPosition(at: now)),
                    offset: offset, now: now, rate: rate, trackID: "trace-track"
                )
                let schedule = batch.lines.map {
                    WidgetLyricSnapshot.ScheduledLine(date: Date(timeIntervalSince1970: $0.startEpoch), text: $0.text,
                                                      endDate: Date(timeIntervalSince1970: $0.endEpoch))
                }
                // Render after the imminent boundary, without another app update.
                let renderDate = now.addingTimeInterval(0.04 / rate)
                let resolved = LAScheduledLyricText.resolveLines(
                    currentLine: try XCTUnwrap(engine.currentLine(at: now)?.text), nextLine: "verse",
                    scheduledLines: schedule, karaokeStartDate: nil, karaokeEndDate: nil,
                    playbackEndDate: nil, at: renderDate
                )
                XCTAssertEqual(resolved.current, engine.currentLine(at: renderDate)?.text,
                               "offset=\(offset), rate=\(rate)")
            }
        }
    }

    func testTrackEndClearsTheFinalScheduledLyric() {
        let start = Date(timeIntervalSince1970: 1_700_000_010)
        let end = Date(timeIntervalSince1970: 1_700_000_020)
        let lines = [
            WidgetLyricSnapshot.ScheduledLine(
                date: start,
                text: "final line",
                endDate: end
            )
        ]

        let resolved = LAScheduledLyricText.resolveLines(
            currentLine: "final line",
            nextLine: nil,
            scheduledLines: lines,
            karaokeStartDate: start,
            karaokeEndDate: end,
            playbackEndDate: end,
            at: end.addingTimeInterval(0.001)
        )

        XCTAssertEqual(resolved.current, "♪")
        XCTAssertNil(resolved.next)
        XCTAssertNil(resolved.startDate)
        XCTAssertNil(resolved.endDate)
    }

    func testScheduleStillShowsTheFinalLyricBeforeTrackEnd() {
        let start = Date(timeIntervalSince1970: 1_700_000_010)
        let end = Date(timeIntervalSince1970: 1_700_000_020)
        let lines = [
            WidgetLyricSnapshot.ScheduledLine(
                date: start,
                text: "final line",
                endDate: end
            )
        ]

        let resolved = LAScheduledLyricText.resolveLines(
            currentLine: "♪",
            nextLine: "final line",
            scheduledLines: lines,
            karaokeStartDate: nil,
            karaokeEndDate: nil,
            playbackEndDate: end,
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(resolved.current, "final line")
        XCTAssertNil(resolved.next)
        XCTAssertEqual(resolved.startDate, start)
        XCTAssertEqual(resolved.endDate, end)
    }

    func testOnlyKnownBoundariesAreRequestedWithoutSyntheticRecoveryTicks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(10)
        let end = now.addingTimeInterval(20)
        XCTAssertEqual(LAScheduledLyricText.makeRefreshDates(
            now: now, scheduledLines: [.init(date: start, text: "line", endDate: end)],
            playbackEndDate: now.addingTimeInterval(600)
        ), [now, start, end, now.addingTimeInterval(600)])
    }

    func testExhaustedBatchDoesNotHoldItsLastLineUntilTrackEnd() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = LAScheduledLyricText.resolveLines(
            currentLine: "intro", nextLine: "verse",
            scheduledLines: [.init(date: now.addingTimeInterval(10), text: "verse",
                                   endDate: now.addingTimeInterval(20))],
            karaokeStartDate: now, karaokeEndDate: now.addingTimeInterval(10),
            playbackEndDate: now.addingTimeInterval(240), at: now.addingTimeInterval(21)
        )
        XCTAssertEqual(resolved.current, "♪")
        XCTAssertNil(resolved.next)
    }
}
#endif
