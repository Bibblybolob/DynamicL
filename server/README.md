# OpenLyrics sync server

This Cloudflare Worker polls Spotify and sends Live Activity updates through APNs.
It is a fallback for the iPhone app.

The phone sends a heartbeat every five seconds.
The heartbeat gives the phone a 15-second update lease.
The server polls Spotify during the lease, but it does not send Activity updates.
The server becomes the update source after the lease ends.

The server polls every five seconds during playback.
It polls every 10 seconds when playback is stopped.

## Set up the server

```sh
cd server
npm install
npx wrangler login
npx wrangler deploy
```

## Set the secrets

Use these commands. Enter each value when Wrangler asks for it.

```sh
npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put SPOTIFY_CLIENT_ID
npx wrangler secret put SYNC_AUTH_TOKEN
```

`APNS_HOST` uses the production APNs host by default.
TestFlight and App Store builds use the production host.
Local development builds can use `https://api.sandbox.push.apple.com`.

Keep `SYNC_AUTH_TOKEN`, `APNS_KEY_P8`, and the Spotify refresh token private.

## Register the phone

Enter the Worker URL and server access token in OpenLyrics.
The app sends `POST /register` with the Spotify refresh token and at least one
Activity token. The first registration can contain only a push-to-start token.

The app sends `POST /heartbeat` while its Spotify data is healthy.
The request includes the Activity state, track ID, lyric offset, schema version,
and phone revision.

All service routes except `/health` require the server access token.

## Check the service

`GET /status` reports the current update source, phone lease, playback session,
start result, payload size, lyric schedule, and artwork state.

Use this command to view live logs:

```sh
npx wrangler tail
```

## Run tests

```sh
npm test
```
