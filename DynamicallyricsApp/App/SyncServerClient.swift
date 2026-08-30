import Foundation
import LyricCore

enum SyncActivityState: String {
    case active
    case none
    case dismissed
}

/// Uploads Live Activity push tokens to the managed sync server so a
/// server-side poller can push content-state updates over APNs.
///
/// The server URL is built in. A private per-install server token is
/// obtained automatically after Spotify sign-in and stored in Keychain.
@MainActor
final class SyncServerClient {
    static let shared = SyncServerClient()

    private static let urlKey = "syncServerURL"
    private static let authTokenKey = "syncServerAuthToken"
    private static let managedServerMigrationKey = "managedSyncServerMigrationV1"
    private static let defaultServerURL = "https://open-lyrics-35df4bad49b3.herokuapp.com"

    /// Most recent tokens seen; re-uploaded when Spotify or ActivityKit changes.
    private(set) var updateToken: String?
    private(set) var pushToStartToken: String?
    private(set) var serverSessionDismissed = false

    private var pendingUploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastHeartbeatAt: Date?
    private var lastLyricOffsetMs = 0
    private var lastAlbumDominantRGB: [Double]?

    private init() {
        migrateLegacyServerSettings()
    }

    var serverURLString: String {
        Self.defaultServerURL
    }

    var serverAuthTokenString: String {
        KeychainStore.string(forKey: Self.authTokenKey) ?? ""
    }

    /// Retries registration after Spotify becomes available. ActivityKit can
    /// deliver the push-to-start token before the user signs in, so a token
    /// upload attempted at launch may have no Spotify refresh token yet.
    func refreshRegistration() {
        scheduleUpload()
    }

