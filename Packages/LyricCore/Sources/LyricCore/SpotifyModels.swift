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
            public var name: String?
        }

        public var name: String
        public var artists: [Artist]?
        public var album: Album?
        public var durationMs: Int?

        enum CodingKeys: String, CodingKey {
            case name, artists, album
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

    public var signature: TrackSignature? {
        guard let item else { return nil }
        return TrackSignature(
            title: item.name,
            artist: item.artists?.first?.name ?? "",
            album: item.album?.name,
            duration: item.durationMs.map { TimeInterval($0) / 1000.0 }
        )
    }

    public var status: PlaybackStatus {
        PlaybackStatus(
            state: isPlaying ? .playing : .paused,
            position: TimeInterval(progressMs ?? 0) / 1000.0,
            rate: isPlaying ? 1.0 : 0.0
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
