import SwiftUI

struct NowPlayingWatchView: View {
    let model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: model.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(model.isPlaying ? Color(red: 0.11, green: 0.86, blue: 0.36) : .secondary)
                        .font(.caption2)
                    Text(model.trackTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if model.hasContent {
                    Text(model.currentLine)
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    if !model.artistName.isEmpty {
                        Text(model.artistName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(.pink)
                        Text("Open OpenLyrics on your iPhone and start playing a song.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Lyrics")
    }
}

#Preview {
    NowPlayingWatchView(model: {
        let model = WatchModel()
        return model
    }())
}
