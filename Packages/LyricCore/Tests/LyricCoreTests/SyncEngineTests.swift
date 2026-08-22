import XCTest
@testable import LyricCore

final class SyncEngineTests: XCTestCase {
    private let document = LyricsDocument(
        track: TrackSignature(title: "T", artist: "A"),
        lines: [
            LyricLine(time: 0, text: "intro"),
            LyricLine(time: 10, text: "verse"),
            LyricLine(time: 20, text: "chorus"),
        ]
    )

    func testNoStatusReturnsNil() {
        let engine = SyncEngine()
        engine.update(document: document)
        XCTAssertNil(engine.currentIndex())
        XCTAssertNil(engine.currentPosition())
    }

    func testPausedHoldsPosition() {
        let engine = SyncEngine()
        engine.update(document: document)
        engine.update(status: PlaybackStatus(state: .paused, position: 12))

        let later = Date.now.addingTimeInterval(60)
        XCTAssertEqual(engine.currentPosition(at: later), 12)
        XCTAssertEqual(engine.currentLine(at: later)?.text, "verse")
    }

    func testPlayingInterpolatesPosition() {
        let engine = SyncEngine()
        engine.update(document: document)
        let start = Date(timeIntervalSince1970: 0)
        engine.update(status: PlaybackStatus(state: .playing, position: 8, rate: 1, timestamp: start))

        let afterFiveSeconds = start.addingTimeInterval(5)
        XCTAssertEqual(engine.currentPosition(at: afterFiveSeconds), 13)
        XCTAssertEqual(engine.currentLine(at: afterFiveSeconds)?.text, "verse")
    }

    func testSeekReanchors() {
        let engine = SyncEngine()
        engine.update(document: document)
        let t0 = Date(timeIntervalSince1970: 0)
        engine.update(status: PlaybackStatus(state: .playing, position: 1, rate: 1, timestamp: t0))
        engine.update(status: PlaybackStatus(state: .playing, position: 21, rate: 1, timestamp: t0))

        XCTAssertEqual(engine.currentLine(at: t0.addingTimeInterval(2))?.text, "chorus")
    }

    func testUserOffsetDelaysLookup() {
        let engine = SyncEngine()
        engine.update(document: document)
        engine.update(status: PlaybackStatus(state: .paused, position: 11))
        XCTAssertEqual(engine.currentLine()?.text, "verse")

        engine.userOffset = 2
        XCTAssertEqual(engine.currentLine()?.text, "intro")

        engine.update(status: PlaybackStatus(state: .paused, position: 19))
        engine.userOffset = -2
        XCTAssertEqual(engine.currentLine()?.text, "chorus")
    }
}
