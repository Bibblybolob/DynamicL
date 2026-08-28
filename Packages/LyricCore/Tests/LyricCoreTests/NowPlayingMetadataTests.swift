import XCTest
@testable import LyricCore

final class NowPlayingMetadataTests: XCTestCase {
    func testPartialSameTrackResponseKeepsArtwork() {
        var metadata = NowPlayingMetadata()
        let signature = TrackSignature(title: "Song", artist: "Artist")
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: signature,
            albumImageURL: "https://example.com/art.jpg"
        )

        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: signature,
            albumImageURL: nil
        )

        XCTAssertEqual(metadata.albumImageURL, "https://example.com/art.jpg")
    }

    func testVerifiedNewTrackDoesNotUseOldArtwork() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Old", artist: "Artist"),
            albumImageURL: "https://example.com/old.jpg"
        )

        metadata.accept(
            trackKey: "track-2",
            trackID: "track-2",
            signature: .init(title: "New", artist: "Artist"),
            albumImageURL: nil
        )

        XCTAssertNil(metadata.albumImageURL)
        XCTAssertEqual(metadata.trackID, "track-2")
    }

    func testArtworkClearsOnlyAfterConfirmedStop() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Song", artist: "Artist"),
            albumImageURL: "https://example.com/art.jpg"
        )

        XCTAssertFalse(metadata.observeStopped())
        XCTAssertNotNil(metadata.albumImageURL)
        XCTAssertTrue(metadata.observeStopped())
        XCTAssertNil(metadata.albumImageURL)
    }
}
