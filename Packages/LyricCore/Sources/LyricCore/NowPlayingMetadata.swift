import Foundation

/// Keeps stable metadata for the accepted playback item.
///
/// Spotify can return a complete item followed by a partial response for the
/// same item. A missing image in that partial response must not remove artwork
/// that is already correct. A verified new item starts with clean metadata so
/// artwork from the previous track can never leak into it.
public struct NowPlayingMetadata: Equatable, Sendable {
    public private(set) var trackKey: String?
    public private(set) var trackID: String?
    public private(set) var signature: TrackSignature?
    public private(set) var albumImageURL: String?
    public private(set) var stoppedSamples = 0

    public init() {}

    public mutating func accept(
        trackKey: String,
        trackID: String?,
        signature: TrackSignature,
        albumImageURL: String?
    ) {
        stoppedSamples = 0
        let cleanURL = albumImageURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        let samePartialTrack = trackID == nil && self.signature.map {
            isCompatiblePartialTrack(existing: $0, incoming: signature)
        } == true
        if self.trackKey != trackKey && !samePartialTrack {
            self.trackKey = trackKey
            self.trackID = trackID
            self.signature = signature
            self.albumImageURL = cleanURL?.isEmpty == false ? cleanURL : nil
            return
        }

        self.trackID = trackID ?? self.trackID
        self.signature = mergedSignature(existing: self.signature, incoming: signature)
        if let cleanURL, !cleanURL.isEmpty {
            self.albumImageURL = cleanURL
        }
    }

    /// Records a trustworthy stopped response. Metadata clears only after the
    /// required number of independent samples, which filters short 204 blips.
    @discardableResult
    public mutating func observeStopped(requiredSamples: Int = 2) -> Bool {
        stoppedSamples += 1
        guard stoppedSamples >= max(1, requiredSamples) else { return false }
        clear()
        return true
    }

    public mutating func replace(
        trackKey: String,
        trackID: String?,
        signature: TrackSignature,
        albumImageURL: String?
    ) {
        self.trackKey = trackKey
        self.trackID = trackID
        self.signature = signature
        self.albumImageURL = albumImageURL
        self.stoppedSamples = 0
    }

    public mutating func clear() {
        trackKey = nil
        trackID = nil
        signature = nil
        albumImageURL = nil
        stoppedSamples = 0
    }

    /// Spotify can omit fields during a transition. Empty text, missing album,
    /// and missing duration are not new metadata; preserve the last complete
    /// value so the app does not reload lyrics or redraw artwork for a partial
    /// response belonging to the same track.
    private func mergedSignature(
        existing: TrackSignature?,
        incoming: TrackSignature
    ) -> TrackSignature {
        guard let existing else { return incoming }
        return TrackSignature(
            title: incoming.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? existing.title : incoming.title,
            artist: incoming.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? existing.artist : incoming.artist,
            album: incoming.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? incoming.album : existing.album,
            duration: incoming.duration.flatMap { $0 > 0 ? $0 : nil } ?? existing.duration
        )
    }

    /// A response without an ID can still be a partial response for the
    /// current item. Title and artist are not sufficient identity because
    /// different releases can contain the same recording name. Keep the old
    /// artwork only when explicitly reported album and duration values do not
    /// conflict with the accepted item.
    private func isCompatiblePartialTrack(
        existing: TrackSignature,
        incoming: TrackSignature
    ) -> Bool {
        guard existing.title == incoming.title,
              existing.artist == incoming.artist else { return false }

        let existingAlbum = existing.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingAlbum = incoming.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingAlbum, !existingAlbum.isEmpty,
           let incomingAlbum, !incomingAlbum.isEmpty,
           existingAlbum != incomingAlbum {
            return false
        }

        if let existingDuration = existing.duration, existingDuration > 0,
           let incomingDuration = incoming.duration, incomingDuration > 0,
           abs(existingDuration - incomingDuration) > 2.0 {
            return false
        }

        return true
    }
}
