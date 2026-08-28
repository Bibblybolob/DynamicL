import XCTest
@testable import LyricCore

final class SharedNowPlayingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SharedNowPlayingTests")
        defaults.removePersistentDomain(forName: "SharedNowPlayingTests")
    }

    func testRoundTripSnapshot() throws {
        let snapshot = WidgetLyricSnapshot(
            trackTitle: "Test Song",
            artistName: "Test Artist",
            albumImageURL: "https://example.com/album.jpg",
            albumImageData: Data([9, 8, 7]),
            currentLine: "Hello line",
            isPlaying: true,
            scheduledLines: [
                .init(date: Date(timeIntervalSince1970: 1_000), text: "Next line"),
            ]
        )

        SharedNowPlaying.save(snapshot, defaults: defaults)

        let loaded = try XCTUnwrap(SharedNowPlaying.load(defaults: defaults))
        XCTAssertEqual(loaded, snapshot)
    }

    func testClearRemovesSnapshotButKeepsArtwork() {
        SharedNowPlaying.setPlayingOverride(true, defaults: defaults)
        SharedNowPlaying.saveArtwork(Data([1, 2, 3]), for: "https://example.com/album.jpg", defaults: defaults)
        let snapshot = WidgetLyricSnapshot(
            trackTitle: "Test Song",
            artistName: "Test Artist",
            currentLine: "Hello line",
            isPlaying: false
        )
        SharedNowPlaying.save(snapshot, defaults: defaults)
        XCTAssertNotNil(SharedNowPlaying.load(defaults: defaults))

        SharedNowPlaying.clear(defaults: defaults)

        XCTAssertNil(SharedNowPlaying.load(defaults: defaults))
        XCTAssertNil(SharedNowPlaying.playingOverride(defaults: defaults))
        XCTAssertEqual(
            SharedNowPlaying.cachedArtwork(for: "https://example.com/album.jpg", defaults: defaults),
            Data([1, 2, 3])
        )
    }

    func testExplicitArtworkClearRemovesImages() {
        let url = "https://example.com/album.jpg"
        SharedNowPlaying.saveArtwork(Data([1, 2, 3]), for: url, defaults: defaults)

        SharedNowPlaying.clearArtworkCache(defaults: defaults)

        XCTAssertNil(SharedNowPlaying.cachedArtwork(for: url, defaults: defaults))
    }

    func testArtworkCacheKeepsFourMostRecentImages() {
        for index in 0..<5 {
            SharedNowPlaying.saveArtwork(
                Data([UInt8(index)]),
                for: "https://example.com/\(index).jpg",
                defaults: defaults
            )
        }

        XCTAssertNil(SharedNowPlaying.cachedArtwork(
            for: "https://example.com/0.jpg",
            defaults: defaults
        ))
        for index in 1..<5 {
            XCTAssertEqual(
                SharedNowPlaying.cachedArtwork(
                    for: "https://example.com/\(index).jpg",
                    defaults: defaults
                ),
                Data([UInt8(index)])
            )
        }
    }

    func testArtworkReadUpdatesTheLRUOrder() {
        for index in 0..<4 {
            SharedNowPlaying.saveArtwork(
                Data([UInt8(index)]),
                for: "https://example.com/\(index).jpg",
                defaults: defaults
            )
        }
        XCTAssertNotNil(SharedNowPlaying.cachedArtwork(
            for: "https://example.com/0.jpg",
            defaults: defaults
        ))

        SharedNowPlaying.saveArtwork(
            Data([4]),
            for: "https://example.com/4.jpg",
            defaults: defaults
        )

        XCTAssertNotNil(SharedNowPlaying.cachedArtwork(
            for: "https://example.com/0.jpg",
            defaults: defaults
        ))
        XCTAssertNil(SharedNowPlaying.cachedArtwork(
            for: "https://example.com/1.jpg",
            defaults: defaults
        ))
    }

    func testArtworkCacheRejectsDifferentURL() {
        let firstURL = "https://example.com/first.jpg"
        let secondURL = "https://example.com/second.jpg"
        let data = Data([1, 2, 3])

        SharedNowPlaying.saveArtwork(data, for: firstURL, defaults: defaults)

        XCTAssertEqual(SharedNowPlaying.cachedArtwork(for: firstURL, defaults: defaults), data)
        XCTAssertNil(SharedNowPlaying.cachedArtwork(for: secondURL, defaults: defaults))
    }

    func testLoadWithNoDataReturnsNil() {
        XCTAssertNil(SharedNowPlaying.load(defaults: defaults))
        XCTAssertNil(SharedNowPlaying.load(defaults: nil))
    }
}
