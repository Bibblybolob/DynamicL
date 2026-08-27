import Foundation

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

    private var pendingUploadTask: Task<Void, Never>?

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

    private func uploadCurrentTokens(force: Bool = false) async {
        // The current worker updates an existing activity. A push-to-start
        // token alone cannot be registered until an update token exists.
        guard let updateToken, !updateToken.isEmpty else { return }
        guard let base = configuredBaseURL() else {
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
        let registerURL = base.hasSuffix("/") ? base.appending("register") : base.appending("/register")
        guard let url = URL(string: registerURL) else {
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "updateToken": updateToken,
            "pushToStartToken": pushToStartToken ?? "",
            "spotifyRefreshToken": refreshToken,
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) {
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
}
