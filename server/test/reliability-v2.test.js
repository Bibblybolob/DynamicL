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
import { fetchPlayer, pollInstallation, pollOnce } from "../src/heroku-worker-v2.js";

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

test("player lookup confirms an empty currently-playing response with full state", async () => {
  const requests = [];
  const result = await fetchPlayer("access-token", async input => {
    const url = String(input);
    requests.push(url);
    if (url.endsWith("/currently-playing")) {
      return new Response(null, { status: 204 });
    }
    return Response.json(player());
  });
  assert.equal(result.player.item.id, "track-1");
  assert.deepEqual(requests, [
    "https://api.spotify.com/v1/me/player/currently-playing",
    "https://api.spotify.com/v1/me/player",
  ]);
});

test("player lookup uses the currently-playing response without a second request", async () => {
  let requests = 0;
  const result = await fetchPlayer("access-token", async input => {
    requests += 1;
    assert.equal(String(input), "https://api.spotify.com/v1/me/player/currently-playing");
    return Response.json(player());
  });
  assert.equal(result.player.item.id, "track-1");
  assert.equal(requests, 1);
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

test("content state carries recovery lyrics past one minute", () => {
  const nowMs = 1_700_000_000_000;
  const state = buildActivityContentState(
    {
      trackID: "track-1",
      title: "Song",
      artist: "Artist",
      durationMs: 180_000,
      progressMs: 0,
      progressObservedAt: nowMs,
      isPlaying: true,
      albumImageURL: "https://images.test/track-1.jpg",
    },
    Array.from({ length: 13 }, (_, index) => ({ t: index * 10, text: `L${index}` })),
    { nowMs, revision: 5 },
  );
  const horizon = state.scheduledLinesV2?.at(-1)?.dateEpoch ?? 0;
  assert.ok(horizon >= nowMs / 1_000 + 110);
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
      return Response.json({
        syncedLyrics: [
          "[00:00.00]First line",
          "[00:04.00]Second line",
          "[00:08.00]Third line",
          "[00:12.00]Fourth line",
          "[00:16.00]Fifth line",
          "[00:20.00]Sixth line",
          "[00:24.00]Seventh line",
        ].join("\n"),
      });
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
  assert.equal(apns[1].headers["apns-collapse-id"], "openlyrics-current-state");

  const afterInitialUpdate = await store.getInstallation(installation.id);
  await pollInstallation(afterInitialUpdate, runtime, { nowMs: 1_700_000_010_000, fetchImpl });
  assert.equal(apns.length, 2, "a scheduled lyric boundary must not use APNs");

  // Simulate the phone entering a game and its ownership lease expiring. The
  // first server pass sends one urgent handoff even though the old schedule
  // still has runway.
  await store.updateInstallation(installation.id, {
    state: { lastUpdateOwner: "phone", phoneLeaseExpiresAt: 0 },
  });
  const afterPhoneSuspended = await store.getInstallation(installation.id);
  await pollInstallation(afterPhoneSuspended, runtime, {
    nowMs: 1_700_000_015_000,
    fetchImpl,
  });
  assert.equal(apns.length, 3);
  assert.equal(apns[2].headers["apns-priority"], "10");
  const afterTakeover = await store.getInstallation(installation.id);
  assert.equal(afterTakeover.state.lastPushReason, "phone takeover");
  assert.equal(afterTakeover.state.lastUpdateOwner, "server");

  await pollInstallation(afterTakeover, runtime, {
    nowMs: 1_700_000_020_000,
    fetchImpl,
  });
  assert.equal(apns.length, 3, "later scheduled lines must not repeat the handoff");
});

test("phone lease completes pending and prepared-but-unsent lyrics", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const nowMs = 1_700_000_000_000;
  const activeTrack = {
    trackID: "track-1",
    title: "Song",
    artist: "Artist",
    durationMs: 180_000,
    progressMs: 1_000,
    progressObservedAt: nowMs,
    isPlaying: true,
    albumImageURL: "https://images.test/track-1.jpg",
  };
  const installation = await store.createInstallation({
    id: "installation-pending-lyrics",
    authHash: "hash-pending-lyrics",
    refreshTokenCiphertext: sealForWorker("refresh-token", encryptionKey),
    state: {
      phoneLeaseExpiresAt: nowMs + 15_000,
      phoneActivityState: "active",
      phoneTrackID: "track-1",
      spotifyTrackID: "track-1",
      activeTrack,
      lyricStatus: "pending",
      lyricOffsetMs: 0,
      serverRevision: 2,
      lastSentTrackID: "track-1",
      lastSentCurrentLine: "♪",
      lastSentNextLine: null,
      lastSentScheduleV2: [],
      lastSentPlaying: true,
    },
  });
  await store.upsertActivityToken(
    installation.id,
    "update",
    sealForWorker("d".repeat(32), encryptionKey),
    { environment: "production" },
  );
  await store.saveDocument({
    contentHash: "cached-lyrics",
    trackID: "track-1",
    source: "lrclib",
    expiresAt: new Date(nowMs + 60_000).toISOString(),
    document: {
      schemaVersion: 2,
      trackID: "track-1",
      title: "Song",
      artist: "Artist",
      durationSec: 180,
      source: "lrclib",
      contentHash: "cached-lyrics",
      lines: [
        { t: 0, text: "First line" },
        { t: 4, text: "Second line" },
      ],
    },
  });

  const apns = [];
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if (url.includes("api.push.apple.com")) {
      apns.push({ body: JSON.parse(init.body), headers: init.headers });
      return new Response(null, { status: 200 });
    }
    throw new Error(`pending lyric recovery must not poll ${url}`);
  };
  const runtime = {
    env: {
      APNS_KEY_P8: privateKey(),
      APNS_KEY_ID: "KEYID123",
      APNS_TEAM_ID: "TEAMID123",
      APNS_HOST: "https://api.push.apple.com",
    },
    store,
    encryptionKey,
  };

  const result = await pollInstallation(installation, runtime, { nowMs, fetchImpl });

  assert.equal(result.owner, "phone");
  assert.equal(result.completed, "pending-lyrics");
  assert.equal(apns.length, 1);
  assert.equal(apns[0].body.aps.event, "update");
  assert.equal(apns[0].body.aps["content-state"].currentLine, "First line");
  assert.equal(apns[0].headers["apns-priority"], "10");
  const after = await store.getInstallation(installation.id);
  assert.equal(after.state.lyricStatus, "ready");
  assert.equal(after.state.phoneLeaseExpiresAt, nowMs + 15_000);

  // Reproduce the other race: lookup finished and stored the complete state,
  // but the phone lease became active before that state reached APNs.
  await store.updateInstallation(installation.id, {
    state: {
      lyricStatus: "ready",
      lastSentTrackID: "track-1",
      lastSentCurrentLine: "♪",
      lastSentNextLine: null,
      lastSentScheduleV2: [],
    },
  });
  const preparedButUnsent = await store.getInstallation(installation.id);
  const second = await pollInstallation(preparedButUnsent, runtime, {
    nowMs: nowMs + 1_000,
    fetchImpl,
  });
  assert.equal(second.completed, "pending-lyrics");
  assert.equal(apns.length, 2);
  assert.equal(apns[1].body.aps["content-state"].currentLine, "First line");
});

