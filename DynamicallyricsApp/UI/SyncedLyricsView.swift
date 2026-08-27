import SwiftUI
import LyricCore

struct SyncedLyricsView: View {
    let document: LyricsDocument
    let currentIndex: Int?
    /// Playback position after applying the same user offset used by the
    /// sync engine. This drives the karaoke sweep without a second clock.
    let lyricPosition: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let karaokeEnabled = LAStyleStore.load().karaokeEnabled
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 120).id("top-spacer")
                    ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                        Group {
                            if index == currentIndex, karaokeEnabled {
                                KaraokeLyricText(
                                    text: line.text,
                                    progress: karaokeProgress(for: index),
                                    font: .system(.title3, design: .rounded, weight: .bold),
                                    baseColor: .pink.opacity(0.38),
                                    highlightColor: .pink,
                                    reduceMotion: reduceMotion
                                )
                            } else {
                                Text(line.text)
                                    .font(.system(.title3, design: .rounded, weight: .medium))
                                    .foregroundStyle(Color.primary.opacity(0.35))
                            }
                        }
                        // Keep the same sizing and alignment for both the
                        // highlighted and inactive render paths.
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(index == currentIndex ? 1.0 : 0.95, anchor: .leading)
                        .animation(.spring(duration: 0.3), value: currentIndex)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(index)
                    }
                    Color.clear.frame(height: 220).id("bottom-spacer")
                }
                .padding(.horizontal)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(duration: 0.4)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func karaokeProgress(for index: Int) -> Double {
        guard index == currentIndex,
              index < document.lines.count else { return 0 }

        let start = document.lines[index].time
        let following = index + 1 < document.lines.count
            ? document.lines[index + 1].time
            : start + 4
        let end = max(start + 0.25, following)
        return min(max((lyricPosition - start) / (end - start), 0), 1)
    }
}

/// A lightweight karaoke sweep for the main lyrics view. LRC currently gives
/// us line timestamps rather than word timestamps, so the highlight advances
/// proportionally across the line until the next timestamp.
private struct KaraokeLyricText: View {
    let text: String
    let progress: Double
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    let reduceMotion: Bool

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(baseColor)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(highlightColor)
                    .mask {
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(
                                    width: proxy.size.width * progress,
                                    height: proxy.size.height,
                                    alignment: .leading
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
            }
            .allowsTightening(true)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                reduceMotion ? nil : .linear(duration: 0.24),
                value: progress
            )
    }
}
