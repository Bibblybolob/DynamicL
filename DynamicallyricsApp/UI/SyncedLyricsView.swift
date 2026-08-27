import SwiftUI
import LyricCore

struct SyncedLyricsView: View {
    let document: LyricsDocument
    let currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 120).id("top-spacer")
                    ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(.title3, design: .rounded, weight: index == currentIndex ? .bold : .medium))
                            .foregroundStyle(index == currentIndex ? Color.pink : Color.primary.opacity(0.35))
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
}
