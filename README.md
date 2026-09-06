# OpenLyrics

OpenLyrics displays time-synced lyrics for the track that is playing.
Widgets are the primary customizable experience. Live Activity, Dynamic Island,
and Apple Watch remain supported companion surfaces.

## Release status

**1.2.0 (56)** introduces Widget Studio. Release validation and TestFlight upload
are in progress; build 55 remains the last verified TestFlight release until
processing finishes. See [build 56 notes](Docs/RELEASE-56.md).

## Customize widgets

Open **Widget Studio** to browse palettes and layouts, favorite themes, or edit
saved designs. Add **OpenLyrics Widgets** to the Home Screen or **OpenLyrics Lock
Screen** to the Lock Screen, then select a saved design in **Edit Widget**.

Build 56 includes:

- **50 palettes** across Dark, Colorful, Aesthetic, Light and Dynamic categories.
  Static palettes live in a bundled JSON catalog with stable IDs and semantic roles.
- **15 layouts:** Lyric Hero, Lyric Stack, Album Card, Now Playing, Minimal, Poster,
  Vinyl, Editorial, Glass, Neon, OLED, Karaoke, Quote, Artwork Full Bleed and Retro Player.
- Presets plus sectioned advanced editing for typography, background, artwork and
  information. Every saved design has its own choices.
- Semantic custom colors for backgrounds, accent, lyrics, title, artist, progress,
  border and glow. Save a named palette for reuse or select it in Edit Widget.
- Four system font designs and ten bundled families. New additions are Fraunces,
  Barlow Condensed, DM Serif Display and Atkinson Hyperlegible; redistribution
  notices are bundled. [Font provenance](Docs/WIDGET-FONTS.json) pins their sources.
- Font weight/scale, casing, alignment, line spacing, bounded line count, independent
  lyric opacities, emphasis and subtle shadow. Family adaptation limits crowded layouts.
- Solid, two/three-color directional and radial gradients, static glow, cached
  artwork, frosted-style panels, paper/outline/neon treatments and inner corner controls.
- Artwork placement, square/rounded/circle/vinyl treatments, size, opacity, tint,
  blur and background darkening. Artwork uses the existing bounded cache.
- Optional title, artist, album, lyric context, progress, elapsed/remaining time,
  playback icon and decorative quotes. Missing metadata is omitted.
- Per-instance design, template, palette, font, surface, text-size, artwork and
  density choices through App Intent configuration.
- Current-song or sample previews for Small, Medium, Large, Inline, Circular and
  Rectangular using the same renderer as the widget. Tint/background-removal
  simulations are illustrative; iOS retains control over the real appearance.

Two widgets selecting the same saved design intentionally share its edits.
**Duplicate / Make Independent** creates a separate design. Named palettes are
copied into saved designs; explicit palette overrides resolve that palette when
the timeline is next built. Preview gestures do not write playback state or reload
widgets. Saving a changed design reloads only the two configurable widget kinds;
no-op saves do not reload. Saving a new palette does not reload existing widgets.

Home Screen configuration supports Small, Medium and Large. Lock Screen
configuration supports Inline, Rectangular and Circular; circular widgets show
playback status, and rectangular/inline widgets prioritize lyrics. Small artwork
layouts use compact headers. Existing widgets and their kind identifiers remain.

Existing widget kinds remain available:

| Widget | Families |
| --- | --- |
| Current Line | Small, Medium, Large, Extra Large; Inline, Circular, Rectangular |
| Album Player | Small, Medium |
| Lyric Focus | Medium, Large |
| Minimal Lyrics | Small, Medium, Large |
| Album Card | Small, Medium |
| Karaoke Focus | Medium, Large |
| Lyrics Poster | Small, Medium, Large |
| Waveform Player | Small, Medium, Large |
| Album Stack | Medium, Large |
| Lock Screen Lyrics | Inline, Circular, Rectangular |
| Lock Screen Album | Circular, Rectangular |
| Lock Screen Quote | Inline, Rectangular |
| Vinyl Player | Small, Circular |

Extra Large is declared for Current Line but is not an iPhone widget size; the
project currently targets iPhone. Some legacy layouts include playback and
refresh buttons. Vinyl motion and other continuous effects are not guaranteed
by WidgetKit.

## Appearance compatibility

**Live Activity Style** continues to use the existing `LAStylePrefs` app-group
record for Live Activity and legacy static widgets. It provides themes, fonts,
layout, artwork, surface, alignment and visibility settings. Its karaoke setting
also affects the in-app lyric scroller.

