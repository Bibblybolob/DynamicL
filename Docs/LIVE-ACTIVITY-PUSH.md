# Live Activity Push — the server-backed upgrade path

APNs delivery to real devices requires a **paid Apple Developer Program
membership**. The app and Worker path is now present, but bring-up also needs
the APNs/Spotify secrets, a deployed Worker, and the matching sync access token.
The current server updates and ends an existing Live Activity; remote activity
start is still a follow-up.

## 1. Capabilities to add

- App + widget extension: the project already declares Live Activity support and
  `aps-environment: production`; use a provisioning profile with the matching
  environment when signing a device build.
- `project.yml` → app target info properties already have `NSSupportsLiveActivities`
  and `NSSupportsLiveActivitiesFrequentUpdates` — nothing else needed there.

## 2. Tokens the app must upload

```swift
// Per-activity update token (iOS 16.2+), refresh on change:
Task {
    for await data in activity.pushTokenUpdates {
        let token = data.map { String(format: "%02x", $0) }.joined()
        await upload(token: token, kind: .update)
    }
}

// Push-to-start token (iOS 17.2+) — one per attributes type:
for await data in Activity<LyricsActivityAttributes>.pushToStartTokenUpdates {
    let token = data.map { String(format: "%02x", $0) }.joined()
    await upload(token: token, kind: .pushToStart)
}
```

Upload target: any tiny HTTPS endpoint that stores `deviceID → tokens`
(a Cloudflare Worker + KV, free tier is plenty).

## 3. Sending updates from the server

```bash
curl -v \
  --header "apns-topic: com.jonathantran.dynamicallyrics.la.push-type.liveactivity" \
  --header "apns-push-type: liveactivity" \
  --header "apns-priority: 10" \
  --header "authorization: bearer $APNS_JWT" \
  --data '{"aps":{"timestamp":1700000000,"event":"update","content-state":{
      "trackTitle":"Song","artistName":"Artist","currentLine":"…",
      "nextLine":"…","isPlaying":true,
      "progressStart":1700000000,"progressEnd":1700000200}}}' \
  --http2 https://api.push.apple.com/3/device/$UPDATE_TOKEN
```

- Priority **5** = opportunistic/unmetered → use for lyric-line flips.
- Priority **10** = immediate/budgeted → reserve for track changes & play/pause.
- The app captures the **push-to-start token**, but the current worker only
  updates/ends an existing Live Activity. Remote `event: start` is still a
  follow-up because it needs a complete server-side starting state.
- APNs auth: JWT signed with your team's key (.p8) — standard stuff.

Server side: a poller hitting Spotify's `/me/player` every ~5 seconds per
active user (or a Spotify webhook when they ship one) translates changes into
the pushes above. ContentState shape is identical to what the app ships today,
so `LyricsLiveActivity.swift` needs zero changes.

## 4. What becomes unnecessary

Once push is live you can dial back: session-wide keep-alive, watchdogs, and
poll bursts all exist to compensate for process liveness limits. With server
push, a suspended app no longer matters. Keep them as fallback anyway.

## 5. Effort estimate

The current bring-up includes token upload, an authenticated Worker, and the
APNs update/end path. Remote activity start, multi-user storage, and production
onboarding remain separate hardening work.
