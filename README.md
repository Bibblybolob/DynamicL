# OpenLyrics

# VIBE-CODED

**OpenLyrics** — an iOS app that displays time-synced lyrics for the currently playing track, on your Lock Screen, home screen, Dynamic Island, and Apple Watch.

## Status

Work in progress. The lyric engine, Spotify integration, and widget surfaces are in place.
Build 5 (`0.1.0 (5)`) has been uploaded to TestFlight and is processing in App Store Connect. Build 7 (`1.1.1`) is the current local release candidate with the OpenLyrics name and selected option 4 artwork.

| Feature | Status |
|---|---|
| LRC parsing + sync engine | ✅ Done |
| Spotify integration (PKCE auth, polling) | ✅ Done |
| Lock Screen Live Activity + Dynamic Island lyrics | ✅ Done |
| Home screen & Lock Screen widgets | ✅ Done |
| Adaptive lyric sizing and overflow protection | ✅ Done |
| Interactive play/pause from widgets | ✅ Done |
| Apple Watch app + complications | ✅ Done |
| Persistent lyric cache across launches | ✅ Done |
| Optional server-backed Live Activity updates | ✅ Done |
| Live Activity layout, artwork, alignment, and control customization | ✅ Done |
| Apple Music integration | Roadmap |

## Build 6 highlights

- Live Activity lyric cards now fit long lines inside bounded, readable layouts instead of allowing oversized text to escape the card.
- Live Activity updates are coalesced and serialized, with a shorter lyric-change interval to reduce stale lines and silent update drops.
- Live Activity appearance now includes compact/balanced/large lyric sizing plus next-line and progress-bar toggles.
- The album-art vinyl widget now supports both Lock Screen circular and Home Screen small layouts with lighter timeline-driven spinning.
- The main app now presents album art, clearer playback state, and grouped settings in a more polished Now Playing surface.

## Build 5 highlights

- Long lyric lines now wrap, shrink, or marquee within a bounded area instead of escaping the app, widget, or Live Activity window.
- Live Activities recover more reliably after relaunches, external dismissal, track changes, and background audio interruptions.
- Fetched lyrics persist locally for faster reuse across launches, with age and size limits plus corrupt-cache protection.
- Playback now uses a provider-neutral contract, keeping the app ready for additional music services beyond Spotify.
- The optional sync server includes authenticated APNs update/end delivery and an in-app connection check. Remote Live Activity starting remains a follow-up.

## Widgets

All widgets read a precomputed snapshot (`WidgetLyricSnapshot`) published by the app into the
shared `group.com.jonathantran.dynamicallyrics.la` app group, so they never talk to Spotify themselves.

| Widget | Surfaces | Notes |
|---|---|---|
| **Current Line** (`CurrentLineWidget`) | Home screen small/medium/large · Lock Screen circular/rectangular/inline | Live lyric line with scheduled per-line timeline entries; tap ⏯ to toggle playback in place |
| **Lock Screen Lyrics** (`LockscreenLyricWidget`) | Lock Screen only (circular/rectangular/inline) | Standalone serif-italic "lyric card" styling that follows the Lock Screen tint |
| **Vinyl Player** (`VinylWidget`) | Home screen small · Lock Screen circular | Album-art record that rotates while playback is active |
| **Lyrics Live Activity** (`LyricsLiveActivity`) | Lock Screen card · Dynamic Island | Synced current + next line; includes a play/pause button |

### Appearance customization

The **Live Activity Style** screen supports Player, Lyrics Focus, and Minimal
layouts; vinyl, square, or hidden artwork; left or centered lyrics; multiple
fonts, themes, lyric sizes, karaoke sweep, next-line/progress visibility, and
optional playback controls or track details. The same choices are reflected in
the home-screen and Lock Screen widgets, while the vinyl widget can be static
when animations are disabled.

### Interactive playback

The ⏯ buttons use an App Intent (`ToggleLyricPlaybackIntent`) that flips an optimistic
play/pause override for instant feedback and drops a command into a shared mailbox
(`PlaybackCommandBus`). The app picks the command up within ~250 ms and calls
`PUT /v1/me/player/play|pause`.

> **Note:** playback control requires the `user-modify-playback-state` scope. If you
> connected your Spotify account before this was added, sign out and back in inside the
> app to grant it. The app also requests `user-read-recently-played` so it can reject
> stale track responses during skips.

## Apple Watch

- **Watch app**: shows the synced lyric line mirrored from the iPhone over Connectivity.
- **Complications**: circular / rectangular / inline / corner ("Current Line") plus a Smart Stack card.

## Project layout

```
├── DynamicallyricsApp/         # Main SwiftUI app target
│   ├── App/                    # AppModel, Spotify auth/provider, Live Activities, sync
│   └── UI/
├── LyricWidgets/               # iOS WidgetKit extension (widgets + Live Activity)
├── WatchApp/                   # watchOS companion app
├── WatchWidgets/               # watchOS widget extension (complications)
├── Packages/LyricCore/         # Swift package shared by every target
│   ├── LRCParser               # Parses .lrc files (multi-timestamp lines, [offset] tag)
│   ├── LRCLIB                  # Lyrics lookup via lrclib.net
│   ├── Models / SyncEngine     # Playback position → current lyric line
│   ├── SharedNowPlaying        # App-group snapshot store (+ optimistic override)
│   ├── PlaybackCommand         # Widget → app remote-control command bus
│   └── LyricsActivityAttributes # Live Activity payload
├── server/                     # optional authenticated Cloudflare sync worker
└── project.yml                 # XcodeGen project definition
```

## Building

Requires **Xcode 16+** (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate   # regenerates Dynamicallyrics.xcodeproj from project.yml
open Dynamicallyrics.xcodeproj
```

Targets iOS 17.0+ and watchOS 10+. Add your Spotify Client ID in
`DynamicallyricsApp/App/SpotifyConfig.swift` (redirect URI: `dynamicallyrics://callback`).

## Tests

LyricCore uses Swift Package Manager tests:

```sh
swift test --package-path Packages/LyricCore
```
