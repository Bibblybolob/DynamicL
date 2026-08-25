# Effortless Real-Time Lyrics Live Activity — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make the lock-screen/Dynamic Island lyrics Live Activity feel continuously live like McDonald's order tracking — fast line + song changes that never visibly stall while locked, degrade honestly when the data feed stalls, and come back cleanly after long pauses.

**Architecture:** Stop spending the scarce ActivityKit background-update budget on every visual change. Ship *self-rendering* UI elements the OS advances on its own (anchored `ProgressView(timerInterval:)`), spend push-like local updates only on lyric-line flips and track/play changes, mark updates with a `staleDate` so a stalled feed visibly decays instead of lying, and lean on the shipped keep-alive-stall fix (`697c683`) so the poller survives lock + stale-API windows.

**Tech Stack:** Swift / ActivityKit / WidgetKit / SwiftUI timers / XcodeGen / LyricCore SPM package (existing).

---

## Why (research summary)

- McDonald's-style "effortless" LAs are mostly **server push** (APNs Live Activity push tokens, push-to-start). That requires a paid Apple dev account + a backend — out of scope for a free-team sideload. The free equivalent is exactly what this repo already does (silent-audio keep-alive + local polling), improved below.
- Apple's documented ways to get motion **without** app updates inside a Live Activity: `Text(timerInterval:)` and `ProgressView(timerInterval:)` — the system renders/advances these on its own clock. This is the core trick to adopt.
- Local ActivityKit updates from a backgrounded process **are rate-limited** (confirmed empirically in this repo: per-tick updates got the activity's updates parked; the Apr '26 Apple forum thread "Live Activity Not Updating Frequently … Lyrics Sync Issue" is the same failure). Mitigations: fewer/smarter updates, `NSSupportsLiveActivitiesFrequentUpdates` in Info.plist, and `staleDate` + `isStale` for graceful decay.
- Known repo facts: starting a NEW LA from the background fails (update-in-place adopted in `LiveActivityController`); keep-alive teardown during stale-API stalls caused a 19-min process coma (fixed in `697c683`); LA update cadence is currently: track/play = immediate, lines ≥4s apart.

## Current context / assumptions

- Branch `main` @ `697c683`; tree clean; 22 LyricCore tests pass; last device install green.
- Device: iPhone 14 Pro, UDID `00008120-00167C4A0200201E`. Build/install pipeline per `ios-device-deploy` skill (DerivedData path: `~/Library/Developer/Xcode/DerivedData/Dynamicallyrics-efpepmqpfkogicauaomnmttnyrla/Build/Products/Debug-iphoneos/Dynamicallyrics.app`).
- XcodeGen: edit `project.yml`, then `xcodegen generate`. Never hand-edit the .xcodeproj.
- `PlaybackStatus` carries `state`, `position` (ms), `rate`, `timestamp` — enough to compute wall-clock anchors.
- Diagnostics pipeline exists: app writes `lyrics-diagnostics.log`, pulled with `devicectl device copy from`.

## Proposed approach (what changes)

1. **Self-advancing progress bar** — put song-position *anchor dates* in `ContentState`; the LA view draws `ProgressView(timerInterval: start...end)`. Between app updates the bar still moves → feels alive, costs zero budget.
2. **Adaptive line-update cadence** — replace fixed 4s cooldown: send a line flip immediately if the *next* line lasts ≥5s; fold sub-5s rapid-fire lines into the next urgent update. Fewer, smarter updates; no rate-limiter parking.
3. **Honest staleness** — every update sets `staleDate ≈ now + 8s`; view switches to a subtle pulsing "…" when `context.isStale` so a stalled feed shows decay, and snaps back the moment truth arrives (his "would come back" ask).
4. **Pause/resume correctness** — pause sends one final static update (bar freezes at correct spot); existing 300s auto-end stays; resume revives via existing per-tick adoption + creation retry.
5. **Budget headroom** — add `NSSupportsLiveActivitiesFrequentUpdates` next to the existing `NSSupportsLiveActivities` key (locate it first — likely `project.yml` target info or an Info.plist).

---

## Task 1: Anchor math helper in LyricCore (TDD)

**Objective:** Pure function converting playback state → wall-clock date range for the self-advancing progress bar.

**Files:**
- Create: `Packages/LyricCore/Sources/LyricCore/PlaybackAnchors.swift`
- Test: `Packages/LyricCore/Tests/LyricCoreTests/PlaybackAnchorsTests.swift`

**Step 1: Write failing test**

```swift
import XCTest
@testable import LyricCore

final class PlaybackAnchorsTests: XCTestCase {
    func testAnchorsMapPositionToWallClock() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Playing at 30s, rate 1, observed at t → bar spans t-30 ... t+dur-30
        let a = PlaybackAnchors(
            state: .playing, positionMs: 30_000, rate: 1.0,
            observedAt: t, durationMs: 200_000)
        XCTAssertEqual(a.startDate.timeIntervalSince1970, 970_000, accuracy: 0.01)
        XCTAssertEqual(a.endDate.timeIntervalSince1970, 1_170_000, accuracy: 0.01)
    }
    func testPausedAnchorsStopInThePast() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let a = PlaybackAnchors(
            state: .paused, positionMs: 60_000, rate: 1.0,
            observedAt: t, durationMs: 200_000)
        // Paused: end date already behind us → ProgressView freezes at elapsed fraction
        XCTAssertLessThan(a.endDate, t)
    }
}
```

