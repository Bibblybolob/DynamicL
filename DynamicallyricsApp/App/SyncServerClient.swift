import Foundation
import LyricCore

enum SyncActivityState: String {
    case active
    case none
    case dismissed
}

/// Uploads Live Activity push tokens to the user-configured sync server so a
/// server-side poller can push content-state updates over APNs.
///
/// The server URL and access token are configured independently so the token
/// never has to live in a URL or appear in normal diagnostics.
@MainActor
final class SyncServerClient {
    static let shared = SyncServerClient()

    private static let urlKey = "syncServerURL"
    private static let authTokenKey = "syncServerAuthToken"

    /// Most recent tokens seen; re-uploaded whenever the server URL changes.
    private(set) var updateToken: String?
    private(set) var pushToStartToken: String?
    private(set) var serverSessionDismissed = false

    private var pendingUploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastHeartbeatAt: Date?
    private var lastLyricOffsetMs = 0
    private var lastAlbumDominantRGB: [Double]?

    var serverURLString: String {
        UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
    }

    var serverAuthTokenString: String {
        KeychainStore.string(forKey: Self.authTokenKey) ?? ""
    }

    /// Debounced setter — the settings field calls this on every keystroke.
    func setServerURL(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        guard trimmed != stored else { return }
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.urlKey)
        DiagnosticsLog.append(trimmed.isEmpty ? "sync: server URL cleared" : "sync: server URL set")

        scheduleUpload()
    }

    func setServerAuthToken(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != serverAuthTokenString else { return }
        KeychainStore.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.authTokenKey)
        DiagnosticsLog.append(trimmed.isEmpty ? "sync: server access token cleared" : "sync: server access token set")
        scheduleUpload()
    }

    /// Verifies the configured Worker URL and access token without waiting for
    /// ActivityKit to produce a token or for a registration upload to happen.
    func checkConnection() async -> SyncServerCheckResult {
        guard configuredBaseURL() != nil else { return .missingURL }
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
    /// suspends the app, the server takes over after 15 seconds.
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
    /// authority when it is configured. `nil` means that local Spotify control
    /// must be used. A server response is idempotent by command ID.
    func sendCommand(_ command: PlaybackCommand, id: UUID) async -> Bool? {
        let serverCommand: String
        switch command {
        case .togglePlayPause: serverCommand = "toggle"
        case .next: serverCommand = "next"
        case .previous: serverCommand = "previous"
        case .refresh: return nil
        }
        guard configuredBaseURL() != nil, !serverAuthTokenString.isEmpty else { return nil }
        guard let url = URL(string: endpoint(path: "command")) else { return false }

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
                return true
            }
            DiagnosticsLog.append("sync: command HTTP \(code); using local control")
            return false
        } catch {
            DiagnosticsLog.append("sync: command failed; using local control")
            return false
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
        let authToken = serverAuthTokenString
        guard !authToken.isEmpty else {
            if force {
                DiagnosticsLog.append("sync: server access token unavailable")
            }
            return
        }
        guard let refreshToken = KeychainStore.string(forKey: "refresh_token"), !refreshToken.isEmpty else {
            if force {
                DiagnosticsLog.append("sync: Spotify refresh token unavailable")
            }
            return
        }
        guard let url = URL(string: endpoint(path: "register")) else {
            DiagnosticsLog.append("sync: invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        // The refresh token lets the sync server poll Spotify on our behalf —
        // that's the entire point of server push (app liveness becomes
        // irrelevant). Sent only over the user-configured HTTPS endpoint.
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    applyServerState(object)
                }
                DiagnosticsLog.append("sync: tokens registered (\(code))")
            } else {
                DiagnosticsLog.append("sync: registration rejected HTTP \(code)")
            }
        } catch {
            DiagnosticsLog.append("sync: upload failed \(error.localizedDescription)")
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

    private func applyServerState(_ object: [String: Any]) {
        if let dismissed = object["playbackSessionDismissed"] as? Bool {
            serverSessionDismissed = dismissed
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
