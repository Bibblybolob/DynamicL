import SwiftUI
import LyricCore

/// Server URL field for the Live Activity push pipeline. Tokens stream in
/// automatically once this is set; leave empty to run purely local.
struct SyncServerRow: View {
    @State private var url: String = SyncServerClient.shared.serverURLString
    @State private var tokenCount: Int = 0

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
        let hasURL = !SyncServerClient.shared.serverURLString.isEmpty
        let tokensKnown = SyncServerClient.shared.updateToken != nil
        switch (hasURL, tokensKnown) {
        case (true, true): return "Registered — server pushes enabled."
        case (true, false): return "Waiting for an activity to start…"
        case (false, true): return "Tokens captured locally; add a URL to enable server push."
        default: return "Optional — enables never-stall push updates."
        }
    }
}
