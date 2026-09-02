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

    func testRecoveryDatesWakeAfterBoundariesWereMissedOffscreen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = [
            WidgetLyricSnapshot.ScheduledLine(
                date: now.addingTimeInterval(10),
                text: "first",
                endDate: now.addingTimeInterval(20)
            ),
            WidgetLyricSnapshot.ScheduledLine(
                date: now.addingTimeInterval(20),
                text: "second",
                endDate: now.addingTimeInterval(30)
            )
        ]

        let dates = LAScheduledLyricText.makeRefreshDates(
            now: now,
            scheduledLines: lines,
            playbackEndDate: now.addingTimeInterval(180)
        )

        let becameVisible = now.addingTimeInterval(23)
        let nextWake = dates.first { $0 > becameVisible }
        XCTAssertNotNil(nextWake)
        XCTAssertLessThanOrEqual(
            nextWake?.timeIntervalSince(becameVisible) ?? .infinity,
            5
        )
        XCTAssertTrue(dates.contains(now.addingTimeInterval(10)))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(20)))
    }

    func testRecoveryDatesStayInsideTheBoundedWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = LAScheduledLyricText.makeRefreshDates(
            now: now,
            scheduledLines: [],
            playbackEndDate: now.addingTimeInterval(600)
        )

        XCTAssertTrue(dates.contains(now.addingTimeInterval(600)))
        let recoveryDates = dates.filter { $0 < now.addingTimeInterval(600) }
        XCTAssertEqual(recoveryDates.last, now.addingTimeInterval(135))
        XCTAssertLessThanOrEqual(recoveryDates.count, 28)
    }
}
#endif
