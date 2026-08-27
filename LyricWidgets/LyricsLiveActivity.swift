import ActivityKit
import SwiftUI
import WidgetKit
import LyricCore

/// Resolved appearance (palette + font + motion prefs) for one render of the
/// Live Activity. Reads user style prefs from the shared app group so in-app
/// changes restyle a running activity on its very next render.
struct LALook {
    let palette: LAPalette
    let layout: LAStylePrefs.Layout
    let artworkStyle: LAStylePrefs.ArtworkStyle
    let textAlignment: LAStylePrefs.TextAlignment
    let fontStyle: LAStylePrefs.FontStyle
    let lyricScale: LAStylePrefs.LyricScale
    let showTrackInfo: Bool
    let showControls: Bool
    let showNextLine: Bool
    let showProgressBar: Bool
    let animations: Bool
    let karaokeEnabled: Bool

    var accent: Color { palette.accent.color }
    var text: Color { palette.text.color }
    var showsArtwork: Bool {
        layout == .player && artworkStyle != .hidden
    }
    var showsTrackHeader: Bool {
        layout != .minimal && showTrackInfo
    }
    var showsTransport: Bool {
        layout != .minimal && showControls
    }

    init(state: LyricsActivityAttributes.ContentState) {
        let prefs = LAStyleStore.load()
        let dominant = state.albumDominantRGB.flatMap { rgb -> RGB? in
            guard rgb.count == 3 else { return nil }
            return RGB(r: rgb[0], g: rgb[1], b: rgb[2])
        }
        self.palette = LAStyleStore.resolve(prefs: prefs, albumDominant: dominant)
        self.layout = prefs.layout
        self.artworkStyle = prefs.artworkStyle
        self.textAlignment = prefs.textAlignment
        self.fontStyle = prefs.fontStyle
        self.lyricScale = prefs.lyricScale
        self.showTrackInfo = prefs.showTrackInfo
        self.showControls = prefs.showControls
        self.showNextLine = prefs.showNextLine
        self.showProgressBar = prefs.showProgressBar
        self.animations = prefs.animationsEnabled
        self.karaokeEnabled = prefs.karaokeEnabled
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
        let scheduledLines = context.state.scheduledLines ?? []
        return DynamicIsland {
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
                    if look.showsTrackHeader {
                        HStack(spacing: 5) {
                            if context.state.isPlaying {
                                LAPulseDot(color: look.accent, animate: look.animations)
                            }
                            Text("\(context.state.trackTitle) — \(context.state.artistName)")
                                .font(look.fontStyle.laFont(.caption2, weight: .semibold))
                                .foregroundStyle(look.text.opacity(0.7))
                                .lineLimit(1)
                                .allowsTightening(true)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity,
                                       alignment: look.textAlignment.alignment)
                        }
                    }
                    LAScheduledLyricText(
                        currentLine: context.state.currentLine,
                        nextLine: context.state.nextLine,
                        scheduledLines: scheduledLines,
                        role: .current,
                        font: look.fontStyle.laFont(
                            fixedSize: CGFloat(look.lyricScale.pointSize),
                            weight: .bold
                        ),
                        color: look.text.opacity(context.isStale ? 0.35 : 1),
                        animations: look.animations && !context.isStale,
                        pointSize: CGFloat(look.lyricScale.pointSize),
                        minScale: CGFloat(look.lyricScale.minimumScale),
                        lineHeight: CGFloat(look.lyricScale.totalHeight),
                        maxLines: look.lyricScale.maximumLines,
                        textAlignment: look.textAlignment == .center ? .center : .leading,
                        karaokeEnabled: look.karaokeEnabled,
                        karaokeStartDate: context.state.karaokeStartDate,
                        karaokeEndDate: context.state.karaokeEndDate,
                        frozenKaraokeProgress: context.state.frozenKaraokeProgress,
                        highlightColor: look.accent
                    )
                    if look.showNextLine, look.layout != .minimal,
                       let next = context.state.nextLine {
                        LAScheduledLyricText(
                            currentLine: context.state.currentLine,
                            nextLine: next,
                            scheduledLines: scheduledLines,
                            role: .next,
                            font: look.fontStyle.laFont(.footnote),
                            color: look.text.opacity(0.45),
                            animations: look.animations,
                            lineHeight: 20,
                            maxLines: 1,
                            textAlignment: look.textAlignment == .center ? .center : .leading
                        )
                    }
                    if look.showProgressBar, look.layout != .minimal {
                        LAThickBar(
                            start: context.state.progressStart,
                            end: context.state.progressEnd,
                            frozen: context.state.frozenProgress,
                            accent: look.accent,
                            track: look.text.opacity(0.22)
                        )
                    }
                    if look.showsTransport {
                        HStack(spacing: 0) {
                            SkipTrackButton(direction: .previous, font: .caption2)
                            TogglePlaybackButton(isPlaying: context.state.isPlaying, font: .caption2)
                                .tint(look.text)
                            SkipTrackButton(direction: .next, font: .caption2)
                        }
                        .foregroundStyle(look.text)
                        .frame(maxWidth: .infinity,
                               alignment: look.textAlignment.alignment)
                    }
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
        let scheduledLines = context.state.scheduledLines ?? []
        Group {
            if look.showsArtwork {
                HStack(alignment: .center, spacing: 14) {
                    miniPlayerDetails(scheduledLines: scheduledLines)
                    Spacer(minLength: 0)
                    LAAlbumDisc(
                        urlString: context.state.albumImageURL,
                        size: 88,
                        imageData: SharedNowPlaying.cachedArtwork(for: context.state.albumImageURL),
                        style: look.artworkStyle
                    )
                }
            } else {
                miniPlayerDetails(scheduledLines: scheduledLines)
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

    @ViewBuilder
    private func miniPlayerDetails(
        scheduledLines: [WidgetLyricSnapshot.ScheduledLine]
    ) -> some View {
        VStack(alignment: look.textAlignment.horizontal, spacing: 6) {
            if look.showsTrackHeader {
                HStack(spacing: 5) {
                    if context.state.isPlaying {
                        LAPulseDot(color: look.accent, animate: look.animations)
                    }
                    VStack(alignment: look.textAlignment.horizontal, spacing: 1) {
                        Text(context.state.trackTitle)
                            .font(look.fontStyle.laFont(.caption2, weight: .semibold))
                            .foregroundStyle(look.text.opacity(0.84))
                            .lineLimit(1)
                        Text(context.state.artistName)
                            .font(look.fontStyle.laFont(.caption2))
                            .foregroundStyle(look.text.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if context.isStale {
                        Button(intent: RefreshLyricsActivityIntent()) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.bold())
                                .foregroundStyle(look.accent)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            LAScheduledLyricText(
                currentLine: context.state.currentLine,
                nextLine: context.state.nextLine,
                scheduledLines: scheduledLines,
                role: .current,
                font: look.fontStyle.laFont(
                    fixedSize: CGFloat(min(look.lyricScale.pointSize, 22)),
                    weight: .heavy
                ),
                color: look.text.opacity(context.isStale ? 0.35 : 1),
                animations: look.animations && !context.isStale,
                pointSize: CGFloat(min(look.lyricScale.pointSize, 22)),
                minScale: CGFloat(look.lyricScale.minimumScale),
                lineHeight: 48,
                maxLines: 2,
                textAlignment: look.textAlignment == .center ? .center : .leading,
                karaokeEnabled: look.karaokeEnabled,
                karaokeStartDate: context.state.karaokeStartDate,
                karaokeEndDate: context.state.karaokeEndDate,
                frozenKaraokeProgress: context.state.frozenKaraokeProgress,
                highlightColor: look.accent
            )

            if look.showsTransport {
                HStack(spacing: 0) {
                    SkipTrackButton(direction: .previous, font: .caption)
                    TogglePlaybackButton(isPlaying: context.state.isPlaying, font: .caption)
                        .tint(look.text)
                    SkipTrackButton(direction: .next, font: .caption)
                }
                .foregroundStyle(look.text)
                .frame(maxWidth: .infinity, alignment: look.textAlignment.alignment)
                .frame(height: 30)
            }

            if look.showProgressBar, look.layout != .minimal {
                LAThickBar(
                    start: context.state.progressStart,
                    end: context.state.progressEnd,
                    frozen: context.state.frozenProgress,
                    accent: look.accent,
                    track: look.text.opacity(0.25)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
