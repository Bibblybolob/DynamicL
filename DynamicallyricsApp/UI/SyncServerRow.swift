import SwiftUI
import LyricCore

/// Server URL field for the Live Activity push pipeline. Tokens stream in
/// automatically once this is set; leave empty to run purely local.
struct SyncServerRow: View {
    @State private var url: String = SyncServerClient.shared.serverURLString
    @State private var authToken: String = SyncServerClient.shared.serverAuthTokenString
    @State private var connectionCheck: ConnectionCheck = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Live sync server (push updates)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("https://your-worker.workers.dev", text: $url)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onChange(of: url) { _, newValue in
                    SyncServerClient.shared.setServerURL(newValue)
                    connectionCheck = .idle
                }
            SecureField("Server access token", text: $authToken)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onChange(of: authToken) { _, newValue in
                    SyncServerClient.shared.setServerAuthToken(newValue)
                    connectionCheck = .idle
                }
            HStack(spacing: 8) {
                Button {
                    Task {
                        connectionCheck = .checking
                        let result = await SyncServerClient.shared.checkConnection()
                        connectionCheck = .result(result)
                    }
                } label: {
                    if connectionCheck == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check connection", systemImage: "checkmark.shield")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || connectionCheck == .checking)
                if let message = connectionCheck.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(connectionCheck.isSuccess ? .green : .secondary)
                }
            }
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .task {
            // Surface already-known tokens when the view appears.
            let client = SyncServerClient.shared
            await client.record(
                updateToken: client.updateToken,
                pushToStartToken: client.pushToStartToken
            )
        }
    }

    private var statusText: String {
        let client = SyncServerClient.shared
        let hasURL = !client.serverURLString.isEmpty
        let hasAuth = !client.serverAuthTokenString.isEmpty
        let tokensKnown = client.updateToken != nil
        switch (hasURL, hasAuth, tokensKnown) {
        case (true, true, true): return "Registered — server pushes enabled."
        case (true, true, false): return "Waiting for an activity to start…"
        case (true, false, _): return "Add the server access token to enable push."
        case (false, _, true): return "Tokens captured locally; add the server URL."
        default: return "Optional — enables never-stall push updates."
        }
    }

    private enum ConnectionCheck: Equatable {
        case idle
        case checking
        case result(SyncServerCheckResult)

        var message: String? {
            switch self {
            case .idle, .checking: nil
            case .result(.ready): "Server reachable."
            case .result(.missingURL), .result(.invalidURL): "Enter a valid HTTPS URL."
            case .result(.missingAccessToken): "Add the access token."
            case .result(.unauthorized): "Access token rejected."
            case .result(.serverNotConfigured): "Worker token is not configured."
            case .result(.failed): "Could not reach the server."
            }
        }

        var isSuccess: Bool {
            self == .result(.ready)
        }
    }
}
