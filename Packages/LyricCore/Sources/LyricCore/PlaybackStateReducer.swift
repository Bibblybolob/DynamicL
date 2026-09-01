import Foundation

/// The playback phase used by every lyric surface.
public enum UnifiedPlaybackPhase: String, Codable, Hashable, Sendable {
    case none
    case paused
    case playing
}

/// Stable track metadata shared by the app, extensions, Watch, and server.
/// Spotify's track ID is the primary identity. Other fields are mergeable
/// metadata and must not replace a trusted value with an empty partial value.
public struct UnifiedTrack: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Double?
    public var artworkURL: String?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        durationMs: Double? = nil,
        artworkURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
    }
}

/// One observation from Spotify. Optional fields represent fields that were
/// absent from a partial response. They do not mean that trusted state should
/// be cleared.
public struct PlaybackObservation: Sendable, Equatable {
    public var itemPresent: Bool
    public var trackID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationMs: Double?
    public var artworkURL: String?
    public var isPlaying: Bool?
    public var progressMs: Double?
    public var eventTimestampMs: Int64?
    public var receivedAt: Date

    public init(
        itemPresent: Bool = true,
        trackID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Double? = nil,
        artworkURL: String? = nil,
        isPlaying: Bool? = nil,
        progressMs: Double? = nil,
        eventTimestampMs: Int64? = nil,
        receivedAt: Date = Date()
    ) {
        self.itemPresent = itemPresent
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.eventTimestampMs = eventTimestampMs
        self.receivedAt = receivedAt
    }
}

/// The canonical playback snapshot. A surface can project lyric timing from
/// `positionMs`, `phase`, and `anchorDate` without polling its owner.
public struct UnifiedPlaybackSnapshot: Codable, Equatable, Hashable, Sendable {
    public var track: UnifiedTrack?
    public var phase: UnifiedPlaybackPhase
    public var positionMs: Double
    public var anchorDate: Date?
    public var lyricOffsetMs: Double
    public var revision: Int64
    public var lastEventTimestampMs: Int64?
    public var lastObservedAt: Date?

    public init(
        track: UnifiedTrack? = nil,
        phase: UnifiedPlaybackPhase = .none,
        positionMs: Double = 0,
        anchorDate: Date? = nil,
        lyricOffsetMs: Double = 0,
        revision: Int64 = 0,
        lastEventTimestampMs: Int64? = nil,
        lastObservedAt: Date? = nil
    ) {
        self.track = track
        self.phase = phase
        self.positionMs = max(0, positionMs)
        self.anchorDate = anchorDate
        self.lyricOffsetMs = lyricOffsetMs
        self.revision = revision
        self.lastEventTimestampMs = lastEventTimestampMs
        self.lastObservedAt = lastObservedAt
    }

    public var isPlaying: Bool { phase == .playing }

    /// Position projected onto the same clock as an observation at `date`.
    public func projectedPosition(at date: Date) -> Double {
        guard phase == .playing, let anchorDate else { return positionMs }
        return max(0, date.timeIntervalSince(anchorDate) * 1_000)
    }
}

public enum PlaybackReductionKind: String, Sendable, Equatable {
    case ignoredStale
    case stopped
    case trackChanged
    case playStateChanged
    case seek
    case metadataMerged
    case progressUpdated
    case unchanged
}

public struct PlaybackReduction: Sendable, Equatable {
    public let kind: PlaybackReductionKind
    public let snapshot: UnifiedPlaybackSnapshot?
    public let positionDeltaMs: Double

    public init(
        kind: PlaybackReductionKind,
        snapshot: UnifiedPlaybackSnapshot?,
        positionDeltaMs: Double = 0
    ) {
        self.kind = kind
        self.snapshot = snapshot
        self.positionDeltaMs = positionDeltaMs
    }
}

/// Merges Spotify observations into one monotonic playback state.
///
/// The reducer is deliberately independent of SwiftUI and ActivityKit. This
/// makes the same rules usable by the phone poller, server fixtures, widgets,
/// and Watch. A response with an older Spotify event timestamp is ignored.
public struct PlaybackStateReducer: Sendable {
    public private(set) var snapshot: UnifiedPlaybackSnapshot?
    private var nextRevision: Int64

    public init(initial: UnifiedPlaybackSnapshot? = nil) {
        self.snapshot = initial
        self.nextRevision = max(0, initial?.revision ?? 0)
    }