**Step 2: Run to verify failure**
Run: `cd Packages/LyricCore && swift test --filter PlaybackAnchorsTests`
Expected: FAIL — `PlaybackAnchors` not defined.

**Step 3: Minimal implementation**

```swift
import Foundation

public struct PlaybackAnchors: Equatable {
    public let startDate: Date
    public let endDate: Date

    /// Maps (position, rate, timestamp) onto wall-clock dates so WidgetKit's
    /// timerInterval views advance the bar with zero app involvement.
    /// While paused the end date lands in the past, freezing the bar in place.
    public init(state: PlaybackState, positionMs: Int?, rate: Double?,
                observedAt: Date, durationMs: Int?) {
        let pos = TimeInterval(positionMs ?? 0) / 1000
        let dur = max(TimeInterval(durationMs ?? 0) / 1000, pos + 1)
        let rate = rate ?? 1
        let start = observedAt.addingTimeInterval(-pos / max(rate, 0.001))
        self.startDate = start
        self.endDate = start.addingTimeInterval(dur / max(rate, 0.001))
    }
}
```

(Adjust to whatever `PlaybackState`/duration source actually exists in LyricCore — check `SpotifyMapping.swift` for the player-state → model mapping; duration comes from the Spotify item.)

**Step 4: Run to verify pass** — same command, Expected: PASS (plus existing 22 still pass).

**Step 5: Commit** — `git commit -m "feat(core): playback wall-clock anchors for self-rendering LA progress"`

---

## Task 2: Extend ContentState with anchors + optional duration

**Objective:** Carry anchor dates (and song duration) in the Live Activity payload.

**Files:**
- Modify: `Packages/LyricCore/Sources/LyricCore/LyricsActivityAttributes.swift`

**Step 1: Add fields (optional, defaulted — keeps Codable back-compat with any surviving adopted activity):**

```swift
public var progressStart: Date?
public var progressEnd: Date?

public init(trackTitle: String, artistName: String, currentLine: String,
            nextLine: String? = nil, isPlaying: Bool,
            progressStart: Date? = nil, progressEnd: Date? = nil) { /* assign */ }
```

**Step 2:** `swift build` in the package → PASS. Commit: `feat(core): anchor dates in LA ContentState`

⚠️ Note for implementer: `LyricCore` is imported by both app and widget extension targets — no target membership edits needed (XcodeGen wires package products already; verify `project.yml` lists LyricCore as a dependency of LyricWidgets, which it must since `LyricsLiveActivity.swift` imports it today).

---

## Task 3: Populate anchors + adaptive cadence in AppModel.syncLiveActivity

**Objective:** Send anchors on every update; replace fixed 4s line cooldown with next-line-aware cadence; set staleDate.

**Files:**
- Modify: `DynamicallyricsApp/App/AppModel.swift:332-425` (`syncLiveActivity`, `contentState`)
- Modify: `DynamicallyricsApp/App/LiveActivityController.swift` (`update`/`start` accept `staleDate`)

**Steps:**
1. `contentState(document:)` gains duration lookup (from the cached Spotify item — check `SpotifyPlayerState.item.durationMs` mapping; if not retained, retain `lastDurationMs` alongside `lastAlbumImageURL` in `SpotifyProvider.swift:168`) and builds `PlaybackAnchors` from `status`.
2. Cadence change inside the `urgent || (lineChanged && cooledDown)` branch:

```swift
// Adaptive: a line that will be replaced again within 5s rides along on the
// NEXT urgent update instead of burning budget twice in a row.
let idx = lyrics.currentIndex
let nextLineAt = idx.map { document.lines[$0].time } ?? .infinity
let followingAt = (idx.map { $0 + 1 } ).flatMap { $0 < document.lines.count ? document.lines[$0 + 1].time : nil } ?? .infinity
let dwellLongEnough = followingAt - nextLineAt >= 5 || followingAt == .infinity
if urgent || (lineChanged && (cooledDown || !dwellLongEnough == false)) { ... }
```
   Implementer: express this cleanly — the invariant is *send immediately when the line will be visible ≥5s; otherwise wait for cooldown OR the next urgent event, whichever first.* Keep `lastLASentTrack/isPlaying/lineIndex` bookkeeping intact.
3. `LiveActivityController.update(state:)` wraps content as `ActivityContent(state:state, staleDate: isPlaying ? .now.addingTimeInterval(8) : nil)` (add `staleDate:` parameter, default computed from `state.isPlaying`).
4. Build: `xcodebuild -project Dynamicallyrics.xcodeproj -scheme Dynamicallyrics -destination "platform=iOS,id=00008120-00167C4A0200201E" build` (no signing needed for compile check) → BUILD SUCCEEDED. Commit: `feat(la): self-advancing progress anchors, adaptive line cadence, honest staleDate`

