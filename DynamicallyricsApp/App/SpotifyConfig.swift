import Foundation

enum SpotifyConfig {
    /// Create an app at https://developer.spotify.com/dashboard and add
    /// `dynamicallyrics://callback` as a redirect URI. A beta tester can
    /// replace the bundled value in the app. Client IDs are public OAuth
    /// metadata; access and refresh tokens remain in the Keychain.
    private static let bundledClientID = "6401f24daeea4c2aa4e333778dff01a2"
    private static let clientIDKey = "spotify_client_id"

    static var clientID: String {
        let saved = KeychainStore.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved! : bundledClientID
    }

    static var savedClientID: String {
        KeychainStore.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveClientID(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed.isEmpty ? nil : trimmed, forKey: clientIDKey)
    }

    static let redirectURI = URL(string: "dynamicallyrics://callback")!
    static let scopes = "user-read-playback-state user-read-currently-playing user-read-recently-played user-modify-playback-state"

    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "YOUR_SPOTIFY_CLIENT_ID"
    }
}
