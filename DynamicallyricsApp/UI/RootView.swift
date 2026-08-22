import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.pink.gradient)

                VStack(spacing: 8) {
                    Text("Dynamicallyrics")
                        .font(.title2.bold())
                    Text("No music detected yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    statusRow(icon: "apple.logo", label: "Apple Music", detail: "Coming in Phase 1")
                    statusRow(icon: "circle.grid.cross", label: "Spotify", detail: "Coming in Phase 6")
                    statusRow(icon: "lock.iphone", label: "Lock Screen lyrics", detail: "Coming in Phase 4")
                    statusRow(icon: "square.grid.2x2", label: "Widgets & StandBy", detail: "Coming in Phase 5")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Now Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private func statusRow(icon: String, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.pink)
            Text(label)
                .font(.body.weight(.medium))
            Spacer()
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    RootView()
}