---

## Task 4: LA views — live progress bar + stale indicator

**Objective:** Render the moving bar and the decay state.

**Files:**
- Modify: `LyricWidgets/LyricsLiveActivity.swift` (both `LockScreenLyricsView` and Dynamic Island expanded bottom)

**Step 1: In `LockScreenLyricsView.body`, under the current line:**

```swift
if let start = context.state.progressStart, let end = context.state.progressEnd {
    ProgressView(timerInterval: start...end, countsDown: false)
        .tint(.pink)
        .progressViewStyle(.linear)
        .frame(height: 4)
}
```
Dynamic Island `.bottom` region gets the same bar (height 3).

**Step 2: Stale decay** — wrap the current-line `Text`:

```swift
if context.isStale {
    Text("• • •")
        .font(.system(.title3, design: .rounded, weight: .bold))
        .foregroundStyle(.white.opacity(0.35))
} else {
    Text(context.state.currentLine) // existing styling
}
```
(Do the same minimal treatment in the island's expanded bottom.) The bar keeps advancing while stale — time truth survives even when lyric truth stalls.

**Step 3:** Full device build (background terminal, grep `error:`/`BUILD SUCCEEDED`). Commit: `feat(widgets): live progress bar + stale decay in lyrics LA`

---

## Task 5: Frequent-updates plist key

**Objective:** Raise the update-budget ceiling (documented mitigation; benefit magnitude uncertain — see Risks).

**Steps:**
1. `search_files(pattern="NSSupportsLiveActivities", path="/Users/jonathantran/Documents/dynamicl", output_mode="content")` to find where the existing key lives (expect `project.yml` target `info.properties` or `LyricWidgets/Support/*.plist`).
2. Add sibling `"NSSupportsLiveActivitiesFrequentUpdates": true` in the same scope.
3. `xcodegen generate` (mandatory after project.yml edits), rebuild. Commit: `chore(ios): opt into Live Activities frequent updates`

---

## Task 6: On-device verification (the real acceptance gate)

**Steps:**
1. Install + launch via `ios-device-deploy` pipeline (devicectl install from DerivedData Debug-iphoneos path, then `device process launch com.jonathantran.dynamicallyrics`).
2. Protocol (user performs): play → lock → skip through 5+ songs over ~5 min → let one song sit paused 5+ min → unlock, resume, skip twice more.
3. Pull log: `xcrun devicectl device copy from --device 00008120-00167C4A0200201E --domain-type appDataContainer --domain-identifier com.jonathantran.dynamicallyrics --source Documents/lyrics-diagnostics.log --destination /tmp/lyrics-diagnostics.log`

**Pass criteria (analyze with Python over timestamps):**
- Zero silent gaps >10s anywhere music was playing or a stall was confirmed (keep-alive hold working).
- Every `rapid probe`/`stall confirmed` episode followed by continued polls at 0.7s through the whole window; fresh positions ≤1s after truth returns.
- `la=true` on all backgrounded heartbeats.
- Visual: progress bar advances smoothly between line flips; skipped songs swap title/artist ≤1 poll (~3s); stale "…" appears only during genuine API lies; after 5-min pause activity ends; resume brings it back within one tick of unlocking.

## Files likely to change (summary)

| File | Change |
|---|---|
| `Packages/LyricCore/Sources/LyricCore/PlaybackAnchors.swift` | new |
| `Packages/LyricCore/Tests/LyricCoreTests/PlaybackAnchorsTests.swift` | new |
| `Packages/LyricCore/Sources/LyricCore/LyricsActivityAttributes.swift` | +2 optional fields |
| `DynamicallyricsApp/App/AppModel.swift` | contentState + cadence |
| `DynamicallyricsApp/App/LiveActivityController.swift` | staleDate plumbing |
| `DynamicallyricsApp/App/SpotifyProvider.swift` | retain durationMs |
| `LyricWidgets/LyricsLiveActivity.swift` | progress bar + stale UI |
| `project.yml` | frequent-updates key |

## Risks / tradeoffs / open questions

- **Rate limiter is opaque & dynamic.** Adaptive cadence reduces risk but can't eliminate it; if updates still park, fall back to: lines-only-on-track-change + rely fully on the self-advancing bar (graceful degradation path is built in).
- **`NSSupportsLiveActivitiesFrequentUpdates` may only enlarge the *push* budget**, not local. Cheap to add; don't count on it.
- **Optional ContentState fields vs adopted activities:** an activity adopted from before the update lacks anchor dates → views must nil-check (they do). First update after launch fills them.
- **True "effortless" tier (McDonald's parity)** = APNs push updates/push-to-start; blocked on paid dev account + backend. Out of scope; revisit if he ever pays for the team.
- **Battery:** silent-audio keep-alive already runs while playing+locked; this plan adds no wakeups (fewer, actually — folded line updates).
