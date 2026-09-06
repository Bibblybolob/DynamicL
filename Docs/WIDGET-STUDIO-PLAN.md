# Widget Studio architecture proposal

Status: implementation delivered for build 56 on September 6, 2026. This document
preserves the architecture proposal; [RELEASE-56.md](RELEASE-56.md) records the
actual implemented scope, validation and remaining follow-ups. Some proposed
refinements (multi-hue extraction, cached artwork variants and archive management)
remain follow-up work. Playback timing and Live Activity ownership are preserved.

## 1. Current architecture

There are two appearance systems:

- `LAStylePrefs` has 16 themes, three layouts, three artwork treatments, five
  surfaces, ten font choices, and shared visibility/motion preferences. Its
  `laStylePrefs` app-group record is consumed by Live Activity and 13 legacy
  iOS widget kinds. The in-app scroller also reads its karaoke preference.
- Build 55 adds `WidgetAppearance`, `WidgetDesign` and `WidgetDesignStore` under
  the separate `widgetDesignCatalog.v1` key. New Home Screen and Lock Screen
  widget instances select a preset or saved design, with a per-instance text-size
  override. Minimal, Lyrics Focus and Lyric Stack use `WidgetLyricCard`, also used
  in the editor preview.

The new system is a useful foundation but not a scalable catalog yet: the preset
mixes template/default styling; only accent/background colors are editable;
primary foreground is inferred; previous/next share one opacity; the font type
still belongs to LAStylePrefs. All three presets use broadly the same vertical
composition. The editor only previews sample content in Small/Medium/Large.

Storage also needs migration support: synthesized decoding of WidgetAppearance
has no field-level defaults, and one incompatible design can fail decoding of
the entire saved array. App Intent names, enum raw values and entity identifiers
are already persisted by iOS and must be treated as public compatibility data.

The trusted timing path stays:

    Spotify observation → lyric engine → existing snapshot/schedule
        → CurrentLineProvider.makeTimeline() → resolved widget presentation

The appearance path stays separate:

    Widget configuration + saved design + catalog + rendering context
        → resolved style → template renderer

Both paths meet only when rendering. Style selection never calls Spotify,
requests lyrics, writes playback revisions, or changes timeline boundary dates.

## 2. Keep LAStylePrefs compatible

Keep existing fields, raw values, defaults, storage key and supported behavior for
Live Activity and legacy widgets. Do not add the widget catalog to this type.
Do not silently move the scroller's karaoke preference in this project.

Expose a one-time Import Legacy Appearance action, which copies the current
values into a new widget design. It must not create a live dependency on the old
settings. A neutral FontCatalog can map existing font IDs while LAStylePrefs
continues exposing its current enum and API.

## 3. WidgetStylePrefs and resolution

Evolve WidgetAppearance into a versioned WidgetStylePrefs record, with a migration
adapter rather than a destructive rename of persisted data:

    WidgetStylePrefs
      schemaVersion
      templateID
      paletteReference
      background: BackgroundSpec
      typography: TypographySpec
      artwork: ArtworkSpec
      details: DetailVisibility
      layout: LayoutSpec
      readability: ReadabilitySpec

Use small enums for actual rendering primitives. Use stable string IDs and
catalog records for palettes, font families, templates, and curated presets.
Avoid a separate enum case for every color, gradient direction or product name.

A pure WidgetStyleResolver produces immutable ResolvedWidgetStyle from the
record, family, size, rendering mode, contrast settings, and available cached
artwork. Validate/clamp numeric settings at this boundary. Unsupported options
fall back at render time without erasing the user's stored choices.

Appearance revisions are separate from snapshot revisions. Saved designs contain
an ID, name, schema version, appearance, and revision. A curated preset is a
versioned recipe selecting a template, palette and default options; it is not a
new renderer for every combination.

## 4. Palette catalog: 50 initial entries

Bundle a validated data resource such as Resources/WidgetPalettes.json in
LyricCore. Each entry has a stable ID, revision, display name, category, tags,
semantic color roles, suggested background, optional dynamic resolver, and a
static fallback. Adding a static theme normally means adding one data record
and its preview/contrast fixture, without changing Swift switch statements.

Proposed launch catalog (50 entries):

| Category | Entries |
| --- | --- |
| Dark (9) | Midnight, OLED Black, Graphite, Charcoal, Obsidian, Black + Gold, Black + Red, Black + Electric Blue, Black + Hot Pink |
| Colorful (18) | Hot Pink, Bubblegum, Lavender, Electric Violet, Crimson, Cherry, Tangerine, Sunset, Mango, Lemon, Lime, Spotify Green, Emerald, Forest, Mint, Aqua, Ocean, Arctic |
| Aesthetic (11) | Vaporwave, Synthwave, Cyberpunk, Cotton Candy, Sakura, Aurora, Galaxy, Matcha, Espresso, Rose Gold, Silver |
| Light (7) | Pure White, Cream, Paper, Soft Gray, Pale Blue, Pale Pink, Pale Lavender |
| Dynamic (5) | Album Art, Album Dominant, Album Gradient, Album Complementary, Album Darkened |

