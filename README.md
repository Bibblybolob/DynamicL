# OpenLyrics

OpenLyrics displays time-synced lyrics for the track that is playing.
It shows lyrics on the Lock Screen, Home Screen, Dynamic Island, and Apple Watch.

## Status

Development continues.

- The current beta build is version 1.2.0, build 43.
- Build 43 is a private beta build.
- TestFlight distributes this build for beta testing.

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
| Lyric lookup retry and recovery | Complete |
| Automatic server-based Live Activity updates | Complete |
| Live Activity layout, artwork, alignment, and control settings | Complete |
| Apple Music integration | Planned |

## Current release candidate

Build 43, version 1.2.0, is a private beta and includes these changes:

- The server completes a pending lyric schedule while the phone owns playback updates.
- The server sends a lyric schedule that was saved but not sent during the ownership handoff.
- The server does not send old lyrics after the phone reports a different Spotify track.
- A failed APNs lyric update remains eligible for retry.
- A local lyric request stops after a fixed time and starts a replacement request.
- LRCLIB requests use a shorter timeout so the app can recover sooner.

- The app handles a confirmed Spotify stop one time for each playback session.
- Repeated stopped-state checks cannot bypass the five-second heartbeat limit.
- Idle playback does not send a continuous heartbeat request loop to the sync server.

- The Spotify poller waits between requests and does not enter a request loop.
- Repeated play, pause, and skip events create only one immediate Spotify check.
- A Spotify check stops after seven seconds if the connection does not respond.
- The app replaces a stopped Spotify connection before it tries again.

- The app checks Spotify's current track endpoint before it checks the full player state.
- The app confirms an empty Spotify response before it reports that playback stopped.
- A timed-out Spotify check shows a retry message and does not remain silent.
- The app uploads ActivityKit tokens only when a token changes.
- The server uses the same Spotify playback fallback as the app.

- The Start Lock Screen Lyrics button always creates a Live Activity.
- Automatic Lyrics creates a waiting Live Activity after a short Spotify delay.
- The waiting state uses clear text and updates when Spotify returns the track.
- The watchdog restarts a Spotify poller that has no successful response.
- The app shows when it is checking Spotify playback.

- App activation does not cancel a working Spotify polling loop.
- A canceled Spotify request retries and does not remain as an error.
- The polling watchdog can recover before the first playback sample arrives.
- The Live Activity waits for current Spotify track data before it starts.
- The phone remains the update owner while its Spotify data is current.
- The server takes ownership after the phone heartbeat stops.

- A partial Spotify response cannot clear a valid widget snapshot during a track change.
- The app sends one WidgetKit reload request for all widget styles.
- The Live Activity does not stop direct lyric updates after a dense lyric minute.
- A background phone yields update ownership to the APNs server.
- A foreground phone keeps ownership only while Spotify data is current.

- Lyric-line changes use the urgent local ActivityKit queue.
- Server lyric-line changes use APNs priority 10.
- The Live Activity uses a positive relevance score for Lock Screen and Dynamic Island presentation.
- Routine schedule refills and keepalive updates remain low priority.
- The existing Heroku web dyno runs the polling loop when a separate worker dyno is off.

- The iPhone sends a direct Live Activity update at each lyric boundary while the app process runs.
- Each direct update keeps a future lyric schedule for app suspension.
- Dense lyrics use a bounded update rate to reduce ActivityKit throttling.

- A new Live Activity clears an obsolete server dismissal.
- The app ignores a dismissal response from a session that existed before a direct restart.
- Repeated taps cannot start overlapping ActivityKit replacement tasks.
- The start button shows when recovery is in progress.

- The app ignores dismissed Live Activities left by an earlier TestFlight build.
- A direct start clears stale phone and server dismissal gates.
- The main screen has a visible Start Lock Screen Lyrics recovery button.
- The app shows a Live Activity start error when ActivityKit rejects a request.

- Rapid skip commands run in order.
- A skip wakes the current Spotify poll without cancelling an in-flight poll.
- Live Activity updates keep the newest track during a rapid skip sequence.

- The app rejects a Spotify response from an old or canceled poll.
- A lyric request uses the Spotify track ID as its primary identity.
- A late lyric request cannot replace lyrics for a new track.
- Play, pause, and seek changes update the Live Activity while lyrics load.
- The app clears an old dismissal flag that can block all Live Activities.
- The app accepts a server dismissal only when the phone reports it.
- An expired APNs token does not count as a user dismissal.
- Live Activity timelines use explicit lyric start and end times.
- A widget always returns to idle at the real end of a track.

