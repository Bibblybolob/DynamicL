import ActivityKit
import SwiftUI
import WidgetKit
import LyricCore

/// Resolved appearance (palette + font + motion prefs) for one render of the
/// Live Activity. Reads user style prefs from the shared app group so in-app
/// changes restyle a running activity on its very next render.
struct LALook {
    let palette: LAPalette
    let fontStyle: LAStylePrefs.FontStyle
    let animations: Bool

    var accent: Color { palette.accent.color }
    var text: Color { palette.text.color }

    init(state: LyricsActivityAttributes.ContentState) {
        let prefs = LAStyleStore.load()
        let dominant = state.albumDominantRGB.flatMap { rgb -> RGB? in
            guard rgb.count == 3 else { return nil }
            return RGB(r: rgb[0], g: rgb[1], b: rgb[2])
        }
        self.palette = LAStyleStore.resolve(prefs: prefs, albumDominant: dominant)
        self.fontStyle = prefs.fontStyle
        self.animations = prefs.animationsEnabled
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(context: context, look: LALook(state: context.state))
        } dynamicIsland: { context in
            island(context: context, look: LALook(state: context.state))
        }
    }

    private func island(context: ActivityViewContext<LyricsActivityAttributes>,
                        look: LALook) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: "music.quarternote.3")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(look.accent)
                    .padding(.leading, 4)
            }
            DynamicIslandExpandedRegion(.trailing) {
                if context.state.isPlaying {
                    let motion = look.animations ? Symbols.SymbolEffectOptions.repeating : Symbols.SymbolEffectOptions.nonRepeating
                    Image(systemName: "waveform")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(look.accent)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                                      options: motion,
                                      isActive: true)
                        .padding(.trailing, 4)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(look.text.opacity(0.45))
                        .padding(.trailing, 4)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        if context.state.isPlaying {
                            LAPulseDot(color: look.accent, animate: look.animations)
                        }
                        Text("\(context.state.trackTitle) — \(context.state.artistName)")
                            .font(look.fontStyle.laFont(.caption2, weight: .semibold))
                            .foregroundStyle(look.text.opacity(0.7))
                            .lineLimit(1)
                    }
                    Text(context.state.currentLine)
                        .font(look.fontStyle.laFont(.headline, weight: .bold))
                        .foregroundStyle(look.text)
                        .opacity(context.isStale ? 0.35 : 1)
                        .lineLimit(2)
                    if let next = context.state.nextLine {
                        Text(next)
                            .font(look.fontStyle.laFont(.footnote))
                            .foregroundStyle(look.text.opacity(0.45))
                            .lineLimit(1)
                    }
                    LAThickBar(
                        start: context.state.progressStart,
                        end: context.state.progressEnd,
                        frozen: context.state.frozenProgress,
                        accent: look.accent,
                        track: look.text.opacity(0.22)
                    )
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } compactLeading: {
            Image(systemName: "music.quarternote.3")
                .foregroundStyle(look.accent)
        } compactTrailing: {
            if context.state.isPlaying {
                let motion = look.animations ? Symbols.SymbolEffectOptions.repeating : Symbols.SymbolEffectOptions.nonRepeating
                Image(systemName: "waveform")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(look.accent)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                                  options: motion,
                                  isActive: true)
            } else {
                Image(systemName: "pause.fill")
                    .foregroundStyle(look.text.opacity(0.45))
            }
        } minimal: {
            Image(systemName: "music.quarternote.3")
                .foregroundStyle(look.accent)
        }
    }
}

/// Order-tracking-style lock-screen card: full-bleed theme gradient, huge
/// lyric hero type, animated progress capsule, pill transport control.
private struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>
    let look: LALook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.caption2.bold())
                    .foregroundStyle(look.accent)
                if context.state.isPlaying {
                    LAPulseDot(color: look.accent, animate: look.animations)
                }
                Text("\(context.state.trackTitle) — \(context.state.artistName)")
                    .font(look.fontStyle.laFont(.caption2, weight: .semibold))
                    .foregroundStyle(look.text.opacity(0.78))
                    .lineLimit(1)
                Spacer()
                // Stall-reveal refresh: only exists once content has gone
                // stale (system-computed), so healthy cards stay clean.
                // Oversized hit area — sub-44pt targets silently swallow taps.
                if context.isStale {
                    Button(intent: RefreshLyricsActivityIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.bold())
                            .foregroundStyle(look.accent)
                            .padding(6)
                            .background(Circle().fill(look.text.opacity(0.18)))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Circle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                }
                TogglePlaybackButton(isPlaying: context.state.isPlaying, font: .footnote)
                    .tint(look.text)
            }

            LAMarquee(
                text: context.state.currentLine,
                font: look.fontStyle.laFont(fixedSize: 25, weight: .heavy),
                color: look.text.opacity(context.isStale ? 0.35 : 1),
                animations: look.animations && !context.isStale,
                pointSize: 25
            )
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)

            LAThickBar(
                start: context.state.progressStart,
                end: context.state.progressEnd,
                frozen: context.state.frozenProgress,
                accent: look.accent,
                track: look.text.opacity(0.25)
            )

            if let next = context.state.nextLine {
                Text(next)
                    .font(look.fontStyle.laFont(.subheadline, weight: .medium))
                    .foregroundStyle(look.text.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // Inner two-tone depth within the card (the tint below is flat).
            LinearGradient(
                colors: [look.palette.backgroundTop.color, look.palette.backgroundBottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // The API that actually colors the card on-device; containerBackground
        // alone is ignored by Live Activities on current iOS builds.
        .activityBackgroundTint(look.palette.backgroundTop.color)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [look.palette.backgroundTop.color, look.palette.backgroundBottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
