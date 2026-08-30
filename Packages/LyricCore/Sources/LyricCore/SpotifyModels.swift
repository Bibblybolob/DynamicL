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
        public var name: String
        public var artists: [Artist]?
        public var album: Album?
        public var durationMs: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, artists, album
            case durationMs = "duration_ms"
        }
    }

    public var progressMs: Int?
    public var isPlaying: Bool
    public var item: Item?
    public var device: Device?

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case item
        case progressMs = "progress_ms"
        case device
    }

    /// URL of a reasonably-sized album cover image, when available.
    public var albumImageURL: String? {
        // Images come largest-first; prefer something near 300px wide.
        guard let images = item?.album?.images, !images.isEmpty else { return nil }
        return (images.last(where: { ($0.width ?? 0) >= 300 }) ?? images.last)?.url
    }

    public var signature: TrackSignature? {
        guard let item else { return nil }
        return TrackSignature(
            title: item.name,
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
            state: item == nil || isCompleted ? .stopped : (isPlaying ? .playing : .paused),
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
