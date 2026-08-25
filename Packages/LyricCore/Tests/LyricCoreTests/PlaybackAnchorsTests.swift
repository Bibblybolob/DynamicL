import XCTest
@testable import LyricCore

final class PlaybackAnchorsTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_000_000)

    func testPlayingAnchorsMapPositionToWallClock() {
        // Playing at 30s observed at t → bar spans t-30 ... t-30+200
        let a = PlaybackAnchors(
            status: PlaybackStatus(state: .playing, position: 30, rate: 1, timestamp: t),
            duration: 200)
        XCTAssertEqual(a.startDate.timeIntervalSince1970, 999_970, accuracy: 0.01)
        XCTAssertEqual(a.endDate?.timeIntervalSince1970 ?? -1, 1_000_170, accuracy: 0.01)
        XCTAssertNil(a.frozenFraction)
    }

    func testRateScalesTheMapping() {
        // rate 2 → wall clock runs twice as fast through the song.
        let a = PlaybackAnchors(
            status: PlaybackStatus(state: .playing, position: 30, rate: 2, timestamp: t),
            duration: 200)
        XCTAssertEqual(a.startDate.timeIntervalSince1970, 999_985, accuracy: 0.01)
        XCTAssertEqual(a.endDate?.timeIntervalSince1970 ?? -1, 1_000_085, accuracy: 0.01)
    }

    func testPausedAnchorsFreezeAtFraction() {
        let a = PlaybackAnchors(
            status: PlaybackStatus(state: .paused, position: 60, rate: 1, timestamp: t),
            duration: 200)
        XCTAssertEqual(a.frozenFraction ?? -1, 0.3, accuracy: 0.001)
        XCTAssertNil(a.endDate)
    }

    func testMissingDurationFallsBackToPositionPlusOne() {
        let a = PlaybackAnchors(
            status: PlaybackStatus(state: .playing, position: 30, rate: 1, timestamp: t),
            duration: nil)
        XCTAssertEqual(a.endDate?.timeIntervalSince(a.startDate) ?? -1, 31, accuracy: 0.01)
    }
}
