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
    /// An explicit Start or Restart action supersedes a dismissal stored by an
    /// older server session. Registration and heartbeat requests can overlap,
    /// so ignore that old value until the server acknowledges the reset. A
    /// later ActivityKit dismissal clears this guard and remains authoritative.
    private var dismissalResetPending = false

    private var pendingUploadTask: Task<Void, Never>?
    /// Registration can be triggered by the global push-to-start stream, an
    /// activity update-token stream, Spotify sign-in, and the heartbeat path at
    /// nearly the same time. Keep bootstrap registration single-flight. Two
    /// concurrent bootstrap requests can make the server reject the second
    /// pairing and leave one of the tokens unregistered.
    private var uploadInFlight = false
    private var uploadQueued = false
    private var queuedUploadIsForced = false
    private var heartbeatTask: Task<Void, Never>?
    private var lastHeartbeatAt: Date?
    private var lastLyricOffsetMs = 0
    private var lastAlbumDominantRGB: [Double]?
    private var pendingActivityEnd = false
    /// Keep the ended Activity token for one explicit end heartbeat. The
    /// current token is cleared immediately so later updates cannot target a
    /// dead Activity, but the server still needs the old token to remove its
    /// APNs route when no push-to-start token is available.
    private var activityEndToken: String?
    private var activityEndGeneration: UInt64 = 0
    /// Kept for compatibility with older registrations. New installations use
    /// one-time automatic-lyrics consent and never receive a per-session gate.
    private var requiresUserStart = false

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
        // Re-register on every manual check. This also repairs a token that
        // became invalid after a server migration or key rotation.
        await uploadCurrentTokens(force: true)
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
        var changed = false
        if let token = updateToken, token != self.updateToken {
            self.updateToken = token
            changed = true
            // A new Activity token supersedes any end notification queued for
            // the previous Activity. Keeping the old marker could send an
            // unnecessary none heartbeat with a dead token after a fresh
            // Activity has already started.
            if pendingActivityEnd {
                pendingActivityEnd = false
                activityEndToken = nil
            }
            DiagnosticsLog.append("push update token received (\(token.count) hex chars)")
        }
        if let token = pushToStartToken, token != self.pushToStartToken {
            self.pushToStartToken = token
            changed = true
            DiagnosticsLog.append("push-to-start token received (\(token.count) hex chars)")
        }
        if changed {
            await uploadCurrentTokens()
        }
    }

    /// Removes an update token that belongs to an ended activity. The global
    /// push-to-start token remains registered for the next playback session.
    func noteActivityEnded(dismissed: Bool) {
        if let updateToken, !updateToken.isEmpty {
            activityEndToken = updateToken
        }
        updateToken = nil
        if dismissed {
            dismissalResetPending = false
            serverSessionDismissed = true
        }
        pendingActivityEnd = true
        activityEndGeneration &+= 1
        lastHeartbeatAt = .distantPast
        DiagnosticsLog.append(dismissed ? "sync: activity dismissed" : "sync: activity ended")
    }

    func resetDismissalForNewSession() {
        // Make repeated reset requests idempotent. Only the first request in a
        // recovery cycle can bypass the normal five-second heartbeat limit.
        // The server response clears dismissalResetPending and arms the next
        // legitimate playback-session reset.
        let needsImmediateHeartbeat = serverSessionDismissed || !dismissalResetPending
        serverSessionDismissed = false
        dismissalResetPending = true
        if needsImmediateHeartbeat {
            lastHeartbeatAt = .distantPast
        }
    }

    func markFirstUseCompleted() {
        requiresUserStart = false
        // Do not wait for the next five-second heartbeat. The first-use tap
        // changes which side owns the activity, so the server must learn the
        // new gate promptly before its fallback poll can publish a placeholder.
        scheduleUpload()
    }

    func resetFirstUseGate() {
        requiresUserStart = false
        SharedNowPlaying.resetLiveActivityFirstUse()
    }

    /// Makes the next heartbeat announce a local ownership change immediately.
    /// This is used after the user presses Show Lyrics. Without the barrier,
    /// the server may still believe it owns the activity for up to five
    /// seconds and can deliver an older fallback state over the fresh phone
    /// state.
    func requestImmediateHeartbeat() {
        lastHeartbeatAt = .distantPast
    }

    /// Wakes the background worker for a Shortcut or automatic Spotify start.
    /// The endpoint is idempotent and does not send a second playback command.
    func wake(reason: String = "shortcut") {
        guard configuredBaseURL() != nil, !serverAuthTokenString.isEmpty,
              let url = URL(string: endpoint(path: "wake")) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(serverAuthTokenString)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        Task { [weak self] in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                DiagnosticsLog.append("sync: wake HTTP \(code)")
            } catch {
                DiagnosticsLog.append("sync: wake failed")
                self?.requestImmediateHeartbeat()
            }
        }
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
        requiresUserStart: Bool = false,
        force: Bool = false
    ) {
        // An explicit local end or dismissal must still reach the server during
        // a Spotify or network failure. Without this exception, disabling Live
        // Activity while the poller is unhealthy leaves the server's APNs route
        // alive until its lease expires, which can keep a stale card on screen.
        // The pending flag is cleared after one accepted heartbeat below.
        guard healthy || pendingActivityEnd else { return }
        lastLyricOffsetMs = Int((lyricOffset * 1_000).rounded())
        lastAlbumDominantRGB = albumDominantRGB
        self.requiresUserStart = requiresUserStart
        let now = Date.now
        guard force || now.timeIntervalSince(lastHeartbeatAt ?? .distantPast) >= 5 else { return }
        guard heartbeatTask == nil else { return }
        guard configuredBaseURL() != nil, !serverAuthTokenString.isEmpty else { return }
        guard updateToken?.isEmpty == false
                || pushToStartToken?.isEmpty == false
                || pendingActivityEnd else { return }
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
                "requiresUserStart": self.requiresUserStart,
            ]
            let pendingGeneration = self.pendingActivityEnd
                ? self.activityEndGeneration
                : nil
            if activityState == .none, pendingGeneration != nil {
                // A plain `none` can mean that the app has not adopted a
                // remotely started activity yet. This flag identifies the
                // separate explicit local end that may remove the server's
                // valid update token.
                body["activityEnded"] = true
            }
            if let albumDominantRGB = self.lastAlbumDominantRGB {
                body["albumDominantRGB"] = albumDominantRGB
            }
            if let updateToken = self.updateToken { body["updateToken"] = updateToken }
            else if activityState == .none, let activityEndToken = self.activityEndToken {
                body["updateToken"] = activityEndToken
            }
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
                    if let pendingGeneration,
                       self.pendingActivityEnd,
                       self.activityEndGeneration == pendingGeneration,
                       object["accepted"] as? Bool != false {
                        self.pendingActivityEnd = false
                        self.activityEndToken = nil
                    }
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
        if uploadInFlight {
            uploadQueued = true
            queuedUploadIsForced = queuedUploadIsForced || force
            return
        }
        uploadInFlight = true
        defer {
            uploadInFlight = false
            if uploadQueued {
                let nextForce = queuedUploadIsForced
                uploadQueued = false
                queuedUploadIsForced = false
                Task { [weak self] in
                    await self?.uploadCurrentTokens(force: nextForce)
                }
            }
        }
        await performUploadCurrentTokens(force: force)
    }

    private func performUploadCurrentTokens(force: Bool) async {
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
            // The private-beta server must use the same Spotify application
            // that completed PKCE on this device. This is public OAuth
            // metadata, not a credential.
            "spotifyClientID": SpotifyConfig.clientID,
            "spotifyRefreshToken": refreshToken,
            "supportsRemoteStart": supportsRemoteStart,
            // Push-to-start is available from iOS 17.2. The input-push-token
            // option is only available from iOS 18, so do not ask APNs for
            // that newer handoff on iOS 17.2–17.x. Those devices still wake
            // the app and provide the normal Activity update token.
            "supportsInputPushToken": {
                if #available(iOS 18.0, *) { return true }
                return false
            }(),
            "lyricOffsetMs": lastLyricOffsetMs,
            "autoStartEnabled": UserDefaults.standard.object(forKey: "lockScreenLyricsEnabled") as? Bool ?? true,
            "requiresUserStart": requiresUserStart,
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

        guard let authToken = KeychainStore.string(forKey: Self.authTokenKey), !authToken.isEmpty else { return }
        var result = await sendRegistration(body: body, authToken: authToken)
        if result?.0 == 401 {
            // The server token is installation-specific. It can become stale
            // after a backend migration or a server-side key rotation. Do not
            // make the user reinstall the app or disconnect Spotify: clear
            // only the rejected server token, bootstrap a new pairing, and
            // retry this same registration once.
            KeychainStore.set(nil, forKey: Self.authTokenKey)
            DiagnosticsLog.append("sync: server token rejected; renewing pairing")
            var bootstrapBody = body
            bootstrapBody["bootstrap"] = true
            guard let (_, bootstrapObject) = await sendRegistration(body: bootstrapBody),
                  let generatedToken = bootstrapObject["authToken"] as? String,
                  !generatedToken.isEmpty else {
                if force { DiagnosticsLog.append("sync: renewed pairing failed") }
                return
            }
            KeychainStore.set(generatedToken, forKey: Self.authTokenKey)
            result = await sendRegistration(body: body, authToken: generatedToken)
        }
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
        return base.appending("/v1/\(path)")
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
                dismissalResetPending = false
                return
            }

            // A direct Start or Restart action has already created a newer
            // local session. A registration or heartbeat for the prior token
            // can finish later and return its obsolete dismissal bit. Do not
            // let that response end the replacement Activity one second after
            // it starts.
            if dismissalResetPending {
                DiagnosticsLog.append("sync: ignored dismissal from pre-recovery session")
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
