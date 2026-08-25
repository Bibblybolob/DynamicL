# Always-On Live Activity — The Exhaustive Solution Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make the lyrics Live Activity behave like Apple Music's: it appears the moment a song starts (no app visit), survives lock indefinitely, and reflects every play/pause/skip/seek within ~1s — never visibly stalling.

**Architecture:** Three coordinated layers. **(A) Persistence:** keep the process alive whenever there's an active Spotify session, not only while "playing," so every transition is heard. **(B) Reactivity:** drive all UI from `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (system-delivered, sub-second, works even if our own process is suspended) instead of inferring everything from 3s HTTP polling; use polling only as the source of truth for *Spotify-side* changes. **(C) Resilience:** push-to-start tokens, watchdogs, and honest stale states so no single failure mode produces a frozen lie.

**Tech Stack:** Swift / ActivityKit / MediaPlayer framework / AVFoundation / XcodeGen / existing DiagnosticsLog pipeline.

---

## Part 0: What the full API surface actually offers (research findings)

Read through Apple's ActivityKit + MediaPlayer docs and WWDC sessions ("Display live data with Live Activities", "Meet ActivityKit" WWDC23-10184, push-notification update doc). Complete inventory of every mechanism, and its verdict for this app:

| # | Mechanism | What it gives | Verdict |
|---|---|---|---|
| 1 | Local `Activity.update()` | In-app/background updates, **rate-limited** in background | ✅ already used, budget-managed |
| 2 | `Text(timerInterval:)` / `ProgressView(timerInterval:)` | OS-animated time/progress, zero budget | ✅ shipped this session (`LAProgressBar`) |
| 3 | `staleDate` + `context.isStale` | Honest decay when feed stalls | ✅ shipped this session |
| 4 | **APNs Live Activity push** (`liveactivity` push type) | Server-driven updates that bypass app liveness entirely; unmetered at priority 5 | ⛔ needs paid Apple account ($99) + server. **The real answer to "MAKE IT WORK like McDonald's" — blocked by account tier, nothing else.** Documented escape hatch below. |
| 5 | **Push-to-start** (`ActivityAttributes.pushToStartToken`, iOS 17.2+) | Start an LA from outside the app — the literal ask in "pops up without me going to the app" | ⛔ same blocker (server sends it) |
| 6 | `NSSupportsLiveActivitiesFrequentUpdates` | Larger update budget | ✅ already in project.yml |
| 7 | Remote command center (`MPRemoteCommandCenter`) | System delivers pause/play/skip/seek events with exact target positions, even when our poller is asleep or suspended | ✅ **adopt — this is the biggest free win** |
| 8 | `MPNowPlayingInfoCenter` publishing | Makes iOS treat us as the audio session owner; system routes lock-screen transport events reliably | ✅ adopt |
| 9 | `UIApplication.beginBackgroundTask` (~30s grace) | Finish work after backgrounding | ➕ minor, add around transitions |
| 10 | Audio-interruption notifications (`AVAudioSession.interruptionNotification`) | Wake/resume triggers when other audio starts/stops | ➕ already partially wired in keeper; extend logging |
| 11 | WidgetKit timelines (`WidgetCenter.reloadTimelines`) | Home-screen widget updates | out of scope here (separate budget) |
| 12 | Watch Smart Stack (`supplementalActivityFamilies`) | Same LA on watch | out of scope |

**Strategy:** implement everything free now (7, 8, 9, plus persistence and watchdog hardening), and document the exact 30-minute upgrade path to mechanisms 4+5 so Jonathan can flip it on if he ever pays for the dev account.

## Current context / assumptions

