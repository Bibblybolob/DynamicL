# Live Activity Push — the paid-tier upgrade path

Everything in this doc is blocked by exactly one thing: Apple requires a **paid
Apple Developer Program membership ($99/yr)** to send APNs pushes, including
Live Activity push. The moment you have that (plus a ~free Cloudflare Worker),
you get Apple-Music/McDonald's-grade behavior: the Live Activity starts without
the app ever running, updates bypass app liveness entirely, and "never stalls"
becomes literal.

## 1. Capabilities to add

- App + widget extension: Push Notifications capability (`aps-environment: development`).
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
  --header "apns-topic: com.jonathantran.dynamicallyrics.push-type.liveactivity" \
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
- `event: start` with the **push-to-start token** starts the LA remotely —
  this is the "pops up without me going to the app" mechanism.
- APNs auth: JWT signed with your team's key (.p8) — standard stuff.

Server side: a poller hitting Spotify's `/me/player` once per second per
active user (or a Spotify webhook when they ship one) translates changes into
the pushes above. ContentState shape is identical to what the app ships today,
so `LyricsLiveActivity.swift` needs zero changes.

## 4. What becomes unnecessary

Once push is live you can dial back: session-wide keep-alive, watchdogs, and
poll bursts all exist to compensate for process liveness limits. With server
push, a suspended app no longer matters. Keep them as fallback anyway.

## 5. Effort estimate

~30 minutes of code (token upload + Worker) given everything in this repo
already speaks the right ContentState shape.
