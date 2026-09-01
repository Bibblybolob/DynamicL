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
            albumDominantRGB: [0.2, 0.4, 0.8],
            lyricOffsetMs: -1_250,
            trackDuration: 183.25,
            currentLine: "Hello line",
            isPlaying: true,
            scheduledLines: [
                .init(date: Date(timeIntervalSince1970: 1_000), text: "Next line"),
            ]
        )

        SharedNowPlaying.save(snapshot, defaults: defaults)

        let loaded = try XCTUnwrap(SharedNowPlaying.load(defaults: defaults))
        var expected = snapshot
        expected.albumImageData = nil
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.lyricOffsetMs, -1_250)
        XCTAssertEqual(
            SharedNowPlaying.cachedArtwork(
                for: snapshot.albumImageURL,
                defaults: defaults
            ),
            Data([9, 8, 7])
        )
        let stored = try XCTUnwrap(defaults.data(forKey: "widgetLyricSnapshot"))
        let storedSnapshot = try XCTUnwrap(
            try? JSONDecoder().decode(WidgetLyricSnapshot.self, from: stored)
        )
        XCTAssertNil(storedSnapshot.albumImageData)
    }

    func testLoadMigratesLegacyImageBytesOutOfSnapshot() throws {
        let snapshot = WidgetLyricSnapshot(
            trackTitle: "Old Song",
            artistName: "Old Artist",
            albumImageURL: "https://example.com/old.jpg",
            albumImageData: Data(repeating: 7, count: 2_000),
            currentLine: "Old line",
            isPlaying: true
        )
        let legacyData = try JSONEncoder().encode(snapshot)
        defaults.set(legacyData, forKey: "widgetLyricSnapshot")

        let loaded = try XCTUnwrap(SharedNowPlaying.load(defaults: defaults))

        XCTAssertNil(loaded.albumImageData)
        XCTAssertEqual(
            SharedNowPlaying.cachedArtwork(
                for: snapshot.albumImageURL,
                defaults: defaults
            )?.count,
            2_000
        )
        XCTAssertLessThan(
            try XCTUnwrap(defaults.data(forKey: "widgetLyricSnapshot")).count,
            legacyData.count
        )
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

    func testEffectivePlayingUsesShortLivedOverride() {
        let snapshot = WidgetLyricSnapshot(
            trackTitle: "Test Song",
            artistName: "Test Artist",
            currentLine: "Hello line",
            isPlaying: true
        )

        XCTAssertTrue(SharedNowPlaying.effectiveIsPlaying(snapshot, defaults: defaults))

        SharedNowPlaying.setPlayingOverride(false, defaults: defaults)
        XCTAssertFalse(SharedNowPlaying.effectiveIsPlaying(snapshot, defaults: defaults))

        SharedNowPlaying.setPlayingOverride(nil, defaults: defaults)
        XCTAssertTrue(SharedNowPlaying.effectiveIsPlaying(snapshot, defaults: defaults))
    }

    func testPlayingOverrideDoesNotLeakAcrossTracks() {
        let firstTrack = WidgetLyricSnapshot(
            trackTitle: "First Song",
            artistName: "Test Artist",
            trackID: "track-1",
            currentLine: "First line",
            isPlaying: true
        )
        let secondTrack = WidgetLyricSnapshot(
            trackTitle: "Second Song",
            artistName: "Test Artist",
            trackID: "track-2",
            currentLine: "Second line",
            isPlaying: true
        )

        SharedNowPlaying.setPlayingOverride(false, trackID: firstTrack.trackID, defaults: defaults)

        XCTAssertFalse(SharedNowPlaying.effectiveIsPlaying(firstTrack, defaults: defaults))
        XCTAssertTrue(SharedNowPlaying.effectiveIsPlaying(secondTrack, defaults: defaults))
    }

    func testClearRemovesPendingSessionRequests() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        SharedNowPlaying.requestLocalSessionStart(at: requestedAt, defaults: defaults)
        SharedNowPlaying.requestLiveActivityControl(true, at: requestedAt, defaults: defaults)
        SharedNowPlaying.requestLiveActivityEnable(at: requestedAt, defaults: defaults)

        SharedNowPlaying.clearAll(defaults: defaults)

        XCTAssertFalse(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.consumeLiveActivityEnableRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertNil(
            SharedNowPlaying.consumeLiveActivityControlRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
    }

    func testClearAllRemovesArtworkCache() {
        let url = "https://example.com/album.jpg"
        SharedNowPlaying.saveArtwork(Data([1, 2, 3]), for: url, defaults: defaults)

        SharedNowPlaying.clearAll(defaults: defaults)

        XCTAssertNil(SharedNowPlaying.cachedArtwork(for: url, defaults: defaults))
    }

    func testSnapshotClearPreservesPendingSessionRequest() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        SharedNowPlaying.requestLocalSessionStart(at: requestedAt, defaults: defaults)

        SharedNowPlaying.clear(defaults: defaults)

        XCTAssertTrue(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
    }

    func testLiveActivityFirstUseCompletionPersistsAndResets() {
        XCTAssertFalse(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(defaults: defaults)
        )

        SharedNowPlaying.markLiveActivityFirstUseCompleted(defaults: defaults)

        XCTAssertTrue(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(defaults: defaults)
        )

        SharedNowPlaying.resetLiveActivityFirstUse(defaults: defaults)

        XCTAssertFalse(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(defaults: defaults)
        )
    }

    func testLiveActivityFirstUseIsBoundToActivityID() {
        SharedNowPlaying.markLiveActivityFirstUseCompleted(
            for: "activity-1",
            defaults: defaults
        )

        XCTAssertTrue(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(
                for: "activity-1",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(
                for: "activity-2",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.hasCompletedLiveActivityFirstUse(
                for: nil,
                defaults: defaults
            )
        )
    }

    func testWatchSnapshotDoesNotReplacePhoneSnapshot() throws {
        let phone = WidgetLyricSnapshot(
            trackTitle: "Phone Song",
            artistName: "Phone Artist",
            currentLine: "Phone line",
            isPlaying: true
        )
        let watch = WidgetLyricSnapshot(
            trackTitle: "Watch Song",
            artistName: "Watch Artist",
            currentLine: "Watch line",
            isPlaying: false
        )

        SharedNowPlaying.save(phone, defaults: defaults)
        SharedNowPlaying.saveWatch(watch, defaults: defaults)

        XCTAssertEqual(try XCTUnwrap(SharedNowPlaying.load(defaults: defaults)).trackTitle, "Phone Song")
        XCTAssertEqual(try XCTUnwrap(SharedNowPlaying.loadWatch(defaults: defaults)).trackTitle, "Watch Song")

        SharedNowPlaying.clearWatch(defaults: defaults)

        XCTAssertEqual(try XCTUnwrap(SharedNowPlaying.load(defaults: defaults)).trackTitle, "Phone Song")
        XCTAssertNil(SharedNowPlaying.loadWatch(defaults: defaults))
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

    func testLocalSessionRequestIsOneShot() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLocalSessionStart(at: requestedAt, defaults: defaults)

        XCTAssertTrue(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertEqual(
            SharedNowPlaying.localSessionStartRequestDate(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            ),
            requestedAt
        )

        XCTAssertTrue(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(2),
                defaults: defaults
            )
        )
    }

    func testLocalSessionRequestWaitsForBoundActivityAndRejectsReplacement() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLocalSessionStart(
            at: requestedAt,
            activityID: "activity-old",
            defaults: defaults
        )

        // The app may see the mailbox before ActivityKit adoption completes.
        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )

        // A later Activity must not inherit a delayed action from the old
        // card. The stale request is consumed and cannot fire again.
        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(2),
                activityID: "activity-new",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(3),
                defaults: defaults
            )
        )
    }

    func testLocalSessionRequestCanConsumeForItsActivity() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLocalSessionStart(
            at: requestedAt,
            activityID: "activity-current",
            defaults: defaults
        )

        XCTAssertTrue(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(1),
                activityID: "activity-current",
                defaults: defaults
            )
        )
    }

    func testDiscardLocalSessionRequestRemovesActivityBinding() {
        SharedNowPlaying.requestLocalSessionStart(
            activityID: "activity-current",
            defaults: defaults
        )

        SharedNowPlaying.discardLocalSessionStartRequest(defaults: defaults)

        XCTAssertFalse(
            SharedNowPlaying.hasLocalSessionStartRequest(defaults: defaults)
        )
        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                activityID: "activity-current",
                defaults: defaults
            )
        )
    }

    func testLocalSessionRequestExpires() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLocalSessionStart(at: requestedAt, defaults: defaults)

        XCTAssertTrue(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(119.999),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.hasLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(120.001),
                defaults: defaults
            )
        )

        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: requestedAt.addingTimeInterval(120.001),
                defaults: defaults
            )
        )
    }

    func testLiveActivityEnableRequestIsOneShot() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLiveActivityEnable(at: requestedAt, defaults: defaults)

        XCTAssertTrue(
            SharedNowPlaying.consumeLiveActivityEnableRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            SharedNowPlaying.consumeLiveActivityEnableRequest(
                now: requestedAt.addingTimeInterval(2),
                defaults: defaults
            )
        )
    }

    func testLiveActivityEnableRequestExpires() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLiveActivityEnable(at: requestedAt, defaults: defaults)

        XCTAssertFalse(
            SharedNowPlaying.consumeLiveActivityEnableRequest(
                now: requestedAt.addingTimeInterval(30.001),
                defaults: defaults
            )
        )
    }

    func testLiveActivityControlRequestPreservesValueAndIsOneShot() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLiveActivityControl(
            true,
            at: requestedAt,
            defaults: defaults
        )

        XCTAssertEqual(
            SharedNowPlaying.consumeLiveActivityControlRequest(
                now: requestedAt.addingTimeInterval(1),
                defaults: defaults
            ),
            true
        )
        XCTAssertNil(
            SharedNowPlaying.consumeLiveActivityControlRequest(
                now: requestedAt.addingTimeInterval(2),
                defaults: defaults
            )
        )
    }

    func testLiveActivityControlRequestExpires() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        SharedNowPlaying.requestLiveActivityControl(
            false,
            at: requestedAt,
            defaults: defaults
        )

        XCTAssertNil(
            SharedNowPlaying.consumeLiveActivityControlRequest(
                now: requestedAt.addingTimeInterval(30.001),
                defaults: defaults
            )
        )
    }

    func testLiveActivityControlStatePersists() {
        XCTAssertFalse(SharedNowPlaying.liveActivityControlEnabled(defaults: defaults))

        SharedNowPlaying.setLiveActivityControlEnabled(true, defaults: defaults)
        XCTAssertTrue(SharedNowPlaying.liveActivityControlEnabled(defaults: defaults))

        SharedNowPlaying.setLiveActivityControlEnabled(false, defaults: defaults)
        XCTAssertFalse(SharedNowPlaying.liveActivityControlEnabled(defaults: defaults))
    }

    func testLegacyBooleanLocalSessionRequestIsIgnored() {
        defaults.set(true, forKey: "localLyricsSessionRequested")

        XCTAssertFalse(
            SharedNowPlaying.consumeLocalSessionStartRequest(
                now: Date(timeIntervalSince1970: 1_000),
                defaults: defaults
            )
        )
        XCTAssertNil(defaults.object(forKey: "localLyricsSessionRequested"))
    }
}