- Branch `main` @ `27c31af`; 26 package tests green; latest build installed on iPhone 14 Pro (`00008120-00167C4A0200201E`).
- Shipped and verified working: stall detector + rapid probes, stall-hold keep-alive (`697c683`), self-advancing progress bar, adaptive cadence, staleDate decay.
- Known remaining defects (from tonight's trace): (1) real pause → keep-alive released → iOS suspends process ~60s later → resume unheard for minutes (the 798s gap); (2) LA flips off ~5s after pause despite the 300s rule.
- `BackgroundAudioKeeper` currently only runs when `status == .playing` (+stall hold).
- Polling: 3s normal / 0.7s rapid, 12s per-poll ceiling.

---

## Phase A — Never miss an event (persistence + system event stream)

### Task A1: Session-wide keep-alive with idle downgrade

**Objective:** Process stays alive whenever Spotify is connected & lock-screen lyrics enabled — playing OR paused — so pause→play is always heard. Battery-bounded via idle downgrade.

**Files:**
- Modify: `DynamicallyricsApp/App/AppModel.swift` (`manageKeepAlive`, ~line 317)
- Modify: `DynamicallyricsApp/App/BackgroundAudioKeeper.swift` (add `setIdleVolume`)

**Steps:**
1. Replace the current condition:

```swift
// Keep the process alive for the whole Spotify session, not just playback:
// a paused app that releases its audio session gets suspended by iOS in
// ~60s and never hears the resume. Downgrade volume when idle to be polite;
// keep the session itself active.
let sessionActive = auth.isConnected || demoActive
let shouldRun = sessionActive && lockScreenLyricsEnabled
```
2. In `BackgroundAudioKeeper.start()`, accept `loud: Bool = true`; set `player?.volume = loud ? 0.01 : 0.001`. AppModel calls `keeper.setLoud(status?.state == .playing)`.
3. Build → commit `feat(la): session-wide keep-alive so paused resumes are heard`

### Task A2: Publish Now Playing info + remote commands

**Objective:** Receive play/pause/skip/**seek-with-target-position** as system-push events (<1s) rather than polling artifacts, and give iOS a reason to route them to us even when suspended.

**Files:**
- Create: `DynamicallyricsApp/App/NowPlayingBridge.swift`
- Modify: `DynamicallyricsApp/App/AppModel.swift` (start/stop bridge with session)

```swift
import MediaPlayer

/// Bridges system transport controls into the app's command bus. iOS wakes/
/// routes these to the app that owns the now-playing info even when the
/// process would otherwise be suspended — the free substitute for APNs
/// Live Activity push.
@MainActor
final class NowPlayingBridge {
    private var handlers: [UInt] = []

    func publish(signature: TrackSignature?, position: TimeInterval, duration: TimeInterval?, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: signature?.title ?? "",
            MPMediaItemPropertyArtist: signature?.artist ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func install(toggle: @escaping () async -> Void,
                 next: @escaping () -> Void,
                 previous: @escaping () -> Void,
                 changePosition: @escaping (TimeInterval) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { _ in Task { await toggle() }; return .success }
        center.pauseCommand.addTarget { _ in Task { await toggle() }; return .success }
        center.nextTrackCommand.addTarget { _ in next(); return .success }
        center.previousTrackCommand.addTarget { _ in previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            changePosition(pos)
            return .success
        }
    }
}
```

⚠️ Implementer notes:
- Seek handling: Spotify Web API `PUT /me/player/seek?position_ms=` — add `seek(to:)` alongside `togglePlayPause()` in `SpotifyProvider.swift` (same auth pattern, returns 204). This makes slider drags instant: the command carries the target position, we fire the seek, optimistic local state jumps immediately, next poll confirms.
- When Spotify's own app is foregrounded it reclaims now-playing ownership; our published info simply loses priority until we're the active audio session again. Harmless — our LA continues independently.

Build → commit `feat(la): now-playing bridge + remote seek/toggle commands`

### Task A3: Fix premature LA teardown after pause

**Objective:** LA must stay up ≥300s after pause (current code ends it early).

**Files:** `DynamicallyricsApp/App/AppModel.swift` (`syncLiveActivity` `.paused` branch ~line 343)

**Step 1:** Root cause candidate: single-poll `.stopped` blips end the activity before the paused timer matters. Require confirmation:

```swift
case .paused:
    if pausedAt == nil { pausedAt = .now }
    if Date.now.timeIntervalSince(pausedAt ?? .now) > 300 {
        if liveActivity.isRunning { liveActivity.end() }
        return
    }
case .stopped, .none:
    // Single stopped blips happen right after skips (204/no-device);
    // require two consecutive observations before tearing the LA down.
    stoppedStreak += 1
    if liveActivity.isRunning && stoppedStreak >= 2 {
        if liveActivity.isRunning { liveActivity.end() }
    }
    pausedAt = nil
    if !liveActivity.isRunning { return }
    return  // hold the LA one more tick either way
```
(Adapt to actual structure; the invariant is: `.stopped` needs a streak ≥2, `.paused` owns the 300s rule, and neither may clear the other's timers.)

**Step 2:** Build → commit `fix(la): stop-blip immunity + honor 300s pause window`

---

## Phase B — Sub-second truth for every transition

### Task B1: Event-driven refresh bursts

**Objective:** On ANY remote-command hit or interruption notification, run a 6-poll @0.5s burst regardless of the regular cadence.

**Files:** `DynamicallyricsApp/App/SpotifyProvider.swift`

```swift
func burst(count: Int = 6, interval: Double = 0.5) {
    rapidProbesLeft = max(rapidProbesLeft, count)
    usesRapidProbe = true
}
```
Call sites: `NowPlayingBridge.install` handlers (toggle/next/previous/seek), `BackgroundAudioKeeper.handleInterruption(.ended)`. Combined with A2, user-initiated changes reflect in ≤1 poll cycle.

Build → commit `feat(la): event-driven poll bursts on transport events`

### Task B2: Watchdog — "playing but polls stalled"

**Objective:** Self-heal any silent poller death while status says playing.

**Files:** `DynamicallyricsApp/App/SpotifyProvider.swift`, `DynamicallyricsApp/App/AppModel.swift`

1. Provider: `private(set) var lastSuccessfulPollAt: Date?` set in the 200 branch.
2. Provider: make `start()` safe to call repeatedly — cancel existing `pollTask` first, then recreate (idempotent restart).
3. AppModel tick: if `status == .playing && now - lastSuccessfulPollAt > 6` → `provider.start()` + log `"watchdog: revive"`.

Build → commit `feat(la): poller watchdog revives dead polling during playback`

### Task B3: Stale-API stall hardening for seek/skip storms

**Objective:** Slider scrubbing generates rapid position lies (API reports old positions). Extend the stall detector to treat "position went backwards or froze during playing" as staleness too.

**Files:** `DynamicallyricsApp/App/SpotifyProvider.swift` (poll(), stall section)

```swift
if state.isPlaying, let last = lastAppliedPositionMs, let newPos = state.progressMs,
   newPos <= last, abs(newPos - last) < 1500 {
    staleSeekCount += 1
} else {
    staleSeekCount = 0
}
if staleSeekCount >= 3 { /* treat as stale: don't regress displayed position */ }
```
Guard: never let `apply()` move the displayed position backwards while playing unless the track changed.

Build → commit `fix(la): ignore backwards/frozen position lies while playing`

---

## Phase C — The guaranteed-forever tier (needs $99 account; document, don't build)

### Task C1: Upgrade-path doc

**Objective:** One file spelling out exactly how to get Apple-Music-grade behavior when Jonathan pays for the developer account.

**Files:** Create `Docs/LIVE-ACTIVITY-PUSH.md`

Content outline (with links):
1. Enable Push Notifications capability; app uploads `activity.pushToken` (iOS 16.2+) and `Activity<LyricsActivityAttributes>.pushToStartToken` (iOS 17.2+) to a tiny endpoint (e.g., a Cloudflare Worker storing token per device).
2. Spotify webhook/poller on the server hits APNs with `apns-push-type: liveactivity`, `apns-topic: <bundle>.push-type.liveactivity`, priority 5 loop for line changes, priority 10 for track changes; payload `{"aps":{"timestamp":...,"event":"update","content-state":{...}}}`.
3. Push-to-start payload (`event: start`) fires the LA without the app ever running — the literal "pops up without me going to the app."
4. Cost: $99/yr + pennies of Worker/APNs (free tier suffices). Effort: ~30 min given this repo's attributes/state already exist.

Commit `docs: APNs Live Activity upgrade path`

---

## Verification (Task D, final gate)

1. Install via devicectl; launch once.
2. Protocol (user): open app → lock → from lock screen: play → skip ×3 → drag slider 0:20→0:25 → pause → wait 4 min → play → wait 10 min locked mid-song → unlock.
3. Pull `/tmp/lyrics-diagnostics.log` via `devicectl device copy from`.

**Pass criteria (Python over timestamps):**
- No gap >10s anywhere in the session (session-wide keep-alive holds; watchdog quiet or self-heals).
- Transport-event timestamps (log each bridge hit: `cmd: toggle/next/prev/seek x`) followed by fresh confirming polls ≤1.5s.
- Seek shows optimistic jump instantly; no backwards-position regressions in logs.
- Pause 4 min → LA still visible at 299s, gone by 305s; resume heard ≤1.5s.
- Stall episodes ride out at 0.7s as before (no regression).

## Files likely to change

| File | Change |
|---|---|
| `DynamicallyricsApp/App/AppModel.swift` | session-wide keep-alive, watchdog call, stop-streak fix |
| `DynamicallyricsApp/App/BackgroundAudioKeeper.swift` | idle/loud volume, interruption burst hook |
| `DynamicallyricsApp/App/NowPlayingBridge.swift` | new — remote commands + now-playing publish |
| `DynamicallyricsApp/App/SpotifyProvider.swift` | seek(), idempotent start(), lastSuccessfulPollAt, backwards-guard, bursts |
| `project.yml` | none required (audio background mode already present) |
| `Docs/LIVE-ACTIVITY-PUSH.md` | new — paid-tier upgrade path |

## Risks / tradeoffs / open questions

- **Battery:** session-long silent audio is the price of "never stalls." Volume drops to near-zero when idle; still nonzero cost — acceptable for Jonathan's stated priority ("MAKE IT WORK").
- **Now-playing ownership contention:** Spotify's app fights over `MPNowPlayingInfoCenter` when foregrounded; our LA doesn't depend on winning, only on receiving commands, which persists.
- **Rate limiter:** bursts + session keep-alive increase update pressure slightly; the adaptive cadence + frequent-updates flag absorb this. If updates park anyway, the bar keeps moving (self-rendering) — degradation stays graceful.
- **Open question:** whether iOS truly routes `MPRemoteCommandCenter` events to a suspended-but-audio-session-active app without user pressing a lock-screen button; logs from Task A2 will answer definitively. If not, the fallback remains: session-wide keep-alive prevents suspension in the first place (belt + suspenders by design).
- **The 100% guarantee** ("never stall") is only achievable via Phase C push updates; Phases A+B get empirically close (~1s worst case) with zero cost.
