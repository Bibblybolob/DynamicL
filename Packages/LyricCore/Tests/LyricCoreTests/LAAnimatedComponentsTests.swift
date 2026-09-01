#if canImport(SwiftUI)
import XCTest
@testable import LyricCore

@MainActor
final class LAAnimatedComponentsTests: XCTestCase {
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
}
#endif
