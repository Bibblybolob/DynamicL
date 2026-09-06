# OpenLyrics 1.2.0 (55): customizable lyric widgets

This is the first widget-focused release: Minimal, Lyrics Focus and Lyric Stack,
with independently configured Home Screen and Lock Screen widgets. Now Playing,
Album Art, and the richer Compact preset remain follow-up work.

## Behavior

- The app opens a widget gallery and visual design editor from Customize Widgets.
- Designs control fonts, bounded size, weight, alignment, lyric context and its
  opacity, title/artist visibility, highlight corners, colors, and system, solid,
  gradient or album-derived backgrounds.
- Each new widget selects a preset or saved design using App Intents. Text size
  can override the design for that widget. Widgets using the same saved design
  intentionally share edits; Duplicate Design creates an independent identity.
- Preview edits remain local until Save. Unchanged saves do not request reloads;
  changed saves reload the two new widget kinds once each.
- All existing widget identifiers and Live Activity preferences remain intact.
- The new provider uses the same synchronous timeline builder as Current Line:
  lyric boundaries, optimistic pause, expiration and track-end behavior remain.
- Optional previous/next text is published from the trusted lyric engine and
  retained in both snapshot representations. Missing legacy context is omitted.
- Appearance uses a separate app-group catalog and never changes playback
  revisions, Spotify requests, lyric timing, or Live Activity ownership.
- Rectangular/inline Lock Screen designs prioritize readable current text;
  circular widgets show playback status. Tinted/background-removed appearances
  use system foreground colors. No continuous animation is promised.

## Validation

- LyricCore: 100 XCTest tests and 38 Swift Testing tests passed. Five new tests
  cover independent designs and duplicate/no-op saves, bounded appearance values,
  six minutes of context projection, paused/resumed schedules, seek/track ordering,
  and legacy/V2 snapshot compatibility.
- Generic iOS Dynamicallyrics build passed, including embedded Watch targets.
- Release archive and iOS simulator build passed. All four embedded bundles report
  1.2.0 (55); strict deep code-signature verification passed.
- App Store Connect accepted the upload on September 5, 2026. Xcode reported
  EXPORT SUCCEEDED. App Store Connect reports build 55 as VALID, verified
  September 6, 2026.
- No server implementation or deployment is part of this widget release. The
  checkout already contained Spotify request-safety work; it was preserved.

## Device validation still required

The Mac was locked during interactive validation and both paired iPhones were
unavailable. Test adding two differently configured widgets, selecting saved
designs, changing one design, duplicating a shared design, app-upgrade preservation,
all supported families, tinted/glass appearances, long/RTL lyrics and custom-font
fallback, six minutes of playback without manual refresh, and pause/seek/track
transitions. Confirm Live Activity and Watch remain functional. Passing model
tests does not establish WidgetKit's real-device display cadence.