    @discardableResult
    public mutating func reduce(_ observation: PlaybackObservation) -> PlaybackReduction {
        if let incomingEvent = observation.eventTimestampMs,
           incomingEvent > 0,
           let previousEvent = snapshot?.lastEventTimestampMs,
           incomingEvent < previousEvent {
            return PlaybackReduction(kind: .ignoredStale, snapshot: snapshot)
        }

        guard observation.itemPresent else {
            let old = snapshot
            nextRevision &+= 1
            snapshot = UnifiedPlaybackSnapshot(
                track: nil,
                phase: .none,
                positionMs: 0,
                lyricOffsetMs: old?.lyricOffsetMs ?? 0,
                revision: nextRevision,
                lastEventTimestampMs: observation.eventTimestampMs ?? old?.lastEventTimestampMs,
                lastObservedAt: observation.receivedAt
            )
            return PlaybackReduction(kind: .stopped, snapshot: snapshot)
        }

        let old = snapshot
        let sameTrack = isSameTrack(observation, as: old?.track)
        let track = mergedTrack(observation, oldTrack: sameTrack ? old?.track : nil)
        guard let track else {
            // A partial response without an ID or identifying metadata cannot
            // safely replace a known track. Keep the trusted state unchanged.
            return PlaybackReduction(kind: .unchanged, snapshot: snapshot)
        }

        let oldPhase = old?.phase ?? .none
        let phase: UnifiedPlaybackPhase
        if let isPlaying = observation.isPlaying {
            phase = isPlaying ? .playing : .paused
        } else {
            phase = sameTrack ? oldPhase : .paused
        }

        let projected = projectedPosition(from: old, at: observation.receivedAt)
        let hasPosition = observation.progressMs.map { $0.isFinite && $0 >= 0 } ?? false
        let observedPosition = hasPosition ? max(0, observation.progressMs ?? 0) : projected
        let duration = track.durationMs ?? old?.track?.durationMs
        let position = duration.map { min(observedPosition, max(0, $0)) } ?? observedPosition
        let positionDelta = position - projected
        let isSeek = hasPosition && old != nil && sameTrack && abs(positionDelta) > 750

        nextRevision &+= 1
        let anchor: Date? = phase == .playing
            ? observation.receivedAt.addingTimeInterval(-(position / 1_000))
            : nil
        let newSnapshot = UnifiedPlaybackSnapshot(
            track: track,
            phase: phase,
            positionMs: position,
            anchorDate: anchor,
            lyricOffsetMs: old?.lyricOffsetMs ?? 0,
            revision: nextRevision,
            lastEventTimestampMs: maxEventTimestamp(
                observation.eventTimestampMs,
                old?.lastEventTimestampMs
            ),
            lastObservedAt: observation.receivedAt
        )
        snapshot = newSnapshot

        let kind: PlaybackReductionKind
        if !sameTrack { kind = .trackChanged }
        else if oldPhase != phase { kind = .playStateChanged }
        else if isSeek { kind = .seek }
        else if metadataChanged(old?.track, track) { kind = .metadataMerged }
        else if hasPosition { kind = .progressUpdated }
        else { kind = .unchanged }
        return PlaybackReduction(kind: kind, snapshot: newSnapshot, positionDeltaMs: positionDelta)
    }

    @discardableResult
    public mutating func setLyricOffset(_ offsetMs: Double) -> PlaybackReduction {
        let bounded = offsetMs.isFinite ? offsetMs : 0
        guard var current = snapshot else {
            return PlaybackReduction(kind: .unchanged, snapshot: nil)
        }
        nextRevision &+= 1
        current.lyricOffsetMs = bounded
        current.revision = nextRevision
        snapshot = current
        return PlaybackReduction(kind: .metadataMerged, snapshot: current)
    }

    private func isSameTrack(_ observation: PlaybackObservation, as old: UnifiedTrack?) -> Bool {
        guard let old else { return false }
        if let incomingID = nonEmpty(observation.trackID) {
            return incomingID == old.id
        }
        let incomingTitle = nonEmpty(observation.title)
        let incomingArtist = nonEmpty(observation.artist)
        if incomingTitle == nil && incomingArtist == nil { return true }
        if let incomingTitle, incomingTitle != old.title { return false }
        if let incomingArtist, incomingArtist != old.artist { return false }
        return true
    }

    private func mergedTrack(
        _ observation: PlaybackObservation,
        oldTrack: UnifiedTrack?
    ) -> UnifiedTrack? {
        let incomingID = nonEmpty(observation.trackID)
        let title = nonEmpty(observation.title) ?? oldTrack?.title
        let artist = nonEmpty(observation.artist) ?? oldTrack?.artist
        guard let title, let artist else { return nil }
        let id = incomingID ?? oldTrack?.id ?? derivedID(title: title, artist: artist)
        let duration = validNumber(observation.durationMs)
            ?? validNumber(oldTrack?.durationMs)
        let artwork = nonEmpty(observation.artworkURL) ?? oldTrack?.artworkURL
        return UnifiedTrack(
            id: id,
            title: title,
            artist: artist,
            album: nonEmpty(observation.album) ?? oldTrack?.album,
            durationMs: duration,
            artworkURL: artwork
        )
    }

    private func projectedPosition(
        from old: UnifiedPlaybackSnapshot?,
        at date: Date
    ) -> Double {
        guard let old else { return 0 }
        return old.projectedPosition(at: date)
    }

    private func metadataChanged(_ old: UnifiedTrack?, _ new: UnifiedTrack) -> Bool {
        guard let old else { return true }
        return old != new
    }

    private func validNumber(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func derivedID(title: String, artist: String) -> String {
        "derived:\(title.lowercased())|\(artist.lowercased())"
    }

    private func maxEventTimestamp(_ incoming: Int64?, _ previous: Int64?) -> Int64? {
        switch (incoming, previous) {
        case let (left?, right?): return max(left, right)
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }
}

public extension SpotifyPlayerState {
    /// Converts the Spotify decoder's presence flags into a reducer input.
    func playbackObservation(receivedAt: Date = Date()) -> PlaybackObservation {
        PlaybackObservation(
            itemPresent: itemWasReported && item != nil,
            trackID: item?.id,
            title: item?.name,
            artist: item?.artists?.first?.name,
            album: item?.album?.name,
            durationMs: item?.durationMs.map(Double.init),
            artworkURL: albumImageURL,
            isPlaying: isPlayingWasReported ? isPlaying : nil,
            progressMs: progressWasReported ? progressMs.map(Double.init) : nil,
            eventTimestampMs: timestampMs,
            receivedAt: receivedAt
        )
    }
}