Semantic roles: background, secondaryBackground, optional tertiaryBackground,
accent, primaryLyric, secondaryLyric, songTitle, artist, progressFill,
progressTrack, border and glow. Store explicit sRGB values rather than SwiftUI
Color archives. Alpha is explicit where useful.

Design directions, not a claim that the final 50 palettes have been validated:

| Palette | Background / secondary | Accent | Primary / secondary lyric |
| --- | --- | --- | --- |
| OLED Black | #000000 / #000000 | #D8B56D | #FFFFFF / #B8B8C0 |
| Midnight | #0B1020 / #18233D | #90B8FF | #F3F6FF / #BBC6DE |
| Vaporwave | #20123B / #421A5D | #66E6E1 | #FFF3FC / #DDB9E5 |
| Matcha | #E8E9D8 / #D7DFC7 | #49623B | #243326 / #52604A |
| Espresso | #241914 / #3B2920 | #D8B18A | #FFF1E2 / #D1BAA6 |
| Paper | #F6F1E7 / #E9E0D0 | #785444 | #292520 / #665E52 |

Use intentional hue relationships and controlled luminance, then test text over
the actual background and opacity. A single dominant-color average is not enough
for text over artwork: use a contrast-protecting scrim or backing plate.

Dynamic palettes resolve only from cached artwork/palette data. Album Art is a
curated combination of artwork background and contrast-safe colors; Album
Dominant uses one dominant hue; Album Gradient selects multiple sampled hues;
Complementary derives a controlled contrasting accent; Darkened preserves hue
while reducing background luminance. Preserve a deterministic fallback when
artwork is absent. Extract/cache once per artwork identity, never per lyric.

## 5. Templates, backgrounds, typography and artwork

Templates are genuinely different compositions with shared primitives:

| Template | Composition |
| --- | --- |
| Lyric Hero | Oversized lyric centered in available space; almost no chrome |
| Lyric Stack | Previous/current/next rows with a stable emphasized center |
| Album Card | Artwork block above/beside a distinct lyric section |
| Now Playing | Compact cover and metadata header, lyric body, progress footer |
| Minimal | Unframed type with generous negative space |
| Poster | Asymmetric oversized type with a small metadata rail |
| Vinyl | Static circular record/cover beside lyrics |
| Editorial | Serif lyric, column/rule structure and separate caption |
| Glass | Artwork-backed composition with an inset readable lyric panel |
| Neon | Framed lyric with accent label and restrained glow |
| OLED | Pure-black sparse composition; optional tiny status mark |
| Karaoke | Dominant current line and a separate upcoming-line region |
| Quote | Poem-like typography with optional decorative quotation marks |
| Artwork Full Bleed | Edge-to-edge cached artwork and anchored lyric scrim |
| Retro Player | Original compact-player structure, distinct header/footer and controls |

Some share layout primitives; they must not all become one VStack with different
colors. Template descriptors declare supported families, defaults, allowed
controls, and compact fallbacks. Keep branded preset names separate from the
limited renderer dispatch. Small widgets prioritize one lyric plus one supporting
region; Medium supports side-by-side artwork or compact stacks; Large supports
full compositions. Rectangular accessories simplify; Inline remains a single
row; Circular favors artwork/status/progress. Preserve the existing Extra Large
kind without adding a new device target in this scope.

BackgroundSpec is compositional: fill kind, gradient stops/positions, geometry,
artwork source, and optional overlays. Vertical/horizontal/diagonal are parameters
of one linear-gradient primitive, not separate enum cases. Outline, paper, neon,
OLED and soft glow are recipes over those primitives.

| Treatment | Implementation decision |
| --- | --- |
| Solid, two/three-color linear, radial | Static SwiftUI shapes/gradients; primary supported path |
| Album gradient | Cached palette → static gradient |
| Blurred/darkened/tinted artwork | Bounded image variants or simple overlays; reuse by artwork/style key; measure extension memory |
| Paper/outline/neon/soft glow | Static fills, borders and bounded shadow layers; no animated noise/shaders |
| Glass/frosted | Readable translucent-style panel over our own artwork; use system appearance where provided, never promise arbitrary wallpaper blur |
| Mesh-like | Static radial-gradient composition initially; MeshGradient is a real API but must pass widget-host and memory checks before enabling it; pre-rendered fallback |
| Minimal/OLED | Clear/system or genuinely black fill in full-color mode; iOS can override presentation in other modes |

