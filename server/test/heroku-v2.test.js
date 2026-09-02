import assert from "node:assert/strict";
import test from "node:test";
import { embeddedWorkerEnabled, start } from "../src/heroku-v2.js";

test("the production web dyno runs the polling worker by default", () => {
  assert.equal(embeddedWorkerEnabled({ NODE_ENV: "production" }), true);
  assert.equal(embeddedWorkerEnabled({ NODE_ENV: "production", EMBEDDED_WORKER_ENABLED: "false" }), false);
  assert.equal(embeddedWorkerEnabled({ NODE_ENV: "test" }), false);
});

async function withServer(fn) {
  const { server, runtime } = await start({
    env: {
      NODE_ENV: "test",
      TOKEN_ENCRYPTION_KEY: "test-encryption-key",
      APNS_KEY_P8: "configured-for-status",
      SPOTIFY_CLIENT_ID: "client-id",
    },
    port: 0,
  });
  const port = server.address().port;
  try {
    await fn(`http://127.0.0.1:${port}`, runtime);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}

async function json(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    headers: { "content-type": "application/json", ...(init.headers ?? {}) },
  });
  return { response, body: await response.json() };
}

test("v1 registration accepts push-to-start only and returns a private token", async () => {
  await withServer(async base => {
    const registered = await json(`${base}/v1/register`, {
      method: "POST",
      body: JSON.stringify({
        pushToStartToken: "abcdef0123456789abcdef0123456789",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
        lyricOffsetMs: -250,
      }),
    });
    assert.equal(registered.response.status, 200);
    assert.equal(typeof registered.body.authToken, "string");
    assert.equal(registered.body.authToken.length, 64);
    assert.equal(registered.body.pushToStartAvailable, true);

    const status = await json(`${base}/v1/status`, {
      headers: { authorization: `Bearer ${registered.body.authToken}` },
    });
    assert.equal(status.response.status, 200);
    assert.equal(status.body.payloadSchema, 2);
    assert.equal(status.body.readiness.spotify, true);
    assert.equal(JSON.stringify(status.body).includes("refresh-token-123"), false);
  });
});

test("heartbeat rejects stale phone state and command IDs are idempotent", async () => {
  await withServer(async base => {
    const registered = await json(`${base}/register`, {
      method: "POST",
      body: JSON.stringify({
        updateToken: "0123456789abcdef0123456789abcdef",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
      }),
    });
    const auth = { authorization: `Bearer ${registered.body.authToken}` };
    const heartbeat = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "active",
        updateToken: "0123456789abcdef0123456789abcdef",
        sentAtMs: 1_700_000_000_000,
        localRevision: 8,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
        trackID: "track-1",
        contentState: {
          schemaVersion: 2,
          source: "phone",
          revision: 8,
          generatedAtEpoch: 1_700_000_000,
          trackID: "track-1",
          trackTitle: "Living Room",
          artistName: "Not For Radio",
          currentLine: "And it goes around like this",
          nextLine: "Next line",
          isPlaying: true,
          scheduledLinesV2: [
            { dateEpoch: 1_700_000_004, endDateEpoch: 1_700_000_008, text: "Next line" },
          ],
        },
      }),
    });
    assert.equal(heartbeat.response.status, 200);
    assert.equal(heartbeat.body.accepted, true);
    assert.equal(heartbeat.body.contentAccepted, true);
    const status = await json(`${base}/status`, { headers: auth });
    assert.equal(status.body.schedule.count, 1);
    assert.equal(status.body.schedule.horizonEpoch, 1_700_000_008);
    assert.equal(status.body.payloadSize > 0, true);
    const stale = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "active",
        sentAtMs: 1_699_999_999_000,
        localRevision: 99,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
      }),
    });
    assert.equal(stale.body.stale, true);

    const commandBody = {
      command: "next",
      commandID: "command-1234",
      issuedAtMs: Date.now(),
    };
    const first = await json(`${base}/command`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify(commandBody),
    });
    const second = await json(`${base}/command`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify(commandBody),
    });
    assert.equal(first.response.status, 202);
    assert.deepEqual(second.body, first.body);
  });
});

test("heartbeat rejects a completed state for a different track", async () => {
  await withServer(async base => {
    const registered = await json(`${base}/register`, {
      method: "POST",
      body: JSON.stringify({
        updateToken: "0123456789abcdef0123456789abcdef",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
      }),
    });
    const result = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: { authorization: `Bearer ${registered.body.authToken}` },
      body: JSON.stringify({
        activityState: "active",
        sentAtMs: Date.now(),
        localRevision: 1,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
        trackID: "track-new",
        contentState: {
          schemaVersion: 2,
          revision: 1,
          generatedAtEpoch: Date.now() / 1_000,
          trackID: "track-old",
          trackTitle: "Old song",
          artistName: "Artist",
          currentLine: "Old lyric",
          isPlaying: true,
        },
      }),
    });
    assert.equal(result.response.status, 400);
    assert.match(result.body.error, /does not match/);
  });
});