- The phone remains the primary Live Activity update source.
- A 15-second lease prevents the phone and server from writing at the same time.
- The server can start one Live Activity when Spotify starts and the app is closed.
- The phone and server use the same version 2 playback fields and lyric offset.
- All new server timestamps use Unix epoch seconds.
- The Live Activity uses explicit lyric start and end boundaries.
- Each Activity content state stays below 3.5 KB.
- Partial Spotify data does not remove valid track data or artwork.
- A verified new track cannot use artwork from the previous track.
- Artwork uses a four-image, 2 MB file cache in the app group.
- Cache disk work is debounced away from the main actor.
- Widget and server commands use IDs and expire after eight seconds.
- The sync server status reports owner, readiness, payload size, and delivery state.
- Watch lyrics advance from the last received local schedule.
- The app can share a rotated diagnostic log from the sync server settings.

- The app uses the OpenLyrics name.
- The app uses the selected OpenLyrics artwork.
- The Live Activity uses a bounded lyric area.
- Long lyric lines wrap or reduce in size inside the lyric area.
- The app sends Live Activity updates in order.
- The app uses a 0.5-second minimum gap between lyric updates.
- The Live Activity supports layout, artwork, alignment, and control settings.
- The vinyl widget can show static artwork when animation is off.
- The Now Playing screen shows album artwork and playback state.
- The app downloads a reduced album image in the app process.
- Widgets and Live Activities use the file-backed image cache for the current track.
- The artwork cache rejects an image from a different track.
- Watch payloads carry one bounded artwork copy when the Watch needs it.
- Live Activities refresh when pending artwork becomes ready.
- The app can retry a failed lyric lookup.
- The app provides Minimal Lyrics, Album Card, Karaoke Focus, Lyrics Poster,
  Waveform Player, and Album Stack widgets.
- The app provides Lock Screen Lyrics, Lock Screen Album, and Lock Screen Quote
  widgets.
- The watch extension provides Karaoke Lyrics and Album Player widgets.
- All iPhone widget styles refresh when the track or artwork changes.
- The vinyl widget downloads artwork once for each timeline.
- Live Activity artwork can recover from the shared cache.
- The main lyrics view centers the active line when it opens.
- Plain lyrics use estimated times across the track duration.
- The iPhone sends the current snapshot to the Watch app and Watch widgets.

## Live Activity update ownership

The app sends a heartbeat every five seconds while Spotify data is healthy.
The heartbeat gives the phone a 15-second update lease.
The server continues to poll Spotify, but it does not send an update during this lease.
The server becomes the writer after the lease expires.

The server polls every five seconds during playback.
It polls every 10 seconds when playback is stopped.
On iOS 17.2 or later, the server can use the push-to-start token to start one
Live Activity for a new playback session. The app then registers the new
Activity update token.

## Beta 2 reliability changes

- The phone and server send one batch of up to 32 future lyric lines to the
  Live Activity.
- The batch covers up to 75 seconds and includes exact Unix start and end
  times.
- The phone sends an urgent update for a track change, play state change, seek,
  artwork change, or style change.
- The phone and server send a low-priority schedule refill when fewer than
  three future lines or fewer than 20 seconds remain.
- A valid schedule changes the lyric inside the Live Activity. The app does
  not send one ActivityKit update for every lyric line.
- The widget snapshot stores a longer bounded song schedule. It also stores a
  predicted track end. This lets WidgetKit return to idle when the phone is
  suspended.
- Partial Spotify responses keep the last trusted progress and artwork.
- A verified new track cannot use artwork from the previous track.
- A track that reaches its duration returns widgets, Watch, and Live Activity
  surfaces to idle.
- Automatic Lyrics is enabled by default. It starts the phone-owned lyric
  session when Spotify playback begins. iOS controls background refresh.
- The Live Activity remains available during a pause for up to 10 minutes.
- The recovery button starts one phone-owned lyrics session and sends an
  immediate Spotify probe when automatic activation is unavailable.
- Play, pause, next, previous, and refresh actions use the phone first and the
  server as a fallback. Commands have an ID and expire after eight seconds.
- The iOS 18 OpenLyrics control is a toggle. Turn it on to start the local
  lyrics session immediately. Turn it off to end the phone-owned session.
  The Open Live Activity Lyrics Shortcut enables automatic lyrics without a
  per-session Show Lyrics action.
- The Start Lyrics Shortcut starts the local lyrics session immediately. You
  can use it in a Shortcuts personal automation when Spotify opens.
- Automatic Lyrics starts the Live Activity after the first Spotify playback
  sample. The recovery button is available when automatic activation is not
  ready. iOS can still suspend the app, so the server remains the recovery
  authority.
- Home Screen artwork and lyric widgets have a **Refresh lyrics** action. Use
  it after a track change when WidgetKit has not yet reloaded its timeline.
