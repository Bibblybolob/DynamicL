# OpenLyrics sync server

This Cloudflare Worker polls Spotify and sends Live Activity updates through APNs.
It is a fallback for the iPhone app.

The phone sends a heartbeat every five seconds.
The heartbeat gives the phone a 15-second update lease.
The server polls Spotify during the lease, but it does not send Activity updates.
The server becomes the update source after the lease ends.

The server polls every five seconds during playback.
It polls every 10 seconds when playback is stopped.
It sends a bounded batch of up to 32 lyric lines that covers up to 75 seconds.
It refills the batch when fewer than three lines or fewer than 20 seconds
remain. It does not send one push for every lyric line.

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
```

`APNS_HOST` uses the production APNs host by default.
TestFlight and App Store builds use the production host.
Local development builds can use `https://api.sandbox.push.apple.com`.

`SYNC_AUTH_TOKEN` is optional. If it is omitted, the first valid app
registration creates a private per-install token. Keep `APNS_KEY_P8` and all
Spotify tokens private.

## Register the phone

OpenLyrics contains the managed server URL. The user only needs to configure
the Spotify Client ID in `SpotifyConfig.swift` and sign in to Spotify.
The app sends `POST /register` with the Spotify refresh token and at least one
Activity token. The first registration validates the Spotify token and returns
a private per-install server token. The app stores this token in Keychain.

The app sends `POST /heartbeat` while its Spotify data is healthy.
The request includes the Activity state, track ID, lyric offset, schema version,
and phone revision.

All service routes except `/health` require the private server token. A static
`SYNC_AUTH_TOKEN` can still be configured for backward-compatible deployments,
but new deployments do not need it.

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

## Deploy to Heroku

The Heroku app is `open-lyrics`. The Heroku runtime uses `src/heroku.js` and
the `DATABASE` Postgres add-on. The Cloudflare Worker remains available with
the Wrangler commands above.

From the repository root, deploy only the `server` directory:

```sh
heroku git:remote -a open-lyrics
git subtree push --prefix server heroku main
```

Set these config variables in the Heroku dashboard. Keep all values private:

```text
APNS_HOST=https://api.push.apple.com
APNS_KEY_P8=<Apple private key contents>
APNS_KEY_ID=<Apple key ID>
APNS_TEAM_ID=<Apple team ID>
SPOTIFY_CLIENT_ID=<Spotify client ID>
```

`DATABASE_URL` is supplied automatically by Heroku Postgres. The service
requires this variable so that session state survives a dyno restart. Do not
add `SYNC_AUTH_TOKEN` when using the built-in app pairing flow.
