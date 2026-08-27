# OpenLyrics sync server (Cloudflare Worker)

Polls Spotify every ~5s while music plays, computes the current lyric line
(LRCLIB), and pushes Live Activity updates over APNs — independent of the app.

## One-time setup

    cd server
    npm install
    npx wrangler login                      # browser popup -> Allow
    npx wrangler deploy

## Secrets

`APNS_HOST` is configured as a non-secret Worker variable and defaults to the
production APNs host. Development-device tokens must use
`https://api.sandbox.push.apple.com`; TestFlight/App Store tokens use the
production host.

    npx wrangler secret put APNS_KEY_P8       # paste the full .p8 file contents
    npx wrangler secret put APNS_KEY_ID       # 4G6T5TV7Y6
    npx wrangler secret put APNS_TEAM_ID      # 643P4Q6FLQ
    npx wrangler secret put SPOTIFY_CLIENT_ID # 6401f24daeea4c2aa4e333778dff01a2
    npx wrangler secret put SYNC_AUTH_TOKEN    # long random token shared with the app

## Register the phone

The app does this automatically once its "Live sync server" fields contain the
deployed URL and the same access token (it POSTs the update token + Spotify
refresh token to /register). Keep the access token private; registration,
status, and reset are protected.

Watch it work: `npx wrangler tail`
