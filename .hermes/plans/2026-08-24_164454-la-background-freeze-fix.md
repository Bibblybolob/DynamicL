# LA Background Freeze Fix — Stalled Poller Detection Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Eliminate the remaining Live Activity freeze: when Spotify's API stalls (reports `playing=false, pos` frozen at the pre-skip value) mid-transition while the app is backgrounded, the app's poller stops being scheduled and never recovers — leaving a frozen card until the user unlocks. Detect the stall and force recovery without depending on timers.

**Architecture:** Keep the existing tick loop + adoption/creation recovery from previous builds (`b104731`). Add two mechanisms in `SpotifyProvider`: (1) an explicit stalled-state flag set when N consecutive polls return frozen `pos` with `isPlaying=false`, cleared on real state; (2) a self-rescheduling poll task that always schedules its next iteration via `Task.sleep`, so a hung `URLSession.data` can't silently end the loop. AppModel already retries `start()` every 250 ms when `!isRunning`; the missing piece was the poller going quiet — this plan fixes exactly that.

**Tech Stack:** Swift 6 / SwiftUI / WidgetKit / ActivityKit / Spotify Web API (`GET /v1/me/player`), XcodeGen project at repo root, device install via `xcrun devicectl`.

---

## Current context (verified from device logs `/tmp/diag17.log`, pulled 2026-08-24 23:45 UTC)

- 23:39–23:43 session: skips detected correctly (`Gun To My Head` → `Champagne` → `Retroactive Jealousy` → `Still`), `la=true` throughout — adoption works.
- **The freeze signature:** at 23:43:48, after "rapid probe" fires, polls repeat `item=Still playing=false pos=55000` with pos **identical to the millisecond** across ≥6 consecutive polls while the user hears the next song playing.
- Earlier trace (diag16): after the same signature at 23:40:00, **all polling stops for ~2m35s** (no `poll:` lines between 23:40:02 and 23:42:35) → card freezes → recovers only at unlock.
- Root cause chain: stale-API window (old track "paused" at frozen pos) → app enters rapid-probe → poll task stalls/exits during it → no new state ever arrives → `syncLiveActivity` has nothing to send → iOS parks the card.
- The app cannot distinguish "user actually paused" from "API serving stale pause" except by the frozen-pos repetition — that's the detector.

## Proposed approach

Two small, surgical changes; no schema or UI changes:

1. **Stall detection + synthetic resume probe** in `SpotifyProvider.poll()`: if ≥4 consecutive polls show identical `progressMs` with `isPlaying == false`, treat as *suspected stale API*, not a real pause: keep the provider in rapid-probe mode indefinitely (until any fresh state arrives), and — critically — keep calling `poll()` on schedule (fix #2 guarantees this).
2. **Self-rescheduling poll loop**: replace the current `while !Task.isCancelled { poll(); sleep }` structure's vulnerability by wrapping each cycle so an unexpected error/return inside `poll()` still reschedules. Concretely: move the loop body into `pollCycle()` and have the loop `defer`-free but log-and-continue on thrown/cancelled internals; verify with a unit-style sanity check that `start()` is idempotent (it is — `guard pollTask == nil`).

Out of scope (explicitly): changing LA update cadence again (current 4s cooldown + urgent bypass is correct), widget changes, vinyl changes.

---

## Step-by-step plan

### Task 1: Add stall detection state to SpotifyProvider

**Objective:** Track consecutive frozen-pause polls so the app knows the API is lying.

**Files:**
- Modify: `DynamicallyricsApp/App/SpotifyProvider.swift` (properties near top, ~lines 8–20)

**Step 1: Add properties**

```swift
private var stalledPauseCount = 0
private static let stallThreshold = 4
/// True while we believe the API is serving a stale paused state.
private(set) var isStalledPause = false
```

**Step 2: Build to verify no syntax errors**

Run: `xcodebuild -project Dynamicallyrics.xcodeproj -scheme Dynamicallyrics -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

(No commit yet — behavior comes in Task 2.)

### Task 2: Feed the detector inside poll()/apply()

**Objective:** Set `isStalledPause` after N frozen-pause polls; clear it on any fresh state.

**Files:**
- Modify: `DynamicallyricsApp/App/SpotifyProvider.swift` — in `poll()` case 200 (~line 45) and `apply(_:)` (~line 106)

**Step 1: In `case 200` of `poll()`, before `apply(state)`, add:**

```swift
if !state.isPlaying, state.progressMs == lastFrozenPos {
    stalledPauseCount += 1
} else {
    stalledPauseCount = 0
}
lastFrozenPos = state.progressMs
isStalledPause = stalledPauseCount >= Self.stallThreshold
```

**Step 2: Add property `private var lastFrozenPos: Int?`** next to the Task-1 properties.

**Step 3: In `apply(_:)`, first line:**

```swift
if state.isPlaying { stalledPauseCount = 0; isStalledPause = false }
```

**Step 4: Extend rapid-probe condition** — current trigger is the playing→paused flip; also keep rapid mode while `isStalledPause`. In the loop where interval is chosen:

```swift
let interval = (self?.usesRapidProbe == true || self?.isStalledPause == true) ? 0.7 : 3.0
```

**Step 5: Build**

Run: same as Task 1 Step 2. Expected: SUCCEEDED.

### Task 3: Make the poll loop unstallable

**Objective:** Guarantee `poll()` keeps running even if one call hangs/fails oddly.

**Files:**
- Modify: `DynamicallyricsApp/App/SpotifyProvider.swift` — `start()` (~line 16) and add `pollCycle()`

**Step 1: Rewrite start():**

```swift
func start() {
    guard pollTask == nil else { return }
    isPolling = true
    pollTask = Task { [weak self] in
        while !Task.isCancelled {
            await self?.pollCycle()
            // Rapid/stalled states poll fast; otherwise normal cadence.
            let fast = self?.usesRapidProbe == true || self?.isStalledPause == true
            try? await Task.sleep(for: .seconds(fast ? 0.7 : 3.0))
        }
    }
}

/// One full poll with its own timeout guard; errors are logged and swallowed
/// so the loop above can never die from a single bad request.
private func pollCycle() async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { [weak self] in await self?.poll() }
        group.addTask {
            try? await Task.sleep(for: .seconds(12))   // hard ceiling per poll
            group.cancelAll()
        }
    }
    DiagnosticsLog.append("pollCycle done stalled=\(isStalledPause)")
}
```

Note: `group.cancelAll()` cancels both children; `poll()`'s URLSession request honors cancellation and throws CancellationError which `poll()` already catches into `lastError`. Loop continues regardless.

**Step 2: Build** — expected SUCCEEDED.

**Step 3: Run package tests**

Run: `swift test --package-path Packages/LyricCore`
Expected: 22 tests, 0 failures (provider code isn't package-tested; this guards regressions elsewhere).

**Step 4: Commit**

```bash
git add DynamicallyricsApp/App/SpotifyProvider.swift DynamicallyricsApp/App/AppModel.swift LyricWidgets/VinylWidget.swift
git commit -m "fix(la): detect stalled stale-API pause, keep poller alive through it"
```

(AppModel.swift/VinylWidget.swift included only if dirty from prior work in this branch.)

### Task 4: Instrument the stall for verification

**Objective:** See the mechanism fire in device logs next test round.

**Files:**
- Modify: `DynamicallyricsApp/App/SpotifyProvider.swift` — in the stall-detection block from Task 2

**Step 1: On threshold crossing (when `isStalledPause` flips true), append once:**

```swift
DiagnosticsLog.append("stall confirmed: \(stalledPauseCount) frozen polls at pos=\(lastFrozenPos ?? -1)")
```

Guard with a `didLogStall` bool so it logs once per stall episode; reset alongside `stalledPauseCount = 0`.

**Step 2: Build + commit**

```bash
git add -A && git commit -m "chore(la): log stall episodes"
```

### Task 5: Device install + live verification

**Objective:** Prove the freeze is gone on hardware.

**Step 1: Install**

Run:
```bash
xcrun devicectl device install app --device 00008120-00167C4A0200201E \
  ~/Library/Developer/Xcode/DerivedData/Dynamicallyrics-efpepmqpfkogicauaomnmttnyrla/Build/Products/Debug-iphoneos/Dynamicallyrics.app
