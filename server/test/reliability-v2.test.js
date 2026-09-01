import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { MemoryStore, sealForWorker } from "../src/heroku-v2.js";
import {
  activityPayload,
  buildActivityContentState,
  contentStateBytes,
  mergeSpotifyPlayer,
  sendAPNs,
} from "../src/reliability-v2.js";
import { pollInstallation, pollOnce } from "../src/heroku-worker-v2.js";

function key() {
  return crypto.createHash("sha256").update("test-encryption-key").digest();
}

function privateKey() {
  return crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" })
    .privateKey.export({ type: "pkcs8", format: "pem" });
}

function player({ id = "track-1", playing = true, progress = 1_000 } = {}) {
  return {
    is_playing: playing,
    progress_ms: progress,
    timestamp: 1_700_000_000_000,
    item: {
      id,
      name: id === "track-1" ? "Song" : "Next song",
      duration_ms: 180_000,
      artists: [{ name: "Artist" }],
      album: {
        name: "Album",
        images: [{ url: `https://images.test/${id}.jpg`, width: 640 }],
      },
    },
  };
}

test("partial Spotify response preserves the accepted track and artwork", () => {
  const first = mergeSpotifyPlayer(null, player(), 1_000);
  const partial = mergeSpotifyPlayer(first.player, { is_playing: true }, 2_000);
  assert.equal(partial.kind, "partial");
  assert.equal(partial.player.trackID, "track-1");
  assert.equal(partial.player.albumImageURL, "https://images.test/track-1.jpg");
  assert.equal(partial.player.progressMs, 2_000);
});

test("content state uses Unix timestamps and keeps a bounded future schedule", () => {
  const state = buildActivityContentState(
    {
      trackID: "track-1",
      title: "Song",
      artist: "Artist",
      durationMs: 180_000,
      progressMs: 0,
      progressObservedAt: 1_700_000_000_000,
      isPlaying: true,
      albumImageURL: "https://images.test/track-1.jpg",
    },
    Array.from({ length: 80 }, (_, index) => ({ t: index * 2, text: `Line ${index}` })),
    { nowMs: 1_700_000_000_000, offsetMs: -250, revision: 4 },
  );
  assert.equal(state.schemaVersion, 2);
  assert.equal(state.source, "server");
  assert.ok(state.generatedAtEpoch > 1_600_000_000);
  assert.ok((state.scheduledLinesV2?.length ?? 0) > 5);
  assert.ok(contentStateBytes(state) <= 3_500);
});

test("APNs start payload includes the required remote-start fields", () => {
  const payload = activityPayload("start", {
    schemaVersion: 2,
    source: "server",
    revision: 2,
    generatedAtEpoch: 1_700_000_000,
    trackID: "track-1",
    trackTitle: "Song",
    artistName: "Artist",
    albumImageURL: "https://images.test/track-1.jpg",
    currentLine: "♪",
    nextLine: null,
    isPlaying: true,
    scheduledLinesV2: [],
  }, { nowEpoch: 1_700_000_000, inputPushToken: true });
  assert.equal(payload.aps.event, "start");
  assert.equal(payload.aps["attributes-type"], "LyricsActivityAttributes");
  assert.deepEqual(payload.aps.attributes, { sessionID: "lyrics" });
  assert.equal(payload.aps["input-push-token"], 1);
  assert.equal(payload.aps.alert.title, "OpenLyrics");
  assert.equal(payload.aps.sound, undefined);
  assert.equal(payload.aps["relevance-score"], 1);
});