TypographySpec includes font ID, real supported weight, relative scale, optional
bounded size override, casing, alignment, line spacing, wrapped-line limit,
previous/current/next visibility and separate opacities. Emphasis supports a
backing highlight, accent text, subtle shadow, or static gradient text in
full-color mode. Gradient text falls back to a solid foreground when tinted.

A text outline is optional follow-up: use a bounded, cached glyph treatment if
it proves readable and efficient. Do not duplicate text many times or claim an
arbitrary SwiftUI Text.stroke API. Keep accessibility text semantic. Uppercase
must be locale-aware. Never animate casing/gradient/shadows by extra entries.
Karaoke describes hierarchy here, not guaranteed continuously animated sweeps.

ArtworkSpec separates shape (square, rounded, circle, vinyl) from placement
(hidden, thumbnail, feature, background, full bleed), plus bounded opacity,
darkening, tint and blur. Cache keys include artwork identity, size and treatment.
Current phone thumbnails are capped at 256 pixels; evaluate a bounded larger
widget-specific variant for Large/full-bleed without enlarging Activity payloads.

Details are independent: title, artist, album, artwork, previous/next lyric,
progress, elapsed/remaining time, playback icon and decorative quotes. Album name
exists in Spotify's decoded album object but not the widget snapshot. Explicit
status is not currently decoded; an optional field can be carried from the
existing response without an extra request. Unknown does not mean clean/explicit.
Native timer/progress views should use existing anchors; paused progress needs
an additive frozen value. Hide unsupported details rather than fabricate data.

## 6. App Intent configuration

Keep OpenLyricsCustomHome, OpenLyricsCustomLock and LyricWidgetConfiguration
identities. Preserve current preset/design/textSize parameters and their raw
values; add optional overrides defaulting to Use Design. Existing installations
must keep their choices after upgrade.

Per-instance overrides: template, palette, background recipe, font, lyric scale,
artwork treatment, information density. Use AppEntity for catalogs and custom
palettes/designs; small AppEnums for finite scalar choices. Native configuration
should show a simple design selector first and conditionally expose overrides.
Family-aware parameter summaries can reduce irrelevant controls; renderer
validation remains necessary when resizing an already-configured widget.

Resolution order:

    saved design (or legacy preset default)
        → explicitly selected instance overrides
        → family/rendering/accessibility adaptation

Every requested appearance value can be independent per widget, directly or
through a saved design. None must be app-global because it is too advanced for
the native editor. The shared catalog is storage, not a global active theme.
Two instances selecting the same saved design/palette intentionally share its
edits; offer Duplicate/Make Independent and show the effect before Save.

Keep global playback settings such as account, provider, lyric offset, and
session behavior outside WidgetStylePrefs. Global font resources and system
accessibility settings are not per-widget style records.

## 7. Custom colors and fonts

Provide full native ColorPicker controls inside Widget Studio for every semantic
role, including secondary background and title/artist/progress colors. Store a
CustomWidgetPalette with UUID, revision, name and color-role values. The widget
selects it through an AppEntity; no unsupported color picker in Edit Widget.
Keep palette IDs stable across renames and copy values when making an independent
design. Provide reset-by-role and a readability preview; retain original values
when runtime rendering must adapt to a system tint.

Preserve the four system font choices and six bundled families (Bungee, Bebas
Neue, Baloo 2, Pacifico, Playfair Display, Space Grotesk). The widget font files
currently total about 1.6 MB before packaging, with copies in the app and extension.
A FontCatalog records ID, PostScript name, categories, supported weights/axes,
script coverage, source/version, license and file size.

Initially evaluate only four distinct additions: Fraunces for retro/editorial,
Barlow Condensed for flexible condensed type, DM Serif Display for editorial
headlines, and Atkinson Hyperlegible for readable supporting text. Their upstream
OFL files permit redistribution subject to their notices and conditions. Pin
actual assets, include license/copyright notices and inspect existing font
metadata/notices too; repository search found no standalone OFL/license files.
Use system fonts without bundling Apple font binaries. Measure app-plus-extension
size and reject near-duplicates. New fonts need glyph-fallback and real-weight
checks, not just a successful download.

## 8. Widget Studio

Settings → Widget Studio, also retaining the prominent widget entry point.

- Discover: curated ready-to-use presets, searchable theme categories and favorites.
- My Designs: saved designs, duplicate, rename, preview and explicit archive/delete behavior.
- Editor: persistent preview and small tabs/sections for Template, Palette, Type,
  Background, Artwork and Details. Advanced controls live inside the relevant
  section, not in one long slider list.
- Preview: Small, Medium, Large, Inline, Circular and Rectangular; current cached
  song or realistic sample; full-color, tinted and background-removed simulations.
