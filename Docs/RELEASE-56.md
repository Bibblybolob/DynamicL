# OpenLyrics 1.2.0 (56): Widget Studio

Status: uploaded to TestFlight. App Store Connect reports **VALID**, verified
September 6, 2026. Build ID: `48640d57-75b2-4190-8007-d72989e99b14`.
Implementation commit: `35935a7`, pushed to `main`.

## Delivered

- Dedicated versioned WidgetStylePrefs; frozen palette values, stable catalog
  IDs, reusable background/typography/artwork primitives and a pure family resolver.
- Fifty authored palettes with complete semantic color roles. All three static
  gradient stops pass a 4.5:1 contrast check against the primary lyric color.
- Fifteen template compositions and family-specific compact adaptations.
- Widget Studio preset browsing, theme search/categories, favorites, saved designs,
  duplication, legacy-style import, sectioned advanced controls and shared renderer
  previews for all six configurable widget families.
- Twelve custom color roles and reusable named palettes; independent per-widget
  App Intent overrides for template, palette, surface, font, size, artwork and density.
- Four additional font families (978,740 bytes per app/extension copy), pinned
  source hashes and bundled OFL notices, including notices for existing families.
- Optional album name and frozen playback position in both widget snapshot formats.
  These come from existing phone state. Older snapshots decode without the fields.
- Native bounded progress/time views use the established playback anchors.
  Paused and optimistic-pause presentations use frozen progress. There are no new
  timeline boundaries, Spotify requests, per-line pushes or style-triggered lyric fetches.

## Compatibility

Live Activity preferences, the scroller, the established timeline builder,
phone/server ownership, APNs payloads, Watch appearance and existing widget kinds
retain their behavior. This work adds no server changes.

Build-55 design IDs, names, revisions and legacy intent values remain supported.
The original v1 catalog is retained. Readers skip unsupported records independently;
saving another design preserves those records. Catalogs are bounded and replaced
as a single value. Palette editing remains local to a design unless explicitly
saved as a reusable palette. Appearance revisions are unrelated to playback revisions.

The checkout already contained the shipped Apple playback/widget foundation from
prior tasks. The release source commit includes those Apple prerequisites so the
repository can reproduce the beta; unrelated server edits remain outside this release.

## Validation

- LyricCore: 107 XCTest cases and 38 Swift Testing cases pass (145 total).
- New regression coverage: catalog IDs/roles/contrast, legacy migration and rollback,
  unknown/unsupported records, default decoding, independent designs/custom palettes,
  six-minute progression without publication, unchanged boundary dates, Unix progress
  anchors, frozen pauses and optional metadata across both snapshot formats.
- Existing timing tests cover seeks, pause/resume, track changes and old revisions.
- Dynamicallyrics generic iOS build succeeds, including embedded Watch targets.
- Off-screen SwiftUI renders reviewed for all 15 templates at Small and Medium;
  corrected artwork clipping and lyric compression found during that review.
- Release archive succeeds; deep/strict signature validation passes. All four
  Apple bundles report 1.2.0 (56); the app includes 14 font files and ten license notices.
- Server tests not rerun: this change does not modify server behavior.

## Remaining device validation and scoped follow-ups

The Mac was locked, preventing interactive simulator checks. Off-screen rendering
is not a WidgetKit-host test. Validate an installed build-55 upgrade, two independent
widgets and two linked widgets, all widget sizes, long/RTL/CJK lyrics, accessibility
sizes/contrast, real album art, system tint/background removal, and extension memory.
Exercise native timers/progress, pause/resume, seek, track changes, and several
minutes locked without updates. WidgetKit still controls when timelines appear.
Live Activity/APNs background behavior remains subject to the existing device tests.

Dynamic palettes currently derive from the cached dominant album hue, with controlled
light accents and a dark scrim. Multi-hue artwork sampling and larger/cached blur
variants remain follow-ups. Background image blur is bounded and uses existing
small artwork; large/full-bleed sharpness and host memory need device measurement.
Frosted/glass are panels over widget content, not wallpaper blur. Glow is a static
radial composition; mesh shaders, animated effects and text strokes are not enabled.

Explicit-content badges are not exposed because the current accepted snapshot does
not carry that metadata. Advanced design archive/delete management remains a follow-up;
existing designs can be edited or duplicated. Actual system tint and font/glyph
fallbacks must be checked on iPhone. Native font weights depend on the bundled faces.
