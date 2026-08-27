# OpenLyrics

OpenLyrics displays time-synced lyrics for the track that is playing.
It shows lyrics on the Lock Screen, Home Screen, Dynamic Island, and Apple Watch.

## Status

Development continues.

- The current local release candidate is version 1.1.1, build 10.
- TestFlight contains version 0.1.0, build 5.
- Build 10 is uploaded to TestFlight and is processing in App Store Connect.

| Feature | Status |
|---|---|
| LRC parsing and lyric synchronization | Complete |
| Spotify integration with PKCE authentication and polling | Complete |
| Lock Screen Live Activity and Dynamic Island lyrics | Complete |
| Home Screen and Lock Screen widgets | Complete |
| Adaptive lyric size and overflow protection | Complete |
| Play and pause from widgets | Complete |
| Apple Watch app and complications | Complete |
| Lyric cache across app launches | Complete |
| Optional server-based Live Activity updates | Complete |
| Live Activity layout, artwork, alignment, and control settings | Complete |
| Apple Music integration | Planned |

## Current release candidate

Build 10, version 1.1.1, includes these changes:

- The app uses the OpenLyrics name.
- The app uses the selected OpenLyrics artwork.
- The Live Activity uses a bounded lyric area.
- Long lyric lines wrap or reduce in size inside the lyric area.
- The app sends Live Activity updates in order.
- The app uses a 1.5-second minimum gap between lyric updates.
- The Live Activity supports layout, artwork, alignment, and control settings.
- The vinyl widget can show static artwork when animation is off.
- The Now Playing screen shows album artwork and playback state.
- The app downloads a reduced album image in the app process.
- Widgets and Live Activities use the cached image for the current track.
- The artwork cache rejects an image from a different track.
- Widget snapshots carry ready artwork bytes with the track update.
- Live Activities refresh when pending artwork becomes ready.

## Widgets

The app writes a `WidgetLyricSnapshot` to the shared app group.
The widgets read this snapshot.
The widgets do not connect to Spotify.

The app group is `group.com.jonathantran.dynamicallyrics.la`.

| Widget | Locations | Function |
|---|---|---|
| **Current Line** (`CurrentLineWidget`) | Home Screen small, medium, and large; Lock Screen circular, rectangular, and inline | Shows the current lyric line. Uses one timeline entry for each line. Sends a play or pause command. |
| **Lock Screen Lyrics** (`LockscreenLyricWidget`) | Lock Screen circular, rectangular, and inline | Shows the current lyric line with serif italic text. Uses the Lock Screen tint. |
| **Vinyl Player** (`VinylWidget`) | Home Screen small and Lock Screen circular | Shows album artwork in a record image. Rotates the record during playback. |
| **Lyrics Live Activity** (`LyricsLiveActivity`) | Lock Screen and Dynamic Island | Shows the current and next lyric lines. Provides a play or pause button. |

### Appearance settings

The **Live Activity Style** screen provides these settings:

- Player, Lyrics Focus, or Minimal layout
- Vinyl, square, or hidden artwork
- Left or centered lyric text
- Font and color theme
- Lyric size
- Karaoke sweep
- Next-line and progress-bar visibility
- Playback-control and track-detail visibility

The app uses these settings in the Live Activity and widgets.
The vinyl widget uses a static image when animation is off.

### Playback control

The play and pause buttons use the `ToggleLyricPlaybackIntent` App Intent.
The intent writes a command to the shared `PlaybackCommandBus`.
The app reads the command within about 250 milliseconds.
The app then calls `PUT /v1/me/player/play` or `PUT /v1/me/player/pause`.

Playback control requires the Spotify `user-modify-playback-state` scope.
If you connected Spotify before playback control was added, sign out in the app.
Then sign in again and grant the scope.

The app also requests the `user-read-recently-played` scope.
This scope helps the app prevent stale track data after a skip.

## Apple Watch

- The Watch app shows the synced lyric line from the iPhone.
- The iPhone sends the lyric line through Connectivity.
- Complications include circular, rectangular, inline, and corner layouts.
- The Smart Stack includes a Current Line card.

## Project layout

```text
├── DynamicallyricsApp/         # Main SwiftUI app target
│   ├── App/                    # AppModel, Spotify, Live Activity, and sync code
│   └── UI/
├── LyricWidgets/               # iOS WidgetKit extension
├── WatchApp/                   # watchOS companion app
├── WatchWidgets/               # watchOS widget extension
├── Packages/LyricCore/         # Swift package shared by all targets
│   ├── LRCParser               # Parses .lrc files and the offset tag
│   ├── LRCLIB                  # Gets lyrics from lrclib.net
│   ├── Models / SyncEngine     # Maps playback position to a lyric line
│   ├── SharedNowPlaying        # App-group snapshot store and playback override
│   ├── PlaybackCommand         # Widget-to-app playback command bus
│   └── LyricsActivityAttributes # Live Activity data
├── server/                     # Optional authenticated Cloudflare sync worker
└── project.yml                 # XcodeGen project definition
```

## Build the app

The build requires Xcode 16 or later, Swift 6, and XcodeGen.

```sh
xcodegen generate   # Regenerates Dynamicallyrics.xcodeproj from project.yml
open Dynamicallyrics.xcodeproj
```

The iOS target requires iOS 17 or later.
The watchOS target requires watchOS 10 or later.

Set the Spotify client ID in
`DynamicallyricsApp/App/SpotifyConfig.swift`.
Use `dynamicallyrics://callback` as the redirect URI.

## Run the tests

LyricCore uses Swift Package Manager tests.

```sh
swift test --package-path Packages/LyricCore
```
