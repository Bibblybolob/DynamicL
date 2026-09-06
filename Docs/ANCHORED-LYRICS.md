# External lyric timing audit — build 53

The in-app scroller remains the reference. Its timing implementation was not
changed. This build improves schedule publication and consumption; it does **not**
establish reliable autonomous arbitrary-text progression in suspended Live
Activities or guarantee second-by-second WidgetKit delivery.

## Trace and first divergence

| Stage | Code | Clock and identity |
| --- | --- | --- |
| Spotify | `DynamicallyricsApp/App/SpotifyProvider.swift`; LyricCore `PlaybackStateReducer` | Accepted `PlaybackStatus`: position in seconds, observation `Date`, rate, playing/paused/stopped. Spotify event timestamps are milliseconds and converted separately; they are not lyric onset dates. Provider supplies the stable track ID. |
| In-app reference | `LyricsService.tick()`, `SyncEngine.currentPosition(at:)`, `currentIndex(at:)`, `SyncedLyricsView` | Position = sampled position + elapsed time × rate while playing; index = document's last line at position minus user offset. No widget revision or stale date participates. |
| Export projection | LyricCore `LyricScheduleProjection.init` | Uses the same engine's accepted status. Samples position and index at one date, then maps current/future line boundaries to absolute dates. This avoids combining an earlier `displayPosition` with a later `Date.now`. |
| App group | `AppModel.syncWidgetSnapshot()`, `publishWidgetSnapshot()`, `SharedNowPlaying` | Snapshot contains track ID, schema 2, increasing publication revision, Unix generated time, current text, offset in milliseconds, projected playback-zero/end epochs, and ordered absolute lyric intervals. Rate and position are already incorporated into those intervals; widgets need no Spotify call to resolve them. |
| iOS/Watch widgets | `CurrentLineProvider.getTimeline()`, `WatchLyricProvider.getTimeline()` | Resolve the first entry at read time; submit future line/expiration dates to WidgetKit. The entry contains resolved text. WidgetKit decides when it actually presents entries. A server Activity push cannot replace this app-group timeline. |
| Activity content | `AppModel.contentState()`, `stamped()`, `LiveActivityController` | Same projection feeds current/next text, karaoke dates and future schedule. Content carries track ID, schema, phone source/revision/generated Unix time, progress dates and absolute schedule dates. The 120-second/64-line candidate is compacted to the existing 3,500-byte content budget, so the actual horizon can be shorter. |
| Activity rendering | `LyricsLiveActivity`, LyricCore `LAScheduledLyricText.body/resolveLines` | Resolves text from wall time whenever the view executes. **This is the fundamental rendering divergence:** its `TimelineView` is not an ActivityKit delivery guarantee. An absolute schedule does not cause arbitrary extension code to execute at every lyric boundary. |
| Server/APNs | `server/src/heroku-worker-v2.js`, `session.js/buildContentState`, `staleDateFor` | Server converts progress/duration/offset milliseconds to seconds, constructs absolute schedule epochs and supplies server source/revision/generated time. APNs `timestamp` is Unix seconds. Existing stale time follows bounded schedule coverage plus grace with a 60-second floor; it is not a lyric clock. Server fallback assumes normal Spotify music playback rate. |

For example: position 9 seconds at Unix epoch T, rate 1, offset 0, and lines at
0/10/20 seconds produce an initial index 0 and future boundaries T+1/T+11.
At T+12, the unchanged engine and the decoded snapshot resolver select index 2,
without a new snapshot. A precomputed widget entry can express that result.
ActivityKit still has to execute/present the Activity view for its text to change.

## Supported changes in this build

- Widget publication no longer depends on the current lyric index. One bounded
  schedule persists through ordinary progression. Structural identity includes
  document contents and rate, so corrected lyrics with unchanged line count and
  rate changes invalidate the old timeline. Existing seek, offset, play-state,
  track and artwork invalidation remains.
- Text and schedule generation use one `LyricScheduleProjection` of the known-good
  engine state. The Watch publisher uses the same projection.
- Phone snapshots carry publication revisions. The shared store rejects older
  revisions across track changes; legacy snapshots use generated-time ordering.
  This revision namespace is separate from phone/server Activity revisions.
- Widget schedules include the active interval and expiration boundaries. A
  truncated schedule resolves to a neutral note after its known final interval,
  rather than falsely holding that lyric until track end.
- An optimistic widget pause resolves the lyric at command time, rather than
  reverting to the potentially old publication text.
- Activity rendering uses wall time when invoked, including the nested karaoke
  render. Expired intervals clear. Synthetic five-second "recovery" dates were
  removed: they did not establish a system execution guarantee.
- No stale timeout increase, extra Spotify polls, per-line APNs, background
  keepalive, server deployment or ownership change is part of this build.

## Platform constraints and remaining validation

[Apple documents](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
Activity updates from the app or ActivityKit pushes, rather than widget timelines.
System timer/progress views can advance natively, but that does not grant the same
behavior to arbitrary lyric selection code.

[WidgetKit guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
encourages precomputed timelines but recommends entries roughly five minutes
apart. Lyric boundaries are much denser. The existing dense timeline is retained
as best effort; accurate schedule data does not guarantee lyric-speed rendering.

The 15-second phone lease and existing APNs ownership recovery remain. A track
change, seek, pause/resume, corrected lyrics, stop or recovery must reach the
surface to replace its old schedule. A locally cached schedule cannot infer an
unobserved Spotify event. APNs Activity updates do not update widget storage.

Unit tests compare six minutes of a decoded snapshot and generated timeline dates
against SyncEngine without further publication, plus anchor delay/rate/offset,
pause/resume, seek within the same line, new tracks, corrected lyrics, expiry,
optimistic pause and snapshot ordering. These test data and resolution, not the
OS's scheduling promises.

Device/TestFlight checks: several minutes locked with the app suspended; switching
to Spotify/another app; Always-On Display; pause/resume/seek/rapid skips; delayed
APNs during phone/server ownership recovery; widget timeline delivery and Watch
delivery. Verify build 53 specifically. Do not describe this work as fixing all
background staleness unless those measurements establish it.
