import XCTest
@testable import LyricCore

final class PlaybackStateReducerTests: XCTestCase {
    func testPartialSameTrackDoesNotRemoveArtworkOrMetadata() {
        var reducer = PlaybackStateReducer()
        let first = reducer.reduce(PlaybackObservation(
            trackID: "track-1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            durationMs: 200_000,
            artworkURL: "https://image/1.jpg",
            isPlaying: true,
            progressMs: 10_000,
            eventTimestampMs: 100,
            receivedAt: Date(timeIntervalSince1970: 10)
        ))
        XCTAssertEqual(first.kind, .trackChanged)

        let partial = reducer.reduce(PlaybackObservation(
            trackID: "track-1",
            isPlaying: true,
            progressMs: 12_000,
            eventTimestampMs: 101,
            receivedAt: Date(timeIntervalSince1970: 12)
        ))
        XCTAssertEqual(partial.snapshot?.track?.title, "Song")
        XCTAssertEqual(partial.snapshot?.track?.artworkURL, "https://image/1.jpg")
        XCTAssertEqual(partial.snapshot?.track?.durationMs, 200_000)
    }

    func testOlderSpotifyEventCannotRestorePreviousTrack() {
        var reducer = PlaybackStateReducer()
        _ = reducer.reduce(PlaybackObservation(
            trackID: "new",
            title: "New",
            artist: "Artist",
            isPlaying: true,
            progressMs: 1_000,
            eventTimestampMs: 200,
            receivedAt: Date(timeIntervalSince1970: 20)
        ))
        let stale = reducer.reduce(PlaybackObservation(
            trackID: "old",
            title: "Old",
            artist: "Artist",
            isPlaying: true,
            progressMs: 90_000,
            eventTimestampMs: 199,
            receivedAt: Date(timeIntervalSince1970: 21)
        ))
        XCTAssertEqual(stale.kind, .ignoredStale)
        XCTAssertEqual(stale.snapshot?.track?.id, "new")
    }

    func testLargePositionCorrectionIsASeek() {
        var reducer = PlaybackStateReducer()
        _ = reducer.reduce(PlaybackObservation(
            trackID: "track-1",
            title: "Song",
            artist: "Artist",
            durationMs: 200_000,
            isPlaying: true,
            progressMs: 1_000,
            eventTimestampMs: 1,
            receivedAt: Date(timeIntervalSince1970: 1)
        ))
        let result = reducer.reduce(PlaybackObservation(
            trackID: "track-1",
            isPlaying: true,
            progressMs: 20_000,
            eventTimestampMs: 2,
            receivedAt: Date(timeIntervalSince1970: 2)
        ))
        XCTAssertEqual(result.kind, .seek)
        XCTAssertGreaterThan(result.positionDeltaMs, 750)
    }

    func testConfirmedStopClearsTrack() {
        var reducer = PlaybackStateReducer()
        _ = reducer.reduce(PlaybackObservation(
            trackID: "track-1",
            title: "Song",
            artist: "Artist",
            isPlaying: true,
            progressMs: 1_000,
            eventTimestampMs: 1
        ))
        let result = reducer.reduce(PlaybackObservation(itemPresent: false, eventTimestampMs: 2))
        XCTAssertEqual(result.kind, .stopped)
        XCTAssertNil(result.snapshot?.track)
        XCTAssertEqual(result.snapshot?.phase, UnifiedPlaybackPhase.none)
    }
}
