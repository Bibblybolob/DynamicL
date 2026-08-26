import Foundation

/// Uploads Live Activity push tokens to the user-configured sync server so a
/// server-side poller can push content-state updates over APNs.
///
/// Until a server URL is configured, tokens are only written to the
/// diagnostics log — enough to exercise the raw APNs pipeline manually
/// (curl + signed JWT) during bring-up.
@MainActor
final class SyncServerClient {
    static let shared = SyncServerClient()

    private static let urlKey = "syncServerURL"

    /// Most recent tokens seen; re-uploaded whenever the server URL changes.
    private(set) var updateToken: String?
    private(set) var pushToStartToken: String?

    private var pendingUploadTask: Task<Void, Never>?

    var serverURLString: String {
        UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
    }

    /// Debounced setter — the settings field calls this on every keystroke.
    func setServerURL(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = UserDefaults.standard.string(forKey: Self.urlKey)
        guard trimmed != stored else { return }
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.urlKey)
        DiagnosticsLog.append(trimmed.isEmpty ? "sync: server URL cleared" : "sync: server URL set")

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
            DiagnosticsLog.append("push update token: \(token)")
        }
        if let token = pushToStartToken, token != self.pushToStartToken {
            self.pushToStartToken = token
            DiagnosticsLog.append("push-to-start token: \(token)")
        }
        await uploadCurrentTokens()
    }

    private func uploadCurrentTokens(force: Bool = false) async {
        guard updateToken != nil || pushToStartToken != nil else { return }
        guard let base = configuredBaseURL() else {
            if force {
                DiagnosticsLog.append("sync: no server URL set; tokens logged only")
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "updateToken": updateToken ?? "",
            "pushToStartToken": pushToStartToken ?? "",
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
        guard !raw.isEmpty, raw.hasPrefix("http") else { return nil }
        return raw
    }
}
