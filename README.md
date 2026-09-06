# OpenLyrics

OpenLyrics displays time-synced lyrics for the track that is playing.
Widgets are the primary customizable experience. Live Activity, Dynamic Island,
and Apple Watch remain supported companion surfaces.

## Release status

The latest verified beta is **1.2.0 (55)**. App Store Connect reports build 55 as
**VALID**, verified September 6, 2026. See the [release notes](Docs/RELEASE-55.md)
for delivered scope, test results, and remaining device checks.

The expanded **Widget Studio**, 50-theme catalog, richer artwork templates and
additional fonts are an [architecture proposal](Docs/WIDGET-STUDIO-PLAN.md).
They are not included in build 55. Earlier release behavior may differ from the
current implementation; avoid using historical timing claims as guarantees.

## Customize widgets

Open **Customize Widgets** in the app to create a design. Add **OpenLyrics
Widgets** to the Home Screen or **OpenLyrics Lock Screen** to the Lock Screen,
then select a preset or saved design in **Edit Widget**.

Build 55 supports:

- Minimal, Lyrics Focus and Lyric Stack presets.
- Font, bounded size, weight, alignment, lyric context and context opacity.
- Song-title and artist visibility; Lyric Stack highlight corners.
- Accent/background colors and system, solid, gradient or album-derived backgrounds.
- Independent design selection and text-size overrides for each widget instance.
- Shared designs that intentionally share edits; **Duplicate Design** creates an
  independent look.
- Local previews until Save. Unchanged saves do not reload widgets; changed saves
  reload only the two configurable widget kinds.

The Home Screen configuration supports Small, Medium and Large. The Lock Screen
configuration supports Inline, Rectangular and Circular. Circular widgets show
playback status; rectangular and inline widgets prioritize current lyrics.
System tint, glass appearance, and background removal can alter custom colors.

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

The two configurable widget kinds use a separate `WidgetAppearance` and
`WidgetDesignStore` catalog. Editing their designs does not change Live Activity
preferences. Four system font styles and six bundled families are available:
Bungee, Bebas Neue, Baloo 2, Pacifico, Playfair Display and Space Grotesk.

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