test("a metadata-free loading heartbeat remains valid", async () => {
  await withServer(async base => {
    const registered = await json(`${base}/register`, {
      method: "POST",
      body: JSON.stringify({
        updateToken: "0123456789abcdef0123456789abcdef",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
      }),
    });
    const result = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: { authorization: `Bearer ${registered.body.authToken}` },
      body: JSON.stringify({
        activityState: "active",
        sentAtMs: Date.now(),
        localRevision: 1,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
        contentState: {
          schemaVersion: 2,
          revision: 1,
          generatedAtEpoch: Date.now() / 1_000,
          trackTitle: "OpenLyrics",
          artistName: "Spotify",
          currentLine: "Waiting for Spotify playback…",
          isPlaying: false,
        },
      }),
    });
    assert.equal(result.response.status, 200);
    assert.equal(result.body.accepted, true);
    assert.equal(result.body.contentAccepted, false);
  });
});

test("an unhealthy phone yields its writer lease without erasing server backoff", async () => {
  await withServer(async (base, runtime) => {
    const registered = await json(`${base}/register`, {
      method: "POST",
      body: JSON.stringify({
        updateToken: "0123456789abcdef0123456789abcdef",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
      }),
    });
    const auth = { authorization: `Bearer ${registered.body.authToken}` };
    const result = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "active",
        sentAtMs: Date.now(),
        localRevision: 2,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
        phoneReady: false,
      }),
    });
    assert.equal(result.response.status, 200);
    assert.equal(result.body.writer, "server");
    assert.equal(result.body.leaseExpiresAt, 0);

    const status = await json(`${base}/status`, { headers: auth });
    assert.equal(status.body.currentOwner, "server");

    const installation = await runtime.store.firstInstallation();
    const serverBackoff = new Date(Date.now() + 120_000).toISOString();
    await runtime.store.updateInstallation(installation.id, { nextPollAt: serverBackoff });
    const repeatedYield = await json(`${base}/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "active",
        sentAtMs: Date.now() + 1,
        localRevision: 3,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
        phoneReady: false,
      }),
    });
    assert.equal(repeatedYield.response.status, 200);
    const afterRepeatedYield = await runtime.store.getInstallation(installation.id);
    assert.equal(afterRepeatedYield.nextPollAt, serverBackoff);
  });
});

test("a replacement activity clears an obsolete server dismissal", async () => {
  await withServer(async base => {
    const oldToken = "0123456789abcdef0123456789abcdef";
    const newToken = "abcdef0123456789abcdef0123456789";
    const registered = await json(`${base}/v1/register`, {
      method: "POST",
      body: JSON.stringify({
        updateToken: oldToken,
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
      }),
    });
    const auth = { authorization: `Bearer ${registered.body.authToken}` };

    const dismissed = await json(`${base}/v1/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "dismissed",
        sentAtMs: 1_700_000_000_000,
        localRevision: 1,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
      }),
    });
    assert.equal(dismissed.body.playbackSessionDismissed, true);
    assert.equal(dismissed.body.dismissalSource, "phone");

    const replacementRegistration = await json(`${base}/v1/register`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        updateToken: newToken,
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
      }),
    });
    assert.equal(replacementRegistration.body.playbackSessionDismissed, false);

    const active = await json(`${base}/v1/heartbeat`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({
        activityState: "active",
        updateToken: newToken,
        sentAtMs: 1_700_000_001_000,
        localRevision: 2,
        clientSchemaVersion: 2,
        lyricOffsetMs: 0,
      }),
    });
    assert.equal(active.body.playbackSessionDismissed, false);
    assert.equal(active.body.dismissalSource, null);
  });
});

test("registration fails closed when token encryption is absent", async () => {
  const { server } = await start({ env: { NODE_ENV: "production" }, port: 0 });
  const port = server.address().port;
  try {
    const result = await json(`http://127.0.0.1:${port}/v1/register`, {
      method: "POST",
      body: JSON.stringify({
        pushToStartToken: "abcdef0123456789abcdef0123456789",
        spotifyRefreshToken: "refresh-token-123",
      }),
    });
    assert.equal(result.response.status, 503);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});
