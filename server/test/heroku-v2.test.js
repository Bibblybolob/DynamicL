import assert from "node:assert/strict";
import test from "node:test";
import { start } from "../src/heroku-v2.js";

async function withServer(fn) {
  const { server } = await start({
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
    await fn(`http://127.0.0.1:${port}`);
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
      }),
    });
    assert.equal(heartbeat.response.status, 200);
    assert.equal(heartbeat.body.accepted, true);
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