test("worker starts once, then updates the same activity after the update token arrives", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const installation = await store.createInstallation({
    id: "installation-1",
    authHash: "hash",
    refreshTokenCiphertext: sealForWorker("refresh-token-123", encryptionKey),
    state: {
      phoneLeaseExpiresAt: 0,
      spotifyClientID: "spotify-client",
      supportsRemoteStart: true,
      supportsInputPushToken: true,
      autoStartEnabled: true,
      clientSchemaVersion: 2,
      lyricOffsetMs: -250,
      serverRevision: 0,
    },
  });
  await store.upsertActivityToken(
    installation.id,
    "pushToStart",
    sealForWorker("a".repeat(32), encryptionKey),
    { environment: "production" },
  );
  const apns = [];
  let spotifyRequests = 0;
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if (url.includes("accounts.spotify.com")) {
      return Response.json({ access_token: "access-token" });
    }
    if (url.includes("api.spotify.com")) {
      const progress = 1_000 + spotifyRequests * 5_000;
      spotifyRequests += 1;
      return Response.json({ ...player({ progress }) });
    }
    if (url.includes("lrclib.net")) {
      return Response.json({ syncedLyrics: "[00:00.00]First line\n[00:04.00]Second line\n[00:08.00]Third line" });
    }
    if (url.includes("api.push.apple.com")) {
      apns.push({ body: JSON.parse(init.body), headers: init.headers });
      return new Response(null, { status: 200 });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const runtime = {
    env: {
      SPOTIFY_CLIENT_ID: "spotify-client",
      APNS_KEY_P8: privateKey(),
      APNS_KEY_ID: "KEYID123",
      APNS_TEAM_ID: "TEAMID123",
      APNS_HOST: "https://api.push.apple.com",
    },
    store,
    encryptionKey,
  };

  await pollInstallation(installation, runtime, { nowMs: 1_700_000_000_000, fetchImpl });
  assert.equal(apns.length, 1);
  assert.equal(apns[0].body.aps.event, "start");
  assert.equal(apns[0].body.aps["input-push-token"], 1);

  await store.upsertActivityToken(
    installation.id,
    "update",
    sealForWorker("b".repeat(32), encryptionKey),
    { environment: "production" },
  );
  const afterStart = await store.getInstallation(installation.id);
  await pollInstallation(afterStart, runtime, { nowMs: 1_700_000_005_000, fetchImpl });
  assert.equal(apns.length, 2);
  assert.equal(apns[1].body.aps.event, "update");
  assert.equal(apns[1].body.aps["content-state"].trackID, "track-1");
  assert.equal(apns[1].headers["apns-priority"], "10");

  const afterInitialUpdate = await store.getInstallation(installation.id);
  await pollInstallation(afterInitialUpdate, runtime, { nowMs: 1_700_000_010_000, fetchImpl });
  assert.equal(apns.length, 3);
  assert.equal(apns[2].body.aps["content-state"].currentLine, "Third line");
  assert.equal(apns[2].headers["apns-priority"], "10");
  const afterLineUpdate = await store.getInstallation(installation.id);
  assert.equal(afterLineUpdate.state.lastPushReason, "line");
});

test("APNs retries Retry-After responses and returns a redacted delivery result", async () => {
  let attempts = 0;
  const result = await sendAPNs({
    token: "c".repeat(32),
    tokenRecord: { environment: "sandbox" },
    payload: { aps: { event: "update", "content-state": { isPlaying: false } } },
    priority: 5,
    env: {
      APNS_KEY_P8: privateKey(),
      APNS_KEY_ID: "KEYID123",
      APNS_TEAM_ID: "TEAMID123",
      APNS_HOST: "https://api.sandbox.push.apple.com",
    },
    fetchImpl: async () => {
      attempts += 1;
      if (attempts < 2) {
        return new Response(JSON.stringify({ reason: "TooManyRequests" }), {
          status: 429,
          headers: { "Retry-After": "0.25" },
        });
      }
      return new Response(null, { status: 200 });
    },
  });
  assert.equal(result.accepted, true);
  assert.equal(result.attempts, 2);
  assert.equal(result.reason, null);
});

test("worker refreshes once when Spotify rejects an expired player token", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const installation = await store.createInstallation({
    id: "installation-401",
    authHash: "hash-401",
    refreshTokenCiphertext: sealForWorker("refresh-token-401", encryptionKey),
    state: {
      phoneLeaseExpiresAt: 0,
      spotifyClientID: "spotify-client",
      lyricOffsetMs: 0,
      serverRevision: 0,
    },
  });
  let tokenRequests = 0;
  let playerRequests = 0;
  const fetchImpl = async input => {
    const url = String(input);
    if (url.includes("accounts.spotify.com")) {
      tokenRequests += 1;
      return Response.json({ access_token: `access-${tokenRequests}` });
    }
    if (url.includes("api.spotify.com")) {
      playerRequests += 1;
      if (playerRequests === 1) return new Response(null, { status: 401 });
      return Response.json(player());
    }
    if (url.includes("lrclib.net")) {
      return Response.json({ syncedLyrics: "[00:00.00]First line" });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const runtime = {
    env: { SPOTIFY_CLIENT_ID: "spotify-client" },
    store,
    encryptionKey,
  };

  const result = await pollInstallation(installation, runtime, {
    nowMs: 1_700_000_000_000,
    fetchImpl,
  });
  assert.equal(result.trackID, "track-1");
  assert.equal(tokenRequests, 2);
  assert.equal(playerRequests, 2);
});

test("worker uses Spotify Retry-After to avoid hot polling", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const installation = await store.createInstallation({
    id: "installation-429",
    authHash: "hash-429",
    refreshTokenCiphertext: sealForWorker("refresh-token-429", encryptionKey),
    nextPollAt: new Date(0).toISOString(),
    state: {
      phoneLeaseExpiresAt: 0,
      spotifyClientID: "spotify-client",
      lyricOffsetMs: 0,
    },
  });
  const fetchImpl = async input => {
    const url = String(input);
    if (url.includes("accounts.spotify.com")) {
      return new Response(JSON.stringify({ reason: "rate limited" }), {
        status: 429,
        headers: { "Retry-After": "30" },
      });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const runtime = { env: { SPOTIFY_CLIENT_ID: "spotify-client" }, store, encryptionKey };
  await pollOnce(runtime, 1, { fetchImpl });
  const after = await store.getInstallation(installation.id);
  assert.ok(Date.parse(after.nextPollAt) >= Date.now() + 29_000);
  assert.match(after.state.lastError, /429/);
});
