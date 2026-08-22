# DynamicL
# VIBE-CODED
**Dynamicallyrics** — an iOS app that displays time-synced lyrics for the currently playing track.

## Status

Work in progress. The core lyric engine and widget extension are in place; music source integrations are on the roadmap.

| Feature | Phase |
|---|---|
| Apple Music integration | Phase 1 |
| Lock Screen lyrics | Phase 4 |
| Widgets & StandBy | Phase 5 |
| Spotify integration | Phase 6 |

## Project layout

```
├── DynamicallyricsApp/     # Main SwiftUI app target
├── LyricWidgets/           # WidgetKit extension
├── Packages/LyricCore/     # Swift package shared by app and widgets
│   ├── LRCParser           # Parses .lrc files (multi-timestamp lines, [offset] tag)
│   ├── Models              # LyricsDocument / PlaybackStatus types
│   ├── SyncEngine          # Maps playback position → current lyric line
│   └── LyricsActivityAttributes # Live Activity payload for lock screen lyrics
└── project.yml             # XcodeGen project definition
```

The app and widgets share state through the `group.com.jonathantran.dynamicallyrics` app group.

## Building

Requires **Xcode 16+** (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate   # regenerates Dynamicallyrics.xcodeproj from project.yml
open Dynamicallyrics.xcodeproj
```

Targets iOS 17.0+.

## Tests

LyricCore uses Swift Package Manager tests:

```sh
swift test --package-path Packages/LyricCore
```
