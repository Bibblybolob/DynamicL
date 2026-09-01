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

    func testPartialSameTrackResponseKeepsStableMetadata() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Song", artist: "Artist", album: "Album", duration: 180),
            albumImageURL: "https://example.com/art.jpg"
        )

        metadata.accept(
            trackKey: "track-1",
            trackID: nil,
            signature: .init(title: "", artist: "", album: nil, duration: nil),
            albumImageURL: nil
        )

        XCTAssertEqual(metadata.signature, .init(title: "Song", artist: "Artist", album: "Album", duration: 180))
        XCTAssertEqual(metadata.trackID, "track-1")
    }

    func testPartialResponseWithoutTrackIDKeepsAcceptedIdentity() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Song", artist: "Artist", duration: 180),
            albumImageURL: "https://example.com/art.jpg"
        )

        metadata.accept(
            trackKey: "Song|Artist|",
            trackID: nil,
            signature: .init(title: "Song", artist: "Artist"),
            albumImageURL: nil
        )

        XCTAssertEqual(metadata.trackKey, "track-1")
        XCTAssertEqual(metadata.trackID, "track-1")
        XCTAssertEqual(metadata.albumImageURL, "https://example.com/art.jpg")
    }

    func testSameTitleAndArtistWithDifferentAlbumIsNewTrack() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Song", artist: "Artist", album: "Original Album", duration: 180),
            albumImageURL: "https://example.com/original.jpg"
        )

        metadata.accept(
            trackKey: "Song|Artist|remix",
            trackID: nil,
            signature: .init(title: "Song", artist: "Artist", album: "Remix Album", duration: 181),
            albumImageURL: nil
        )

        XCTAssertEqual(metadata.trackKey, "Song|Artist|remix")
        XCTAssertNil(metadata.trackID)
        XCTAssertEqual(metadata.signature?.album, "Remix Album")
        XCTAssertNil(metadata.albumImageURL)
    }

    func testSameTitleAndArtistWithMissingAlbumStillKeepsArtwork() {
        var metadata = NowPlayingMetadata()
        metadata.accept(
            trackKey: "track-1",
            trackID: "track-1",
            signature: .init(title: "Song", artist: "Artist", album: "Album", duration: 180),
            albumImageURL: "https://example.com/art.jpg"
        )

        metadata.accept(
            trackKey: "Song|Artist|",
            trackID: nil,
            signature: .init(title: "Song", artist: "Artist", album: nil, duration: nil),
            albumImageURL: nil
        )

        XCTAssertEqual(metadata.trackKey, "track-1")
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
