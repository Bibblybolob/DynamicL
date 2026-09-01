import Foundation

/// Subset of Spotify's `GET /v1/me/player` response that we consume.
public struct SpotifyPlayerState: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public var id: String?
        public var name: String?
        public var isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name
            case isActive = "is_active"
        }
    }
    public struct Item: Codable, Sendable, Equatable {
        public struct Artist: Codable, Sendable, Equatable {
            public var name: String

            public init(name: String) {
                self.name = name
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Spotify can return an empty artist object during a device
                // or track transition. Keep the player response usable so
                // the caller can merge the partial item with trusted state.
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
            }

            private enum CodingKeys: String, CodingKey {
                case name
            }
        }

        public struct Album: Codable, Sendable, Equatable {
            public struct Image: Codable, Sendable, Equatable {
                public var url: String?
                public var width: Int?
                public var height: Int?
            }

            public var name: String?
            public var images: [Image]?
        }

        public var id: String?
        public var name: String?
        public var artists: [Artist]?
        public var album: Album?
        public var durationMs: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, artists, album
            case durationMs = "duration_ms"
        }
    }

    public var progressMs: Int?
    /// Unix millisecond timestamp for the last Spotify playback event.
    /// Spotify changes this value for play, pause, skip, scrub, and a new
    /// item. It is an event clock, not the observation time for progress_ms.
    public var timestampMs: Int64?
    public var isPlaying: Bool
    /// True when Spotify included a non-null `is_playing` value in the response.
    /// A false value means the caller must preserve a trusted local value.
    public var isPlayingWasReported: Bool
    /// True when Spotify included a non-null `progress_ms` value in the response.
    /// A false value means the caller must preserve or project the last sample.
    public var progressWasReported: Bool
    /// True when the response included the `item` key. A missing key is a
    /// partial transition response and must not be treated as a confirmed stop;
    /// an explicit `item: null` remains a real no-item response.
    public var itemWasReported: Bool
    public var item: Item?
    public var device: Device?

    enum CodingKeys: String, CodingKey {
        case timestampMs = "timestamp"
        case isPlaying = "is_playing"
        case item
        case progressMs = "progress_ms"
        case device
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestampMs = try container.decodeIfPresent(Int64.self, forKey: .timestampMs)
        let isPlayingValue = try container.decodeIfPresent(Bool.self, forKey: .isPlaying)
        let progressValue = try container.decodeIfPresent(Int.self, forKey: .progressMs)
        self.isPlaying = isPlayingValue ?? false
        self.isPlayingWasReported = isPlayingValue != nil
        self.progressMs = progressValue
        self.progressWasReported = progressValue != nil
        self.item = try container.decodeIfPresent(Item.self, forKey: .item)
        self.itemWasReported = container.contains(.item)
        self.device = try container.decodeIfPresent(Device.self, forKey: .device)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(timestampMs, forKey: .timestampMs)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encodeIfPresent(progressMs, forKey: .progressMs)
        try container.encodeIfPresent(item, forKey: .item)
        try container.encodeIfPresent(device, forKey: .device)
    }

    /// The event date reported by Spotify, when the value is usable.
    /// Callers must still use the current response time for progress_ms.
    public var playbackChangeDate: Date? {
        guard let timestampMs, timestampMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1_000)
    }

    /// URL of a reasonably-sized album cover image, when available.
    public var albumImageURL: String? {
        // Images come largest-first; prefer something near 300px wide.
        guard let images = item?.album?.images, !images.isEmpty else { return nil }
        return (images.last(where: { ($0.width ?? 0) >= 300 }) ?? images.last)?.url
    }

    public var signature: TrackSignature? {
        guard let item, let name = item.name, !name.isEmpty else { return nil }
        return TrackSignature(
            title: name,
            artist: item.artists?.first?.name ?? "",
            album: item.album?.name,
            duration: item.durationMs.map { TimeInterval($0) / 1000.0 }
        )
    }

    /// Spotify can report the final position with `is_playing == false`
    /// before it returns `item: null`. Treat that state as stopped so the app,
    /// widgets, Watch, and Live Activity can move to the idle state together.
    public var isCompleted: Bool {
        guard let durationMs = item?.durationMs,
              durationMs > 0,
              let progressMs,
              progressMs >= durationMs - 750 else { return false }
        return !isPlaying
    }

    public var status: PlaybackStatus {
        PlaybackStatus(
            // A 200 response with `item: null` means there is no current
            // playback item. Treating it as a paused song leaves stale title
            // and lyric UI alive until a later 204 response.
            state: (itemWasReported && item == nil) || isCompleted
                ? .stopped : (isPlaying ? .playing : .paused),
            position: TimeInterval(progressMs ?? 0) / 1000.0,
            rate: isPlaying && item != nil ? 1.0 : 0.0
        )
    }
}

public struct SpotifyTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String?
    public var expiresIn: Int
    public var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}
