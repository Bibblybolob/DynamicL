import Foundation

enum SpotifyConfig {
    /// Create an app at https://developer.spotify.com/dashboard, add
    /// `dynamicallyrics://callback` as a redirect URI, then paste the Client ID here.
    static let clientID = "6401f24daeea4c2aa4e333778dff01a2"

    static let redirectURI = URL(string: "dynamicallyrics://callback")!
    static let scopes = "user-read-playback-state user-read-currently-playing user-read-recently-played user-modify-playback-state"

    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "YOUR_SPOTIFY_CLIENT_ID"
    }
}