```
Expected: `• bundleID: com.jonathantran.dynamicallyrics`

**Step 2: User reproduction protocol (locked phone)**

Play a playlist, lock, skip 5+ songs over ~5 minutes, note any freeze ≥15s.

**Step 3: Pull diagnostics**

```bash
xcrun devicectl device copy from --device 00008120-00167C4A0200201E \
  --domain-type appDataContainer --domain-identifier com.jonathantran.dynamicallyrics \
  --source Documents/lyrics-diagnostics.log --destination /tmp/diag18.log
grep -E "stall confirmed|pollCycle" /tmp/diag18.log | tail -20
```

**Pass criteria:** every `stall confirmed` episode is followed within ≤2s by resumed `poll:` lines with fresh positions, `la=true` persists across all skips, and no >10s gap between consecutive `hb` lines.

**Step 4: Commit final state & push**

```bash
git add -A && git commit -m "verified: LA survives stale-API stalls" && git push origin main
```

---

## Files likely to change

- `DynamicallyricsApp/App/SpotifyProvider.swift` (detection + resilient loop)
- `DynamicallyricsApp/App/AppModel.swift` (only if integration requires; currently untouched)
- Diagnostics strings only otherwise

## Tests / validation

- Package suite: `swift test --package-path Packages/LyricCore` → 22 pass (regression guard)
- Build gate: generic iOS destination build must SUCCEED before any install
- Hardware acceptance: the 4-step protocol in Task 5 (pass criteria defined there)
- Log-based regression tripwire: any future `hb` gap >10s between consecutive heartbeats = fail

## Risks, tradeoffs, open questions

- **Risk: 0.7s polling during long stalls** could burn API rate limits. Mitigation: cap continuous rapid mode at 90s per episode (add counter; drop to 3s cadence but keep `isStalledPause` semantics). Decide during Task 2 review.
- **Tradeoff accepted:** during a genuine user pause, the first ~2.8s (4 × 0.7s) will be misread as "stalled" before confirmation — harmless because a real pause produces the same visual (paused card).
- **Open question:** whether the underlying poller stall is a hung `URLSession.data` despite `timeoutInterval = 10`. If Task 5 shows `pollCycle done` gaps *without* the 12s timeout firing, escalate to explicit `URLRequest.timeoutInterval` recheck + `URLSessionConfiguration.timeoutIntervalForRequest`.
- **Assumption to revisit if wrong:** that the process stays alive through stalls (heartbeats continued in diag17 — yes, it does).

## Explicit non-goals

- No changes to LA update throttling (settled: urgent bypass + 4s line cooldown)
- No widget/vinyl changes (vinyl spin params were just retuned; let them settle)
- No removal of diagnostics logging this round (still needed for one more verification cycle)
