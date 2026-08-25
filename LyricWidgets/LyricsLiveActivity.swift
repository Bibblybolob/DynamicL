import ActivityKit
import SwiftUI
import WidgetKit
import LyricCore

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(context: context)
                .activityBackgroundTint(.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.quarternote.3")
                        .font(.title3)
                        .foregroundStyle(.pink)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(context.state.isPlaying ? Color(red: 0.11, green: 0.86, blue: 0.36) : .secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if context.isStale {
                            Text("• • •")
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                        } else {
                            Text(context.state.currentLine)
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                        }
                        if let next = context.state.nextLine {
                            Text(next)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        LAProgressBar(state: context.state)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "music.quarternote.3")
                    .foregroundStyle(.pink)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(context.state.isPlaying ? Color(red: 0.11, green: 0.86, blue: 0.36) : .secondary)
            } minimal: {
                Image(systemName: "music.quarternote.3")
                    .foregroundStyle(.pink)
            }
        }
    }
}

private struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.caption2.bold())
                    .foregroundStyle(.pink)
                Text("\(context.state.trackTitle) — \(context.state.artistName)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                TogglePlaybackButton(isPlaying: context.state.isPlaying, font: .footnote)
                    .tint(.white)
            }

            Text(context.state.currentLine)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .opacity(context.isStale ? 0.35 : 1)

            LAProgressBar(state: context.state)

            if let next = context.state.nextLine {
                Text(next)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Self-advancing song progress: the system animates ProgressView(timerInterval:)
/// on its own clock between app updates — zero Live Activity update budget spent.
/// While paused, renders a static bar at the frozen fraction instead (an interval
/// would keep advancing after pause).
struct LAProgressBar: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let start = state.progressStart, let end = state.progressEnd, state.isPlaying {
            ProgressView(timerInterval: start...end, countsDown: false)
                .progressViewStyle(.linear)
                .tint(.pink)
                .frame(height: 4)
        } else if let frozen = state.frozenProgress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.pink)
                        .frame(width: geo.size.width * frozen)
                }
            }
            .frame(height: 4)
        } else {
            EmptyView()
        }
    }
}
