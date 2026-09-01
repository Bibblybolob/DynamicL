import Foundation
import Testing
@testable import LyricCore

struct PlaybackTransitionPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func stableTrackIDWinsWhenPartialResponseOmitsTextMetadata() {
        let matches = PlaybackTransitionPolicy.isSameTrack(
            incomingID: "track-1",
            acceptedID: "track-1",
            incomingTitle: nil,
            incomingArtist: nil,
            acceptedSignature: .init(title: "Song", artist: "Artist")
        )
        #expect(matches)
    }

    @Test
    func differentStableTrackIDDoesNotInheritAcceptedTransportState() {
        let matches = PlaybackTransitionPolicy.isSameTrack(
            incomingID: "track-2",
            acceptedID: "track-1",
            incomingTitle: "Song",
            incomingArtist: "Artist",
            acceptedSignature: .init(title: "Song", artist: "Artist")
        )
        #expect(matches == false)
    }

    @Test
    func textIdentityIsOnlyFallbackWhenIDsAreUnavailable() {
        let matches = PlaybackTransitionPolicy.isSameTrack(
            incomingID: nil,
            acceptedID: nil,
            incomingTitle: "Song",
            incomingArtist: "Artist",
            acceptedSignature: .init(title: "Song", artist: "Artist")
        )
        #expect(matches)
    }

    @Test
    func acceptsFreshEntryAfterCurrentTrackStarted() {
        let playedAt = now.addingTimeInterval(-2)

        #expect(PlaybackTransitionPolicy.acceptsRecentlyPlayed(
            playedAt: playedAt,
            now: now,
            currentTrackPosition: 1
        ))
    }

    @Test
    func rejectsOlderHistoryEntryForCurrentTrack() {
        let playedAt = now.addingTimeInterval(-50)

        #expect(!PlaybackTransitionPolicy.acceptsRecentlyPlayed(
            playedAt: playedAt,
            now: now,
            currentTrackPosition: 10
        ))
    }

    @Test
    func rejectsStaleAndFutureHistoryEntries() {
        #expect(!PlaybackTransitionPolicy.acceptsRecentlyPlayed(
            playedAt: now.addingTimeInterval(-61),
            now: now,
            currentTrackPosition: 0
        ))
        #expect(!PlaybackTransitionPolicy.acceptsRecentlyPlayed(
            playedAt: now.addingTimeInterval(6),
            now: now,
            currentTrackPosition: 0
        ))
    }
}
