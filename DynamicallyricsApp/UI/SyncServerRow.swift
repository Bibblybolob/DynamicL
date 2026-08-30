import SwiftUI
import LyricCore

/// Managed sync status for the Live Activity push pipeline.
struct SyncServerRow: View {
    @State private var connectionCheck: ConnectionCheck = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Live sync server (push updates)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("The sync server is configured automatically after Spotify sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .disabled(connectionCheck == .checking)
                if let message = connectionCheck.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(connectionCheck.isSuccess ? .green : .secondary)
                }
            }
            ShareLink(item: DiagnosticsLog.shareURL) {
                Label("Share diagnostics", systemImage: "square.and.arrow.up")
            }
            .font(.caption.weight(.semibold))
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
        let hasAuth = !client.serverAuthTokenString.isEmpty
        let hasUpdateToken = client.updateToken != nil
        let hasStartToken = client.pushToStartToken != nil
        switch (hasAuth, hasUpdateToken, hasStartToken) {
        case (true, true, _): return "Registered. Phone fallback is ready."
        case (true, false, true): return "Ready. Automatic start is enabled."
        case (true, false, false): return "Waiting for an Activity token."
        default: return "Sign in to Spotify to enable automatic sync."
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
            case .result(.missingURL), .result(.invalidURL): "Sync server URL is invalid."
            case .result(.missingAccessToken): "Sign in to Spotify first."
            case .result(.unauthorized): "Automatic server pairing was rejected."
            case .result(.serverNotConfigured): "Sync server is not ready."
            case .result(.failed): "Could not reach the server."
            }
        }

        var isSuccess: Bool {
            self == .result(.ready)
        }
    }
}