The configurable kinds use dedicated `WidgetStylePrefs`, separate from
`LAStylePrefs`. `WidgetAppearance` remains the build-55 compatibility adapter.
`WidgetDesignStore` reads `widgetDesignCatalog.v2`, with v1 fallback and per-record
decoding. Saved design IDs/names/revisions remain stable; saving verifies a
round-trip before replacing the catalog. The v1 record and unsupported v2 records
are retained. Old intent parameters and values still resolve. Import Live Activity
Appearance makes a copy rather than linking settings.

Palette values are stored with each design to avoid silent restyling when a
built-in catalog changes. Custom palette storage is separate from playback
snapshots. The Apple Watch and Live Activity retain their existing appearance and
timing paths; the new widget style record is not sent in APNs content state.

## Playback, snapshots and reliability

The iPhone's accepted playback state feeds the shared LyricCore timing engine.
It publishes a versioned `WidgetLyricSnapshot` to app group
`group.com.jonathantran.dynamicallyrics.la`. The snapshot contains playback
anchors, ordered lyric intervals, track identity, artwork references and
publication ordering. Artwork is stored in a bounded shared file cache.

Widgets consume the existing snapshot and precomputed timeline. Appearance
changes do not request Spotify playback or acquire lyrics. Ordinary lyric
progression does not require a new snapshot or manual reload for every line.
Pause, seek, track changes and corrected lyrics update the schedule through the
existing publication path. Track-end and schedule-expiration boundaries are
preserved. Actual timeline presentation remains controlled by WidgetKit.

Live Activity remains functional through phone updates and the APNs server.
Healthy phone heartbeats grant a 15-second lease; the current Heroku v2 worker
skips Spotify acquisition during that lease. In-flight requests can still overlap
a handoff. The server can take over when the phone stops renewing its lease.

A cached schedule cannot discover an unobserved pause, seek or track change.
An ActivityKit push does not update the widget's app-group snapshot. Accurate
schedule data also does not guarantee continuously executing arbitrary text
animations in a suspended Live Activity. See the [timing audit](Docs/ANCHORED-LYRICS.md).

The app uses Spotify PKCE authentication and existing request-safety handling.
Playback controls require `user-modify-playback-state`; the current integration
also requests playback-reading and recently-played scopes. Reauthorize if an
older sign-in did not grant playback control. Managed synchronization uses
per-installation authentication; secrets belong in Keychain/server configuration,
never in source control.

## Apple Watch

The phone sends snapshots through WatchConnectivity. The Watch advances its
local schedule and uses its own snapshot storage. Existing watch widgets are
Current Line (Inline, Circular, Rectangular and Corner), Lyrics Stack Card
(Rectangular), Karaoke Lyrics (Rectangular), and Album Player (Circular and
Rectangular). The new iOS design editor does not yet configure Watch widgets.

## Project layout

| Path | Responsibility |
| --- | --- |
| `DynamicallyricsApp/App/` | AppModel, Spotify, lyrics, Live Activity and synchronization services |
| `DynamicallyricsApp/UI/` | Main scroller, legacy appearance settings and widget gallery/editor |
| `LyricWidgets/` | Configurable/legacy widgets, Live Activity, Control Center control and intents |
| `Packages/LyricCore/` | Shared timing, snapshots, appearance models and rendering components |
| `WatchApp/`, `WatchWidgets/` | Companion app and watch widgets |
| `server/` | Heroku/PostgreSQL sync service; legacy Cloudflare paths retained |
| `project.yml` | XcodeGen definition; canonical project is `Dynamicallyrics.xcodeproj` |
| `Docs/` | Release notes, audits and proposals with their implementation status |

Some shipped work remains uncommitted in the local checkout. The release notes
identify the verified binary; a source checkout should be assessed by its own
commit and working-tree state.

## Build and test

Use Xcode with the required SDKs, Swift 6, and XcodeGen. The deployment targets
are iOS 18 and watchOS 10. Build 55 was validated with Xcode 26.6.

```sh
xcodegen generate
open Dynamicallyrics.xcodeproj
xcodebuild -project Dynamicallyrics.xcodeproj -scheme Dynamicallyrics -destination 'generic/platform=iOS' build
swift test --package-path Packages/LyricCore
```

The Watch scheme is `DynamicallyricsWatch`. Device builds require appropriate
local signing. Enter the Spotify Client ID in the app and configure
`dynamicallyrics://callback` as its redirect URI.

For server changes, use Node 22 and the commands in [server/README.md](server/README.md):

```sh
cd server
npm install
npm test
```

Build 55 passed 100 XCTest tests plus 38 Swift Testing tests, the generic iOS
build, simulator build, Release archive and code-signature verification.
Real-device checks still need to cover widget configuration, saved-design
independence, app upgrades, all rendering appearances, and playback transitions.
