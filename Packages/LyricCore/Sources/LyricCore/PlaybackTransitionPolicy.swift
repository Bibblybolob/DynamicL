import Foundation

/// Pure timing rules used when a playback provider cross-checks a stale
/// player response against a recently-played entry.
public enum PlaybackTransitionPolicy {
    /// Compares a player response with the accepted item before merging
    /// missing transport fields. A stable Spotify track ID is authoritative;
    /// title and artist are only a fallback for legacy or partial responses
    /// that do not contain an ID.
    public static func isSameTrack(
        incomingID: String?,
        acceptedID: String?,
        incomingTitle: String?,
        incomingArtist: String?,
        acceptedSignature: TrackSignature?
    ) -> Bool {
        let normalizedIncomingID = incomingID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAcceptedID = acceptedID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedIncomingID, !normalizedIncomingID.isEmpty,
           let normalizedAcceptedID, !normalizedAcceptedID.isEmpty {
            return normalizedIncomingID == normalizedAcceptedID
        }

        guard let acceptedSignature,
              let incomingTitle,
              !incomingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let incomingArtist,
              !incomingArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return acceptedSignature.title == incomingTitle
            && acceptedSignature.artist == incomingArtist
    }

    /// Returns true when a recently-played timestamp can represent a track
    /// transition from the track currently reported by the player endpoint.
    ///
    /// The history endpoint does not report playback state. The caller must
    /// therefore pass the current track position and only call this rule for a
    /// currently playing (or known stale-playing) sample. The freshness and
    /// estimated-start checks prevent an older history entry from replacing a
    /// legitimate long-running track.
    public static func acceptsRecentlyPlayed(
        playedAt: Date,
        now: Date,
        currentTrackPosition: TimeInterval,
        freshnessWindow: TimeInterval = 60,
        startTolerance: TimeInterval = 8
    ) -> Bool {
        guard currentTrackPosition.isFinite,
              currentTrackPosition >= 0,
              freshnessWindow > 0,
              startTolerance >= 0 else {
            return false
        }

        let age = now.timeIntervalSince(playedAt)
        guard age >= -5, age < freshnessWindow else { return false }

        let estimatedCurrentStart = now.addingTimeInterval(-currentTrackPosition)
        return playedAt >= estimatedCurrentStart.addingTimeInterval(-startTolerance)
    }
}

/// Tracks the edge from an active or uncertain player state to a confirmed
/// stop. A provider can report the same stopped state on every polling tick,
/// but stop side effects must run only once for each playback session.
public struct ConfirmedStopTransitionTracker: Sendable {
    public private(set) var didHandleCurrentStop = false

    public init() {}

    /// Returns true once when playback becomes confirmed stopped. Observing
    /// any other state arms the tracker for the next playback session.
    public mutating func observe(isConfirmedStopped: Bool) -> Bool {
        guard isConfirmedStopped else {
            didHandleCurrentStop = false
            return false
        }
        guard !didHandleCurrentStop else { return false }
        didHandleCurrentStop = true
        return true
    }
}