- The automatic lyrics request is consumed only once for each shortcut event.
- Pause, play, seek, and skip commands update the local playback state before
  the Spotify response arrives. The app uses the local Spotify client first
  while it is running and uses the server as a fallback.

## Widgets

The app writes a `WidgetLyricSnapshot` to the shared app group.
The widgets read this snapshot and load artwork by its cache key.
The widgets do not connect to Spotify.

The app group is `group.com.jonathantran.dynamicallyrics.la`.

| Widget | Locations | Function |
|---|---|---|
| **Current Line** (`CurrentLineWidget`) | Home Screen small, medium, and large; Lock Screen circular, rectangular, and inline | Shows the current lyric line. Uses one timeline entry for each line. Sends a play or pause command. |
| **Lock Screen Lyrics** (`LockscreenLyricWidget`) | Lock Screen circular, rectangular, and inline | Shows the current lyric line with serif italic text. Uses the Lock Screen tint. |
| **Vinyl Player** (`VinylWidget`) | Home Screen small and Lock Screen circular | Shows album artwork in a record image. Rotates the record during playback. |
| **Album Player** (`AlbumPlayerWidget`) | Home Screen small and medium | Shows album art, track details, lyrics, and playback controls. |
| **Lyric Focus** (`LyricFocusWidget`) | Home Screen medium and large | Shows the current and next lyric lines. |
| **Minimal Lyrics** (`MinimalLyricsWidget`) | Home Screen small, medium, and large | Shows lyrics in a text-only layout. |
| **Album Card** (`AlbumCardWidget`) | Home Screen small and medium | Shows album art with track details and lyrics. |
| **Karaoke Focus** (`KaraokeFocusWidget`) | Home Screen medium and large | Highlights the current lyric and shows the next line. |
| **Lyrics Poster** (`LyricsPosterWidget`) | Home Screen small, medium, and large | Shows the current lyric as a bold quote card. |
| **Waveform Player** (`WaveformPlayerWidget`) | Home Screen small, medium, and large | Shows the current lyric with a compact player and waveform. |
| **Album Stack** (`AlbumStackWidget`) | Home Screen medium and large | Shows layered album artwork with the current lyric. |
| **Lock Screen Album** (`LockscreenAlbumWidget`) | Lock Screen circular and rectangular | Shows album artwork, the track, and the current lyric. |
| **Lock Screen Quote** (`LockscreenQuoteWidget`) | Lock Screen rectangular and inline | Shows the current lyric as a compact quotation. |
| **Lyrics Live Activity** (`LyricsLiveActivity`) | Lock Screen and Dynamic Island | Shows the current and next lyric lines. Provides a play or pause button. |

### Appearance settings

The **Live Activity Style** screen provides these settings:

- Player, Lyrics Focus, or Minimal layout
- Vinyl, square, or hidden artwork
- Gradient, glass, neon, paper, or outline card surface
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
The intent writes a command with an ID to the shared `PlaybackCommandBus`.
The app sends the command to the managed sync server when it is available.
The server command is idempotent. If the server is not configured, the app calls
Spotify directly.

Playback control requires the Spotify `user-modify-playback-state` scope.
If you connected Spotify before playback control was added, sign out in the app.
Then sign in again and grant the scope.

The app also requests the `user-read-recently-played` scope.
This scope helps the app prevent stale track data after a skip.

### Managed sync setup

The app uses the managed OpenLyrics sync server. The user does not enter a
server URL or access token. After Spotify sign-in and the first ActivityKit
token, the app validates the Spotify session and stores a private server token
in Keychain. The Spotify Client ID remains the only app-specific value.

## Apple Watch

- The Watch app shows the synced lyric line from the iPhone.
- The iPhone sends the lyric line and a bounded future schedule through Connectivity.
- The Watch advances lines from its local schedule when the iPhone is suspended.
- Complications include circular, rectangular, inline, and corner layouts.
- The Smart Stack includes a Current Line card.
- Watch widgets include Karaoke Lyrics and Album Player styles.

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
│   ├── Models / SyncEngine      # Shared playback state and timing logic
│   ├── SharedNowPlaying         # App-group snapshot and file-backed artwork
│   ├── PlaybackCommand         # ID-based playback command queue
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

The iOS target requires iOS 18 or later.
The watchOS target requires watchOS 10 or later.

Enter the Spotify client ID in the app.
Use `dynamicallyrics://callback` as the redirect URI.

## Run the tests

LyricCore uses Swift Package Manager tests.

```sh
swift test --package-path Packages/LyricCore
```

The sync server tests run with:

```sh
cd server
npm test
```
