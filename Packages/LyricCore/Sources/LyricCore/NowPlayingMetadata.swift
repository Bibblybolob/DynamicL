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

        if self.trackKey != trackKey {
            self.trackKey = trackKey
            self.trackID = trackID
            self.signature = signature
            self.albumImageURL = cleanURL?.isEmpty == false ? cleanURL : nil
            return
        }

        self.trackID = trackID ?? self.trackID
        self.signature = signature
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
}