    /// Verifies the configured sync server. If this installation has not been
    /// paired, registration obtains a private server token automatically.
    func checkConnection() async -> SyncServerCheckResult {
        guard configuredBaseURL() != nil else { return .missingURL }
        if serverAuthTokenString.isEmpty {
            await uploadCurrentTokens(force: true)
        }
        guard !serverAuthTokenString.isEmpty else { return .missingAccessToken }
        guard let url = URL(string: endpoint(path: "status")) else { return .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(serverAuthTokenString)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200...299:
                DiagnosticsLog.append("sync: connection check passed")
                return .ready
            case 401:
                DiagnosticsLog.append("sync: connection check unauthorized")
                return .unauthorized
            case 503:
                DiagnosticsLog.append("sync: connection check server not configured")
                return .serverNotConfigured
            default:
                DiagnosticsLog.append("sync: connection check HTTP \(code)")
                return .failed
            }
        } catch {
            DiagnosticsLog.append("sync: connection check failed")
            return .failed
        }
    }

    private func scheduleUpload() {
        // Debounce re-upload until typing settles.
        pendingUploadTask?.cancel()
        pendingUploadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.uploadCurrentTokens(force: true)
        }
    }

    /// Records tokens arriving from ActivityKit streams and uploads them.
    func record(updateToken: String?, pushToStartToken: String?) async {
        if let token = updateToken, token != self.updateToken {
            self.updateToken = token
            DiagnosticsLog.append("push update token received (\(token.count) hex chars)")
        }
        if let token = pushToStartToken, token != self.pushToStartToken {
            self.pushToStartToken = token
            DiagnosticsLog.append("push-to-start token received (\(token.count) hex chars)")
        }
        await uploadCurrentTokens()
    }

    /// Removes an update token that belongs to an ended activity. The global
    /// push-to-start token remains registered for the next playback session.
    func noteActivityEnded(dismissed: Bool) {
        updateToken = nil
        if dismissed { serverSessionDismissed = true }
        lastHeartbeatAt = .distantPast
        DiagnosticsLog.append(dismissed ? "sync: activity dismissed" : "sync: activity ended")
    }

    func resetDismissalForNewSession() {
        serverSessionDismissed = false
        lastHeartbeatAt = .distantPast
    }

    /// Renews the phone's writer lease. If this call stops because iOS
    /// suspends the app or the local poll loop dies, the server takes over
    /// after 15 seconds.
    func heartbeat(
        activityState: SyncActivityState,
        trackID: String?,
        lyricOffset: TimeInterval,
        localRevision: Int64,
        healthy: Bool,
        autoStartEnabled: Bool,
        albumDominantRGB: [Double]? = nil,
        force: Bool = false
    ) {
        guard healthy else { return }
        lastLyricOffsetMs = Int((lyricOffset * 1_000).rounded())
        lastAlbumDominantRGB = albumDominantRGB
        let now = Date.now
        guard force || now.timeIntervalSince(lastHeartbeatAt ?? .distantPast) >= 5 else { return }
        guard heartbeatTask == nil else { return }
        guard configuredBaseURL() != nil, !serverAuthTokenString.isEmpty else { return }
        guard updateToken != nil || pushToStartToken != nil else { return }
        lastHeartbeatAt = now

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            defer { self.heartbeatTask = nil }
            guard let url = URL(string: self.endpoint(path: "heartbeat")) else { return }
            var body: [String: Any] = [
                "clientSchemaVersion": 2,
                "activityState": activityState.rawValue,
                "sentAtMs": Int64(now.timeIntervalSince1970 * 1_000),
                "localRevision": localRevision,
                "lyricOffsetMs": self.lastLyricOffsetMs,
                "autoStartEnabled": autoStartEnabled,
            ]
            if let albumDominantRGB = self.lastAlbumDominantRGB {
                body["albumDominantRGB"] = albumDominantRGB
            }
            if let updateToken = self.updateToken { body["updateToken"] = updateToken }
            if let trackID { body["trackID"] = trackID }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(self.serverAuthTokenString)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200...299).contains(code),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.applyServerState(object)
                    let writer = object["writer"] as? String ?? "phone"
                    DiagnosticsLog.append("sync: heartbeat ok writer=\(writer)")
                } else {
                    DiagnosticsLog.append("sync: heartbeat HTTP \(code)")
                }
            } catch {
                DiagnosticsLog.append("sync: heartbeat failed")
            }
        }
    }

    /// Sends a widget or Live Activity transport command to the background
    /// authority when it is configured. A missing configuration returns
    /// `.unavailable`, which permits a local Spotify call. An indeterminate
    /// result (for example, a timeout after the server may have accepted the
    /// command) must not fall back to a second transport call.
    func sendCommand(_ command: PlaybackCommand, id: UUID) async -> RemoteCommandResult {
        let serverCommand: String
        switch command {
        case .togglePlayPause: serverCommand = "toggle"
        case .next: serverCommand = "next"
        case .previous: serverCommand = "previous"
        case .refresh: return .unavailable
        }
        guard configuredBaseURL() != nil, !serverAuthTokenString.isEmpty else { return .unavailable }
        guard let url = URL(string: endpoint(path: "command")) else { return .rejected }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(serverAuthTokenString)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "command": serverCommand,
            "commandID": id.uuidString,
            "issuedAtMs": Int64(Date.now.timeIntervalSince1970 * 1_000),
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) {
                DiagnosticsLog.append("sync: command accepted \(serverCommand)")
                return .accepted
            }
            DiagnosticsLog.append("sync: command HTTP \(code); no local retry")
            return .rejected
        } catch {
            // The request may have reached the Worker even when the response
            // was lost. Retrying locally could duplicate next/previous or
            // toggle playback twice.
            DiagnosticsLog.append("sync: command result unknown; no local retry")
            return .indeterminate
        }
    }

    private func uploadCurrentTokens(force: Bool = false) async {
        // A push-to-start token must be accepted before the first activity
        // exists. Requiring an update token here made automatic start
        // impossible on a fresh installation.
        guard updateToken?.isEmpty == false || pushToStartToken?.isEmpty == false else { return }
        guard configuredBaseURL() != nil else {
            if force {
                DiagnosticsLog.append("sync: no valid HTTPS server URL set")
            }
            return
        }
        guard let refreshToken = KeychainStore.string(forKey: "refresh_token"), !refreshToken.isEmpty else {
            if force {
                DiagnosticsLog.append("sync: Spotify refresh token unavailable")
            }
            return
        }
        // The refresh token lets the sync server poll Spotify on our behalf —
        // that's the entire point of server push (app liveness becomes
        // irrelevant). Sent only over the configured HTTPS endpoint.
        let supportsRemoteStart: Bool
        if #available(iOS 17.2, *) {
            supportsRemoteStart = true
        } else {
            supportsRemoteStart = false
        }
        var body: [String: Any] = [
            "clientSchemaVersion": 2,
            "spotifyRefreshToken": refreshToken,
            "supportsRemoteStart": supportsRemoteStart,
            "supportsInputPushToken": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18,
            "lyricOffsetMs": lastLyricOffsetMs,
            "autoStartEnabled": UserDefaults.standard.object(forKey: "lockScreenLyricsEnabled") as? Bool ?? true,
        ]
        if let lastAlbumDominantRGB {
            body["albumDominantRGB"] = lastAlbumDominantRGB
        }
        if let updateToken, !updateToken.isEmpty { body["updateToken"] = updateToken }
        if let pushToStartToken, !pushToStartToken.isEmpty { body["pushToStartToken"] = pushToStartToken }

        if serverAuthTokenString.isEmpty {
            var bootstrapBody = body
            bootstrapBody["bootstrap"] = true
            guard let (_, bootstrapObject) = await sendRegistration(body: bootstrapBody),
                  let generatedToken = bootstrapObject["authToken"] as? String,
                  !generatedToken.isEmpty else {
                if force { DiagnosticsLog.append("sync: automatic server pairing failed") }
                return
            }
            KeychainStore.set(generatedToken, forKey: Self.authTokenKey)
            DiagnosticsLog.append("sync: server paired automatically")
        }

        guard !serverAuthTokenString.isEmpty else { return }
        let result = await sendRegistration(body: body, authToken: serverAuthTokenString)
        if let (code, object) = result, (200...299).contains(code) {
            applyServerState(object)
            DiagnosticsLog.append("sync: tokens registered (\(code))")
        } else if let code = result?.0 {
            DiagnosticsLog.append("sync: registration rejected HTTP \(code)")
        } else if force {
            DiagnosticsLog.append("sync: upload failed")
        }
    }

    private func sendRegistration(
        body: [String: Any],
        authToken: String? = nil
    ) async -> (Int, [String: Any])? {
        guard let url = URL(string: endpoint(path: "register")) else {
            DiagnosticsLog.append("sync: invalid server URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, object)
        } catch {
            DiagnosticsLog.append("sync: registration request failed")
            return nil
        }
    }

    private func configuredBaseURL() -> String? {
        let raw = serverURLString
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func endpoint(path: String) -> String {
        guard let base = configuredBaseURL() else { return path }
        return base.appending("/\(path)")
    }

    private func migrateLegacyServerSettings() {
        guard !UserDefaults.standard.bool(forKey: Self.managedServerMigrationKey) else { return }

        // Earlier beta builds stored a Worker URL and a shared access token.
        // The managed server now uses a built-in HTTPS endpoint and a private
        // per-install token. Clear only the old transport credentials once;
        // Spotify credentials remain untouched.
        UserDefaults.standard.set(Self.defaultServerURL, forKey: Self.urlKey)
        KeychainStore.set(nil, forKey: Self.authTokenKey)
        UserDefaults.standard.set(true, forKey: Self.managedServerMigrationKey)
        DiagnosticsLog.append("sync: migrated to managed server pairing")
    }

    private func applyServerState(_ object: [String: Any]) {
        if let dismissed = object["playbackSessionDismissed"] as? Bool {
            if !dismissed {
                serverSessionDismissed = false
                return
            }

            // Only an explicit phone heartbeat is proof that the user
            // dismissed the Activity. Older server builds also used this flag
            // for an expired APNs token, which could suppress all future local
            // starts even though the user did not dismiss anything.
            if object["dismissalSource"] as? String == "phone" {
                serverSessionDismissed = true
            } else {
                DiagnosticsLog.append("sync: ignored unverified dismissal state")
            }
        }
    }
}

enum SyncServerCheckResult: Equatable {
    case ready
    case missingURL
    case invalidURL
    case missingAccessToken
    case unauthorized
    case serverNotConfigured
    case failed
}

enum RemoteCommandResult: Equatable {
    case unavailable
    case accepted
    case rejected
    case indeterminate
}
