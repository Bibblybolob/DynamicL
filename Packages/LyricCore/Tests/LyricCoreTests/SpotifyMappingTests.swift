import XCTest
@testable import LyricCore

final class SpotifyMappingTests: XCTestCase {
    func testDecodesPlayerState() throws {
        let json = """
        {
          "device": {"id": "abc", "is_active": true, "name": "iPhone"},
          "repeat_state": "off",
          "shuffle_state": false,
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
}