- Save: apply, save as new, or cancel. No storage writes/reloads on each preview
  gesture. Explain intentionally linked designs/palettes.

The same WidgetTemplateView, resolved style, layout metrics and presentation
model should render the app preview and real widget. The host supplies the
rendering context. Preview geometry uses representative family sizes rather than
claiming one hard-coded 160-point card matches every device. The OS compositor,
tint/material treatment, timeline delivery and actual device size still require
real-widget validation.

The current preview has no artwork or progress and always uses sample content.
Extend WidgetPresentation as a read-only adapter over existing snapshot fields;
add optional metadata only where it does not exist. The preview may advance
locally while the app is visible without changing WidgetKit's timeline or reload
frequency.

## 9. Migration and reliability

1. Keep laStylePrefs and widgetDesignCatalog.v1 untouched as rollback inputs.
2. Decode v1 designs with their original schema, preserving IDs, names, revisions,
   colors, size, font, context and background semantics.
3. Convert into widgetDesignCatalog.v2 with explicit schema/defaults. Persist only
   after successful conversion and round-trip verification; never overwrite the
   sole readable copy first. Readers use v2 when present, with v1 fallback.
4. Decode records independently. Quarantine an unsupported record without dropping
   all other designs. Unknown IDs retain a fallback instead of resetting the
   entire catalog; missing new fields get stable defaults.
5. Keep the existing App Intent type/parameter identities and legacy preset mapping.
6. Preserve all old widget kind identifiers. Do not force replacement/re-adding.
7. Test old fixtures and an installed-build-55 → new-build upgrade, including
   two independent widgets and two intentionally linked widgets.

Store appearance in its own bounded, atomic app-group catalog. The app is the
single writer and the extension a reader. Built-in catalog revisions have stable
fallbacks so later palette tuning does not unexpectedly restyle saved designs.
No-op saves do not reload. Coalesce a completed edit into reloads for affected
widget kinds; public reload APIs do not target an arbitrary individual instance.
Playback-triggered reload behavior and every existing boundary date stay intact.
Cache artwork treatments, do not perform work for every line or every slider
preview, and never acquire lyrics/Spotify observations because a style changed.

## 10. Implementation phases

| Phase | Deliverable and acceptance |
| --- | --- |
| 1. Compatibility foundation | Versioned WidgetStylePrefs, pure resolver, per-record migration, preserved intent/design IDs; old fixtures and existing timing tests pass |
| 2. Palette and typography catalogs | 50 authored/validated palettes, all custom color roles, curated font registry/notices, static backgrounds; no new Spotify traffic |
| 3. Distinct templates | Hero/Minimal/Stack/Poster/Editorial/Quote, then Album Card/Now Playing/Full Bleed/Vinyl; family-specific visual fixtures |
| 4. Widget Studio and configuration | Searchable presets, advanced sections, saved palettes, all instance overrides, current/sample previews and independent-design flow |
| 5. Rich treatments and details | Remaining Glass/Neon/OLED/Karaoke/Retro recipes, bounded artwork variants, progress/time/metadata; profile memory and image cache |
| 6. Release validation | Migration/device visual matrix, long/RTL lyrics, missing artwork, contrast, pause/seek/track changes, no-update playback; shared tests and iOS/Watch builds |
| 7. Publish | Update README to actual delivered scope, inspect focused commits, push, archive a new unique build, upload and verify TestFlight processing |

Do not release half-migrated preferences. Keep Live Activity compiling and its
existing behavior; no ActivityKit lifecycle, ownership, server or APNs rewrite.
Server tests are only required if a later approved phase actually changes server
behavior. Finite schedule coverage and system-controlled timeline presentation
remain product constraints, not problems to hide with more polling.

## Primary references

- [Apple: configurable widgets and AppEntity](https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget)
- [Apple: App Intent configuration and dependent options](https://developer.apple.com/videos/play/wwdc2023/10103/)
- [Apple: rendering contexts](https://developer.apple.com/documentation/widgetkit/preparing-widgets-for-additional-contexts-and-appearances)
- [Apple: accented rendering and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
- [Apple: MeshGradient](https://developer.apple.com/documentation/swiftui/meshgradient)
- [Fraunces license](https://github.com/google/fonts/blob/main/ofl/fraunces/OFL.txt)
- [Barlow Condensed license](https://github.com/google/fonts/blob/main/ofl/barlowcondensed/OFL.txt)
- [DM Serif Display license](https://github.com/google/fonts/blob/main/ofl/dmserifdisplay/OFL.txt)
- [Atkinson Hyperlegible license](https://github.com/google/fonts/blob/main/ofl/atkinsonhyperlegible/OFL.txt)
