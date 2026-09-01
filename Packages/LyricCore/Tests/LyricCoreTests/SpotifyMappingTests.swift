import XCTest
@testable import LyricCore

final class SpotifyMappingTests: XCTestCase {
    func testDecodesPlayerState() throws {
        let json = """
        {
          "device": {"id": "abc", "is_active": true, "name": "iPhone"},
          "repeat_state": "off",
          "shuffle_state": false,
          "timestamp": 1800000000123,
          "progress_ms": 45000,
          "is_playing": true,
          "item": {
            "id": "track-123",
            "album": {"album_type": "album", "name": "Rumours"},
            "artists": [{"name": "Fleetwood Mac"}],
            "duration_ms": 271000,
            "name": "The Chain"
          }
        }
        """
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))

        XCTAssertEqual(state.signature?.title, "The Chain")
        XCTAssertEqual(state.item?.id, "track-123")
        XCTAssertEqual(state.signature?.artist, "Fleetwood Mac")
        XCTAssertEqual(state.signature?.album, "Rumours")
        XCTAssertEqual(state.signature?.duration ?? 0, 271.0, accuracy: 0.001)
        XCTAssertEqual(state.timestampMs, 1_800_000_000_123)
        XCTAssertEqual(state.playbackChangeDate?.timeIntervalSince1970 ?? 0, 1_800_000_000.123, accuracy: 0.001)

        let status = state.status
        XCTAssertEqual(status.state, .playing)
        XCTAssertEqual(status.position, 45.0, accuracy: 0.001)
    }

    func testNoItemStateMapsToStopped() throws {
        let json = """
        {"progress_ms": 10000, "is_playing": false, "item": null}
        """
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))
        XCTAssertEqual(state.status.state, .stopped)
        XCTAssertNil(state.signature)
    }

    func testNaturalCompletionMapsToStopped() throws {
        let json = """
        {
          "progress_ms": 179500,
          "is_playing": false,
          "item": {
            "id": "track-1",
            "name": "Finished",
            "duration_ms": 180000,
            "artists": [{"name": "Artist"}]
          }
        }
        """
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))
        XCTAssertTrue(state.isCompleted)
        XCTAssertEqual(state.status.state, .stopped)
    }

    func testPausedTrackBeforeEndRemainsPaused() throws {
        let json = """
        {
          "progress_ms": 10000,
          "is_playing": false,
          "item": {
            "id": "track-1",
            "name": "Paused",
            "duration_ms": 180000,
            "artists": [{"name": "Artist"}]
          }
        }
        """
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))
        XCTAssertFalse(state.isCompleted)
        XCTAssertEqual(state.status.state, .paused)
    }

    func testPartialPlayerStateMarksMissingTransportFields() throws {
        let json = #"{"item":{"id":"track-1","name":"Partial"}}"#
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))

        XCTAssertFalse(state.isPlayingWasReported)
        XCTAssertFalse(state.progressWasReported)
        XCTAssertNil(state.progressMs)
        XCTAssertEqual(state.item?.name, "Partial")
        XCTAssertNil(state.timestampMs)
    }

    func testPartialItemWithoutNameDoesNotBecomeAFalseNewTrack() throws {
        let json = #"{"is_playing":true,"progress_ms":12000,"item":{"id":"track-1"}}"#
        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))

        XCTAssertEqual(state.item?.id, "track-1")
        XCTAssertNil(state.signature)
        XCTAssertEqual(state.status.state, .playing)
    }

    func testPartialArtistObjectDoesNotBreakPlaybackStateDecode() throws {
        let json = #"""
        {
          "is_playing": true,
          "progress_ms": 1234,
          "item": {
            "id": "track-1",
            "name": "Partial track",
            "artists": [{}],
            "duration_ms": 180000
          }
        }
        """#

        let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: Data(json.utf8))

        XCTAssertEqual(state.item?.artists?.first?.name, "")
        XCTAssertEqual(state.signature?.title, "Partial track")
        XCTAssertEqual(state.status.state, .playing)
    }
}