test("phone lease relays a completed phone state without a server player sample", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const nowMs = 1_700_000_000_000;
  const completedState = {
    schemaVersion: 2,
    source: "phone",
    revision: 12,
    generatedAtEpoch: nowMs / 1_000,
    trackID: "track-phone",
    trackTitle: "Living Room",
    artistName: "Not For Radio",
    albumImageURL: "https://images.test/living-room.jpg",
    currentLine: "And it goes around like this",
    nextLine: "Next line",
    isPlaying: true,
    scheduledLinesV2: [
      {
        dateEpoch: nowMs / 1_000 + 4,
        endDateEpoch: nowMs / 1_000 + 8,
        text: "Next line",
      },
    ],
  };
  const installation = await store.createInstallation({
    id: "installation-phone-content",
    authHash: "hash-phone-content",
    refreshTokenCiphertext: sealForWorker("refresh-token", encryptionKey),
    state: {
      phoneLeaseExpiresAt: nowMs + 15_000,
      phoneActivityState: "active",
      phoneTrackID: "track-phone",
      lyricStatus: "ready",
      activeContentState: completedState,
      lastUpdateOwner: "phone",
      lastSentTrackID: "track-phone",
      lastSentCurrentLine: "Finding lyrics…",
      lastSentNextLine: null,
      lastSentScheduleV2: [],
      lastSentPlaying: true,
      serverRevision: 4,
    },
  });
  await store.upsertActivityToken(
    installation.id,
    "update",
    sealForWorker("e".repeat(32), encryptionKey),
    { environment: "production" },
  );

  const apns = [];
  const runtime = {
    env: {
      APNS_KEY_P8: privateKey(),
      APNS_KEY_ID: "KEYID123",
      APNS_TEAM_ID: "TEAMID123",
      APNS_HOST: "https://api.push.apple.com",
    },
    store,
    encryptionKey,
  };
  const result = await pollInstallation(installation, runtime, {
    nowMs,
    fetchImpl: async (input, init = {}) => {
      const url = String(input);
      if (url.includes("api.push.apple.com")) {
        apns.push({ body: JSON.parse(init.body), headers: init.headers });
        return new Response(null, { status: 200 });
      }
      throw new Error(`phone content relay must not poll ${url}`);
    },
  });

  assert.equal(result.completed, "pending-lyrics");
  assert.equal(apns.length, 1);
  assert.equal(apns[0].body.aps["content-state"].currentLine, completedState.currentLine);
  assert.equal(apns[0].headers["apns-priority"], "10");
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

test("worker preserves a long Spotify Retry-After window", async () => {
  const encryptionKey = key();
  const store = new MemoryStore();
  const installation = await store.createInstallation({
    id: "installation-long-429",
    authHash: "hash-long-429",
    refreshTokenCiphertext: sealForWorker("refresh-token-long-429", encryptionKey),
    nextPollAt: new Date(0).toISOString(),
    state: {
      phoneLeaseExpiresAt: 0,
      spotifyClientID: "spotify-client",
      lyricOffsetMs: 0,
    },
  });
  const fetchImpl = async input => {
    if (String(input).includes("accounts.spotify.com")) {
      return new Response(null, {
        status: 429,
        headers: { "Retry-After": "7200" },
      });
    }
    throw new Error(`unexpected URL ${input}`);
  };
  const runtime = { env: { SPOTIFY_CLIENT_ID: "spotify-client" }, store, encryptionKey };
  await pollOnce(runtime, 1, { fetchImpl });
  const after = await store.getInstallation(installation.id);
  assert.ok(Date.parse(after.nextPollAt) >= Date.now() + 7_199_000);
});
