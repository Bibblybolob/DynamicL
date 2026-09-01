import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  PlaybackSessionV2,
  buildContentState,
  compactContentState,
  contentStateSize,
  swiftReferenceSeconds,
} from "../src/session.js";

class MemoryStorage {
  constructor(entries = {}) {
    this.values = new Map(Object.entries(entries));
    this.alarm = null;
  }

  async get(key) { return this.values.get(key); }

  async put(key, value) {
    if (typeof key === "object") {
      for (const [entryKey, entryValue] of Object.entries(key)) {
        this.values.set(entryKey, entryValue);
      }
      return;
    }
    this.values.set(key, value);
  }

  async delete(key) { this.values.delete(key); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(value) { this.alarm = value; }
}

function session(entries = {}, env = {}) {
  return new PlaybackSessionV2(
    { storage: new MemoryStorage(entries) },
    env
  );
}

function player(overrides = {}) {
  return {
    trackID: "track-1",
    title: "Test Song",
    artist: "Test Artist",
    albumImageURL: "https://image.test/album.jpg",
    durationMs: 180_000,
    progressMs: 10_250,
    isPlaying: true,
    lines: [
      { t: 0, text: "First line" },
      { t: 10, text: "Second line" },
      { t: 20, text: "Third line" },
    ],
    ...overrides,
  };
}

test("APNs requests use the configured sandbox host and JSON content type", async () => {
  const originalFetch = globalThis.fetch;
  let request;
  globalThis.fetch = async (input, init) => {
    request = { input, init };
    return new Response(null, { status: 200 });
  };

  try {
    const current = session({}, { APNS_HOST: "https://api.sandbox.push.apple.com" });
    current.pushJwt = async () => "jwt";
    const payload = { aps: { event: "update" } };
    assert.equal(await current.apnsRequest("token", payload, 5), 200);
    assert.equal(request.input, "https://api.sandbox.push.apple.com/3/device/token");
    assert.equal(request.init.headers["content-type"], "application/json");
    assert.deepEqual(JSON.parse(request.init.body), payload);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("an expired update token permits remote activity recovery", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 410 });

  try {
    const current = session({
      updateToken: "0123456789abcdef0123456789abcdef",
      pushToStartToken: "abcdef0123456789abcdef0123456789",
      playbackSessionID: "session-1",
      playbackSessionStartAttempted: true,
      lastStartAttemptAt: Date.now(),
    });
    current.pushJwt = async () => "jwt";

    assert.equal(
      await current.apnsRequest(
        "0123456789abcdef0123456789abcdef",
        { aps: { event: "update" } },
        10,
        "update"
      ),
      410
    );
    assert.equal(await current.state.storage.get("updateToken"), "");
    assert.equal(await current.state.storage.get("playbackSessionStartAttempted"), false);
    assert.equal(await current.state.storage.get("lastStartAttemptAt"), 0);
    assert.equal(await current.state.storage.get("playbackSessionDismissed"), undefined);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a terminal APNs device-token reason clears the affected route", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(
    JSON.stringify({ reason: "BadDeviceToken" }),
    { status: 400, headers: { "content-type": "application/json" } }
  );

  try {
    const current = session({
      pushToStartToken: "start-token",
      updateToken: "update-token",
    });
    current.pushJwt = async () => "jwt";

    assert.equal(await current.apnsRequest("start-token", { aps: {} }, 10, "start"), 400);
    assert.equal(await current.state.storage.get("pushToStartToken"), "");
    assert.equal(await current.state.storage.get("updateToken"), "update-token");

    assert.equal(await current.apnsRequest("update-token", { aps: {} }, 10, "update"), 400);
    assert.equal(await current.state.storage.get("updateToken"), "");
    assert.equal(await current.state.storage.get("playbackSessionDismissed"), undefined);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("ending an activity sends dismissal-date and clears its token", async () => {
  const current = session({ updateToken: "token", clientSchemaVersion: 2 });
  let payload;
  current.apnsRequest = async (_token, nextPayload) => {
    payload = nextPayload;
    return 200;
  };
  await current.pushEnd();
  assert.equal(typeof payload.aps["dismissal-date"], "number");
  assert.equal(payload.aps.dismissalDate, undefined);
  assert.equal(await current.state.storage.get("updateToken"), "");
});

test("ending an activity sends a stopped content state", async () => {
  const current = session({
    updateToken: "token",
    clientSchemaVersion: 2,
    activeContentState: buildContentState(player(), { schemaVersion: 2 }),
  });
  let payload;
  current.apnsRequest = async (_token, nextPayload) => {
    payload = nextPayload;
    return 200;
  };
  await current.pushEnd();
  assert.equal(payload.aps["content-state"].isPlaying, false);
  assert.deepEqual(payload.aps["content-state"].scheduledLinesV2, []);
  assert.equal(payload.aps["content-state"].progressStartEpoch, null);
});

test("APNs host validation rejects arbitrary endpoints", () => {
  const current = session({}, { APNS_HOST: "https://example.test" });
  assert.throws(() => current.apnsHost(), /supported Apple push host/);
});

test("schema 2 uses exact millisecond progress and Unix timestamps", () => {
  const nowMs = 1_700_000_000_000;
  const state = buildContentState(player(), {
    nowMs,
    offsetMs: 500,
    schemaVersion: 2,
    revision: 7,
  });
  assert.equal(state.schemaVersion, 2);
  assert.equal(state.source, "server");
  assert.equal(state.revision, 7);
  assert.equal(state.generatedAtEpoch, 1_700_000_000);
  assert.equal(state.progressStartEpoch, 1_699_999_989.75);
  assert.equal(state.currentLine, "First line");
  assert.equal(state.scheduledLinesV2[0].text, "Second line");
  assert.equal(state.scheduledLinesV2[0].dateEpoch, 1_700_000_000.25);
  assert.equal(state.albumImageURL, "https://image.test/album.jpg");
});

test("first-use gate is carried in the shared content state", () => {
  const state = buildContentState(player(), {
    nowMs: 1_700_000_000_000,
    schemaVersion: 2,
    requiresUserStart: true,
  });
  assert.equal(state.requiresUserStart, true);
});

test("the final scheduled lyric has an explicit end boundary", () => {
  const state = buildContentState(player({ progressMs: 0, lines: [
    { t: 0, text: "First" },
    { t: 12, text: "Final" },
  ] }), {
    nowMs: 1_700_000_000_000,
    schemaVersion: 2,
  });
  assert.equal(state.scheduledLinesV2[0].text, "Final");
  assert.equal(state.scheduledLinesV2[0].endDateEpoch, 1_700_000_180);
});

test("server does not schedule lyric lines after the track ends", () => {
  const state = buildContentState(player({
    durationMs: 20_000,
    progressMs: 0,
    lines: [
      { t: 0, text: "First" },
      { t: 12, text: "Last" },
      { t: 21, text: "After track end" },
    ],
  }), {
    nowMs: 1_700_000_000_000,
    schemaVersion: 2,
  });
  assert.deepEqual(state.scheduledLinesV2.map(line => line.text), ["Last"]);
});

test("legacy Swift dates decode to the intended Unix date", () => {
  const unix = 1_700_000_000;
  assert.equal(swiftReferenceSeconds(unix) + 978_307_200, unix);
  const state = buildContentState(player({ progressMs: 0 }), {
    nowMs: unix * 1_000,
    schemaVersion: 1,
  });
  assert.equal(state.progressStart + 978_307_200, unix);
});

test("the shared fixture preserves Unix and Swift reference dates", async () => {
  const fixtureURL = new URL(
    "../../Packages/LyricCore/Tests/Fixtures/activity-state-v2.json",
    import.meta.url
  );
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const state = fixture.state;
  assert.equal(
    state.progressStart + 978_307_200,
    state.progressStartEpoch
  );
  assert.equal(
    new Date(state.generatedAtEpoch * 1_000).toISOString().replace(".000", ""),
    fixture.expectedGeneratedDate
  );
});

test("long lyric schedules remain below the content-state limit", () => {
  const longLines = Array.from({ length: 80 }, (_, index) => ({
    t: index * 2,
    text: `Line ${index} ${"word ".repeat(120)}`,
  }));
  const state = buildContentState(player({ lines: longLines, progressMs: 0 }), {
    nowMs: 1_700_000_000_000,
    schemaVersion: 2,
  });
  assert.ok(contentStateSize(state) <= 3_500);
  assert.equal(state.albumImageURL, "https://image.test/album.jpg");
  assert.ok(state.scheduledLinesV2.length < 24);
});

test("short lyric schedules send more than the old five-line batch", () => {
  const lines = Array.from({ length: 40 }, (_, index) => ({
    t: index * 2,
    text: `Line ${index}`,
  }));
  const state = buildContentState(player({ lines, progressMs: 0 }), {
    nowMs: 1_700_000_000_000,
    schemaVersion: 2,
  });
  assert.equal(state.scheduledLinesV2.length, 32);
  assert.ok(contentStateSize(state) <= 3_500);
});

test("pathological optional metadata is compacted below the Activity limit", () => {
  const oversized = {
    schemaVersion: 2,
    source: "server",
    revision: 4,
    generatedAtEpoch: 1_700_000_000,
    trackID: "track-1",
    trackTitle: "Title",
    artistName: "Artist",
    albumImageURL: "https://image.test/" + "x".repeat(12_000),
    currentLine: "line",
    nextLine: "next",
    isPlaying: true,
    progressStart: 1,
    progressEnd: 2,
    progressStartEpoch: 1_700_000_000,
    progressEndEpoch: 1_700_001_000,
    karaokeStartDate: 1,
    karaokeEndDate: 2,
    karaokeStartEpoch: 1_700_000_000,
    karaokeEndEpoch: 1_700_000_001,
    albumDominantRGB: [0.1, 0.2, 0.3],
  };
  const compact = compactContentState(oversized);
  assert.ok(contentStateSize(compact) <= 3_500);
  assert.equal(compact.currentLine, "line");
  assert.equal(compact.albumImageURL, null);
});

test("same-track partial Spotify data preserves artwork", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      albumImageURL: "https://image.test/kept.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 12_345,
    item: {
      id: "track-1",
      name: "Test Song",
      artists: [{ name: "Artist" }],
      duration_ms: 200_000,
      album: {},
    },
  });
  assert.equal(normalized.albumImageURL, "https://image.test/kept.jpg");
});

test("server preserves Spotify playback event timestamps", async () => {
  const current = session();
  const normalized = await current.normalizedPlayer({
    timestamp: 1_700_000_000_123,
    is_playing: true,
    progress_ms: 12_345,
    item: {
      id: "track-1",
      name: "Test Song",
      artists: [{ name: "Artist" }],
      duration_ms: 200_000,
      album: {},
    },
  });
  assert.equal(normalized.playbackChangeAtMs, 1_700_000_000_123);
  assert.equal(await current.state.storage.get("playbackChangeAtMs"), 1_700_000_000_123);
});

test("server selects the same suitable artwork size as the phone", async () => {
  const current = session();
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 12_345,
    item: {
      id: "track-1",
      name: "Test Song",
      artists: [{ name: "Artist" }],
      duration_ms: 200_000,
      album: {
        images: [
          { url: "https://image.test/large.jpg", width: 640, height: 640 },
          { url: "https://image.test/suitable.jpg", width: 300, height: 300 },
          { url: "https://image.test/small.jpg", width: 64, height: 64 },
        ],
      },
    },
  });
  assert.equal(normalized.albumImageURL, "https://image.test/suitable.jpg");
});

test("same-track partial Spotify data preserves projected progress", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      progressMs: 20_000,
      progressObservedAt: Date.now() - 1_000,
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    item: { id: "track-1", name: "Test Song", album: {} },
  });
  assert.ok(normalized.progressMs >= 20_900);
  assert.ok(normalized.progressMs <= 21_200);
});

test("same-track null Spotify progress preserves projected progress", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      progressMs: 20_000,
      progressObservedAt: Date.now() - 1_000,
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: null,
    item: { id: "track-1", name: "Test Song", album: {} },
  });
  assert.ok(normalized.progressMs >= 20_900);
  assert.ok(normalized.progressMs <= 21_200);
});

test("same-track partial Spotify data preserves the trusted play state", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Test Song",
      artist: "Test Artist",
      durationMs: 200_000,
      progressMs: 20_000,
      isPlaying: true,
      progressObservedAt: Date.now() - 1_000,
    },
  });
  const normalized = await current.normalizedPlayer({
    progress_ms: null,
    item: { id: "track-1", name: "Test Song", artists: [{ name: "Test Artist" }], album: {} },
  });
  assert.equal(normalized.isPlaying, true);
  assert.equal(normalized.completed, false);
  assert.ok(normalized.progressMs >= 20_900);
});

test("server does not push once per lyric line when a future schedule exists", async () => {
  const current = session({
    lastSentTrackID: "track-1",
    lastSentPlaying: true,
    lastSentAlbumImageURL: "https://image.test/album.jpg",
    lastSentCurrentLine: "Old line",
    lastSentNextLine: "Next line",
    lastSentScheduleV2: [{ dateEpoch: Date.now() / 1_000 + 20, text: "Next line" }],
    lastPushAt: Date.now(),
  });
  const reason = await current.updateReason({
    trackID: "track-1",
    isPlaying: true,
    currentLine: "New line",
    nextLine: "Next line",
    albumImageURL: "https://image.test/album.jpg",
    scheduledLinesV2: [{ dateEpoch: Date.now() / 1_000 + 40, text: "Later line" }],
  }, {});
  assert.equal(reason, "schedule");
});

test("a new playback session reopens the closed-session gate", async () => {
  const current = session({
    playbackSessionID: "old-session",
    playbackSessionClosed: true,
    playbackSessionStartAttempted: true,
    playbackSessionDismissed: true,
    dismissalSource: "phone",
  });

  await current.beginPlaybackSession("track-2");

  assert.equal(await current.state.storage.get("playbackSessionClosed"), false);
  assert.equal(await current.state.storage.get("playbackSessionStartAttempted"), false);
  assert.equal(await current.state.storage.get("playbackSessionDismissed"), false);
  assert.equal(await current.state.storage.get("dismissalSource"), null);
  assert.match(await current.state.storage.get("playbackSessionID"), /-track-2$/);
});

test("server sends a lyric correction for paused content", async () => {
  const current = session({
    lastSentTrackID: "track-1",
    lastSentPlaying: false,
    lastSentAlbumImageURL: "https://image.test/album.jpg",
    lastSentCurrentLine: "Old line",
    lastSentNextLine: "Next line",
    lastPushAt: Date.now(),
  });
  const reason = await current.updateReason({
    trackID: "track-1",
    isPlaying: false,
    currentLine: "New line",
    nextLine: "Next line",
    albumImageURL: "https://image.test/album.jpg",
    scheduledLinesV2: [],
  }, {});
  assert.equal(reason, "line");
});

test("server sends playback events with urgent priority", async () => {
  const current = session({
    updateToken: "token",
    clientSchemaVersion: 2,
    playbackChangeAtMs: 1_700_000_000_123,
    lastSentPlaybackChangeAtMs: 1_700_000_000_000,
    lastSentTrackID: "track-1",
    lastSentPlaying: true,
    lastSentAlbumImageURL: "https://image.test/album.jpg",
    lastSentCurrentLine: "Line",
    lastSentNextLine: null,
    lastSentScheduleV2: [],
    lastPushAt: Date.now(),
  });
  let priority;
  current.apnsRequest = async (_token, _payload, nextPriority) => {
    priority = nextPriority;
    return 200;
  };
  await current.pushUpdate({
    trackID: "track-1",
    trackTitle: "Test Song",
    artistName: "Test Artist",
    albumImageURL: "https://image.test/album.jpg",
    currentLine: "Line",
    nextLine: null,
    isPlaying: true,
    scheduledLinesV2: [],
  }, "playback event");
  assert.equal(priority, 10);
});

test("server sends a playing lyric correction when no future schedule exists", async () => {
  const current = session({
    lastSentTrackID: "track-1",
    lastSentPlaying: true,
    lastSentAlbumImageURL: "https://image.test/album.jpg",
    lastSentCurrentLine: "Old line",
    lastSentNextLine: null,
    lastSentScheduleV2: [],
    lastPushAt: Date.now(),
  });
  const reason = await current.updateReason({
    trackID: "track-1",
    isPlaying: true,
    currentLine: "New line",
    nextLine: null,
    albumImageURL: "https://image.test/album.jpg",
    scheduledLinesV2: [],
  }, {});
  assert.equal(reason, "line");
});

test("completed normalized player state is not treated as playing", async () => {
  const current = session({
    activeTrack: { trackID: "track-1", progressMs: 179_000, progressObservedAt: Date.now() },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: false,
    progress_ms: 179_500,
    item: {
      id: "track-1",
      name: "Finished",
      duration_ms: 180_000,
      album: {},
    },
  });
  assert.equal(normalized.completed, true);
  assert.equal(normalized.isPlaying, false);
});

test("a near-end paused sample keeps the server-owned activity alive", async () => {
  const current = session({
    updateToken: "token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
    activeContentState: buildContentState(player(), { schemaVersion: 2 }),
  });
  let endReason;
  current.pushEnd = async reason => {
    endReason = reason;
    await current.state.storage.put("updateToken", "");
    return true;
  };
  current.fetchPlayer = async () => ({
    player: {
      is_playing: false,
      progress_ms: 179_500,
      item: {
        id: "track-1",
        name: "Test Song",
        artists: [{ name: "Test Artist" }],
        duration_ms: 180_000,
        album: { images: [{ url: "https://image.test/album.jpg" }] },
      },
    },
  });
  current.lyricsFor = async () => [];
  current.pushUpdate = async () => true;

  await current.tick();

  assert.equal(endReason, undefined);
  assert.equal(await current.state.storage.get("updateToken"), "token");
  assert.equal((await current.state.storage.get("activeTrack")).trackID, "track-1");
  assert.equal((await current.state.storage.get("activeTrack")).isPlaying, false);
  assert.equal(await current.state.storage.get("isPlaying"), false);
});

test("two confirmed no-item samples end the server-owned activity", async () => {
  const current = session({
    updateToken: "token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
    activeContentState: buildContentState(player(), { schemaVersion: 2 }),
  });
  let endCount = 0;
  current.pushEnd = async () => {
    endCount += 1;
    await current.state.storage.put("updateToken", "");
    return true;
  };
  current.fetchPlayer = async () => ({ player: null });

  await current.tick();
  assert.equal(endCount, 0);
  await current.tick();
  assert.equal(endCount, 1);
  assert.equal(await current.state.storage.get("activeTrack"), null);
  assert.equal(await current.state.storage.get("activeContentState"), null);
});

test("a failed activity end keeps the server session for retry", async () => {
  const current = session({
    updateToken: "token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
  });
  current.pushEnd = async () => false;

  assert.equal(await current.closePlaybackSession("track completed"), false);
  assert.equal(await current.state.storage.get("updateToken"), "token");
  assert.equal(await current.state.storage.get("playbackSessionID"), "session-1");
  assert.notEqual(await current.state.storage.get("playbackSessionClosed"), true);
});

test("a failed long-pause end does not publish another paused state", async () => {
  const current = session({
    updateToken: "token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
    pausedAt: Date.now() - 11 * 60 * 1_000,
    activeTrack: player({ isPlaying: false, progressMs: 20_000 }),
  });
  current.fetchPlayer = async () => ({
    player: {
      is_playing: false,
      progress_ms: 20_000,
      item: {
        id: "track-1",
        name: "Test Song",
        artists: [{ name: "Test Artist" }],
        duration_ms: 180_000,
        album: { images: [{ url: "https://image.test/album.jpg" }] },
      },
    },
  });
  current.pushEnd = async () => false;
  current.lyricsFor = async () => {
    throw new Error("lyrics lookup must not run after a failed end");
  };

  await current.tick();

  assert.equal(await current.state.storage.get("updateToken"), "token");
  assert.equal(await current.state.storage.get("playbackSessionID"), "session-1");
  assert.notEqual(await current.state.storage.get("activeContentState"), null);
});

test("server polling cannot clear a phone-owned session after a missing item", async () => {
  const current = session({
    phoneLeaseExpiresAt: Date.now() + 10_000,
    updateToken: "server-token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
    noItemSamples: 1,
    activeTrack: player(),
    activeContentState: buildContentState(player(), { schemaVersion: 2 }),
  });
  current.fetchPlayer = async () => ({ player: null });

  await current.tick();

  assert.equal(await current.state.storage.get("noItemSamples"), 1);
  assert.equal(await current.state.storage.get("playbackSessionID"), "session-1");
  assert.equal(await current.state.storage.get("updateToken"), "server-token");
  assert.notEqual(await current.state.storage.get("activeContentState"), null);
});

test("server polling cannot close a phone-owned session after a long pause", async () => {
  const current = session({
    phoneLeaseExpiresAt: Date.now() + 10_000,
    updateToken: "server-token",
    playbackSessionID: "session-1",
    playbackSessionClosed: false,
    pausedAt: Date.now() - 11 * 60 * 1_000,
    activeTrack: player({ isPlaying: false, progressMs: 20_000 }),
  });
  current.fetchPlayer = async () => ({
    player: {
      is_playing: false,
      progress_ms: 20_000,
      item: {
        id: "track-1",
        name: "Test Song",
        artists: [{ name: "Test Artist" }],
        duration_ms: 180_000,
        album: { images: [{ url: "https://image.test/album.jpg" }] },
      },
    },
  });
  current.lyricsFor = async () => [];

  await current.tick();

  assert.equal(await current.state.storage.get("playbackSessionID"), "session-1");
  assert.equal(await current.state.storage.get("updateToken"), "server-token");
  assert.notEqual(await current.state.storage.get("playbackSessionClosed"), true);
});

test("same-track partial Spotify data preserves title, artist, and duration", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Test Song",
      artist: "Test Artist",
      durationMs: 200_000,
      albumImageURL: "https://image.test/kept.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 12_345,
    item: { id: "track-1", album: {} },
  });
  assert.equal(normalized.title, "Test Song");
  assert.equal(normalized.artist, "Test Artist");
  assert.equal(normalized.durationMs, 200_000);
});

test("same-track zero duration preserves the trusted duration", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Test Song",
      artist: "Test Artist",
      durationMs: 200_000,
      albumImageURL: "https://image.test/kept.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 12_345,
    item: {
      id: "track-1",
      name: "Test Song",
      artists: [{ name: "Test Artist" }],
      duration_ms: 0,
      album: {},
    },
  });
  assert.equal(normalized.durationMs, 200_000);
});

test("same-track partial Spotify data without an ID preserves identity and artwork", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Test Song",
      artist: "Test Artist",
      durationMs: 200_000,
      albumImageURL: "https://image.test/kept.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 12_345,
    item: { name: "Test Song", artists: [{ name: "Test Artist" }], album: {} },
  });
  assert.equal(normalized.trackID, "track-1");
  assert.equal(normalized.albumImageURL, "https://image.test/kept.jpg");
});

test("an ID-less response with a different album does not inherit artwork", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Same Song",
      artist: "Same Artist",
      albumName: "Original Album",
      durationMs: 200_000,
      albumImageURL: "https://image.test/original.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 0,
    item: {
      name: "Same Song",
      artists: [{ name: "Same Artist" }],
      album: { name: "Remix Album" },
      duration_ms: 201_000,
    },
  });
  assert.notEqual(normalized.trackID, "track-1");
  assert.equal(normalized.albumName, "Remix Album");
  assert.equal(normalized.albumImageURL, null);
});

test("legacy ID-less album metadata does not inherit an unknown old cover", async () => {
  const current = session({
    activeTrack: {
      trackID: "track-1",
      title: "Same Song",
      artist: "Same Artist",
      durationMs: 200_000,
      albumImageURL: "https://image.test/unknown-old.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 0,
    item: {
      name: "Same Song",
      artists: [{ name: "Same Artist" }],
      album: { name: "Reported Album" },
      duration_ms: 200_000,
    },
  });
  assert.notEqual(normalized.trackID, "track-1");
  assert.equal(normalized.albumImageURL, null);
});

test("a verified new track never uses the previous album", async () => {
  const current = session({
    activeTrack: {
      trackID: "old-track",
      albumImageURL: "https://image.test/old.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 0,
    item: {
      id: "new-track",
      name: "New Song",
      artists: [{ name: "Artist" }],
      duration_ms: 200_000,
      album: {},
    },
  });
  assert.equal(normalized.albumImageURL, null);
});

test("a different Spotify ID does not inherit artwork from a same-title track", async () => {
  const current = session({
    activeTrack: {
      trackID: "old-track",
      title: "Same Song",
      artist: "Same Artist",
      albumImageURL: "https://image.test/old.jpg",
    },
  });
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 0,
    item: {
      id: "new-track",
      name: "Same Song",
      artists: [{ name: "Same Artist" }],
      duration_ms: 200_000,
      album: {},
    },
  });
  assert.equal(normalized.trackID, "new-track");
  assert.equal(normalized.albumImageURL, null);
});

test("remote start sends one complete start request per playback session", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsInputPushToken: true,
    autoStartEnabled: true,
    clientSchemaVersion: 2,
    playbackSessionID: "session-1",
    playbackSessionStartAttempted: false,
    playbackSessionDismissed: false,
  });
  const requests = [];
  current.apnsRequest = async (...args) => {
    requests.push(args);
    return 200;
  };
  const state = buildContentState(player(), { schemaVersion: 2 });
  await current.startActivityIfNeeded(state);
  await current.startActivityIfNeeded(state);

  assert.equal(requests.length, 1);
  const payload = requests[0][1];
  assert.equal(payload.aps.event, "start");
  assert.equal(payload.aps["attributes-type"], "LyricsActivityAttributes");
  assert.deepEqual(payload.aps.attributes, { sessionID: "lyrics" });
  assert.equal(payload.aps["input-push-token"], 1);
  assert.equal(payload.aps.alert.title, "OpenLyrics");
  assert.match(payload.aps.alert.body, /Test Song/);
  assert.equal(payload.aps.alert.sound, undefined);
  assert.equal(payload.aps["content-state"].albumImageURL, "https://image.test/album.jpg");
  const finalScheduledLine = payload.aps["content-state"].scheduledLinesV2.at(-1);
  assert.ok(finalScheduledLine.endDateEpoch > finalScheduledLine.dateEpoch);
  assert.ok(payload.aps["stale-date"] >= finalScheduledLine.endDateEpoch + 15);
});

test("remote start omits the iOS 18 input token option when unsupported", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsInputPushToken: false,
    autoStartEnabled: true,
    clientSchemaVersion: 2,
    playbackSessionID: "session-ios-17",
    playbackSessionStartAttempted: false,
    playbackSessionDismissed: false,
  });
  let payload;
  current.apnsRequest = async (_token, request) => {
    payload = request;
    return 200;
  };

  await current.startActivityIfNeeded(buildContentState(player(), { schemaVersion: 2 }));

  assert.equal(payload.aps["input-push-token"], undefined);
  assert.equal(payload.aps.event, "start");
});

test("remote first-use start preserves the Show Lyrics gate", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsInputPushToken: true,
    autoStartEnabled: true,
    clientSchemaVersion: 2,
    playbackSessionID: "session-first-use",
    playbackSessionStartAttempted: false,
    playbackSessionDismissed: false,
    requiresUserStart: true,
  });
  let payload;
  current.apnsRequest = async (_token, request) => {
    payload = request;
    return 200;
  };

  await current.startActivityIfNeeded(
    buildContentState(player(), { schemaVersion: 2, requiresUserStart: true })
  );

  assert.equal(payload.aps.event, "start");
  assert.equal(payload.aps["content-state"].requiresUserStart, true);
});

test("remote start does not duplicate a known active phone activity", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsRemoteStart: true,
    autoStartEnabled: true,
    phoneActivityState: "active",
    phoneLeaseExpiresAt: Date.now() + 15_000,
    playbackSessionStartAttempted: false,
  });
  let requestCount = 0;
  current.apnsRequest = async () => {
    requestCount += 1;
    return 200;
  };
  await current.startActivityIfNeeded(buildContentState(player(), { schemaVersion: 2 }));
  assert.equal(requestCount, 0);
});

test("remote start is sent before a slow lyric lookup completes", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsInputPushToken: true,
    autoStartEnabled: true,
    clientSchemaVersion: 2,
    playbackSessionStartAttempted: false,
    playbackSessionDismissed: false,
  });
  const events = [];
  current.fetchPlayer = async () => ({
    player: {
      is_playing: true,
      progress_ms: 1_000,
      item: {
        id: "track-1",
        name: "Test Song",
        artists: [{ name: "Test Artist" }],
        duration_ms: 180_000,
        album: { images: [{ url: "https://image.test/album.jpg" }] },
      },
    },
  });
  current.lyricsFor = async () => {
    events.push("lyrics-start");
    await new Promise(resolve => setTimeout(resolve, 20));
    events.push("lyrics-finished");
    return [{ t: 0, text: "First line" }, { t: 12, text: "Second line" }];
  };
  current.apnsRequest = async (_token, payload) => {
    events.push("apns-start");
    assert.equal(payload.aps.event, "start");
    assert.equal(payload.aps["content-state"].currentLine, "♪");
    return 200;
  };

  await current.tick();

  assert.deepEqual(events, ["apns-start", "lyrics-start", "lyrics-finished"]);
  assert.equal((await current.state.storage.get("activeContentState")).currentLine, "First line");
});

test("an expired phone lease does not block remote recovery", async () => {
  const current = session({
    pushToStartToken: "start-token",
    supportsRemoteStart: true,
    autoStartEnabled: true,
    phoneActivityState: "active",
    phoneLeaseExpiresAt: Date.now() - 1,
    playbackSessionStartAttempted: false,
  });
  let requestCount = 0;
  current.apnsRequest = async () => {
    requestCount += 1;
    return 200;
  };
  await current.startActivityIfNeeded(buildContentState(player(), { schemaVersion: 2 }));
  assert.equal(requestCount, 1);
});

test("a phone heartbeat owns updates for 15 seconds", async () => {
  const current = session({ pushToStartToken: "start-token" });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "none",
      clientSchemaVersion: 2,
      localRevision: 3,
      sentAtMs: Date.now(),
      lyricOffsetMs: 250,
      requiresUserStart: true,
    }),
  }));
  const body = await response.json();
  assert.equal(body.writer, "phone");
  assert.equal(await current.currentWriter(), "phone");
  assert.ok(body.leaseExpiresAt > Date.now() + 14_000);
  assert.equal(await current.state.storage.get("requiresUserStart"), true);
});

test("a phone heartbeat without an explicit end preserves the server activity token", async () => {
  const current = session({
    updateToken: "server-token",
    phoneActivityState: "active",
  });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "none",
      clientSchemaVersion: 2,
      localRevision: 5,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
    }),
  }));
  assert.equal(response.status, 200);
  assert.equal(await current.state.storage.get("updateToken"), "server-token");
});

test("an explicit phone activity end clears the server activity token", async () => {
  const current = session({
    updateToken: "server-token",
    phoneActivityState: "active",
  });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "none",
      activityEnded: true,
      clientSchemaVersion: 2,
      localRevision: 6,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
    }),
  }));
  assert.equal(response.status, 200);
  assert.equal(await current.state.storage.get("updateToken"), "");
});

test("a legacy heartbeat does not clear the first-use gate", async () => {
  const current = session({ requiresUserStart: true });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "none",
      clientSchemaVersion: 1,
      localRevision: 4,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
    }),
  }));
  assert.equal(response.status, 200);
  assert.equal(await current.state.storage.get("requiresUserStart"), true);
});

test("an older phone heartbeat cannot overwrite newer activity state", async () => {
  const current = session();
  const fresh = Date.now();
  const first = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "active",
      updateToken: "0123456789abcdef0123456789abcdef",
      clientSchemaVersion: 2,
      localRevision: 8,
      sentAtMs: fresh,
      trackID: "new-track",
      lyricOffsetMs: 300,
    }),
  }));
  assert.equal((await first.json()).accepted, true);

  const stale = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "dismissed",
      clientSchemaVersion: 2,
      localRevision: 7,
      sentAtMs: fresh - 1_000,
      trackID: "old-track",
      lyricOffsetMs: -900,
    }),
  }));
  const body = await stale.json();
  assert.equal(body.accepted, false);
  assert.equal(body.stale, true);
  assert.equal(await current.state.storage.get("phoneActivityState"), "active");
  assert.equal(await current.state.storage.get("phoneTrackID"), "new-track");
  assert.equal(await current.state.storage.get("updateToken"), "0123456789abcdef0123456789abcdef");
  assert.notEqual(await current.state.storage.get("playbackSessionDismissed"), true);
});

test("commands are idempotent and use the current playback state", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (input, init) => {
    calls += 1;
    assert.equal(input, "https://api.spotify.com/v1/me/player/pause");
    assert.equal(init.method, "PUT");
    return new Response(null, { status: 204 });
  };
  try {
    const current = session({
      accessToken: "access",
      accessTokenExpiresAt: Date.now() + 120_000,
      refreshToken: "refresh-token",
      isPlaying: true,
    });
    const request = () => current.fetch(new Request("https://session/command", {
      method: "POST",
      body: JSON.stringify({ command: "toggle", commandID: "command-123", issuedAtMs: Date.now() }),
    }));
    assert.equal((await (await request()).json()).accepted, true);
    assert.equal((await (await request()).json()).accepted, true);
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("bootstrap registration issues a private server token", async () => {
  const current = session({}, { SPOTIFY_CLIENT_ID: "client-id" });
  current.accessToken = async () => "access-token";
  const response = await current.fetch(new Request("https://session/register", {
    method: "POST",
    body: JSON.stringify({
      bootstrap: true,
      pushToStartToken: "abcdef0123456789abcdef0123456789",
      spotifyRefreshToken: "refresh-token-123",
      clientSchemaVersion: 2,
    }),
  }));
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.ok, true);
  assert.equal(typeof body.authToken, "string");
  assert.equal(body.authToken.length, 64);
  assert.equal(await current.state.storage.get("clientAuthToken"), body.authToken);

  const authorized = await current.fetch(new Request("https://session/authorize", {
    method: "POST",
    body: JSON.stringify({ token: body.authToken }),
  }));
  assert.equal(authorized.status, 200);
});

test("bootstrap registration cannot replace an existing pairing", async () => {
  const current = session({ clientAuthToken: "existing-token" }, {
    SPOTIFY_CLIENT_ID: "client-id",
  });
  const response = await current.fetch(new Request("https://session/register", {
    method: "POST",
    body: JSON.stringify({
      bootstrap: true,
      pushToStartToken: "abcdef0123456789abcdef0123456789",
      spotifyRefreshToken: "refresh-token-123",
    }),
  }));
  assert.equal(response.status, 401);
});

test("expired commands are rejected before contacting Spotify", async () => {
  const current = session({
    accessToken: "access",
    accessTokenExpiresAt: Date.now() + 60_000,
    isPlaying: true,
  });
  const response = await current.fetch(new Request("https://session/command", {
    method: "POST",
    body: JSON.stringify({ command: "next", commandID: "command-123", issuedAtMs: Date.now() - 9_000 }),
  }));
  assert.equal(response.status, 400);
});

test("future commands are rejected before contacting Spotify", async () => {
  const current = session({ isPlaying: true });
  const response = await current.fetch(new Request("https://session/command", {
    method: "POST",
    body: JSON.stringify({ command: "next", commandID: "command-123", issuedAtMs: Date.now() + 9_000 }),
  }));
  assert.equal(response.status, 400);
});

test("a heartbeat without color does not erase the current track color", async () => {
  const current = session({
    albumDominantRGB: [0.2, 0.4, 0.8],
    albumDominantTrackID: "track-1",
  });
  await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "none",
      clientSchemaVersion: 2,
      localRevision: 3,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
      trackID: "track-1",
    }),
  }));
  const normalized = await current.normalizedPlayer({
    is_playing: true,
    progress_ms: 100,
    item: {
      id: "track-1",
      name: "Test Song",
      artists: [{ name: "Artist" }],
      duration_ms: 180_000,
      album: {},
    },
  });
  assert.deepEqual(normalized.albumDominantRGB, [0.2, 0.4, 0.8]);
});

test("status separates server readiness from reachability", async () => {
  const current = session({ refreshToken: "refresh-token", pushToStartToken: "start-token" }, {
    SPOTIFY_CLIENT_ID: "client-id",
    APNS_KEY_P8: "key",
    APNS_KEY_ID: "key-id",
    APNS_TEAM_ID: "team-id",
  });
  const status = await current.fetch(new Request("https://session/status"));
  const body = await status.json();
  assert.equal(body.spotifyReady, true);
  assert.equal(body.apnsReady, true);
  assert.equal(body.serverReady, true);
  assert.equal(body.pushToStartAvailable, true);
});

test("status never returns the Spotify refresh token", async () => {
  const refreshToken = "refresh-token-that-must-stay-private";
  const current = session({
    refreshToken,
    pushToStartToken: "start-token",
  }, {
    SPOTIFY_CLIENT_ID: "client-id",
  });

  const response = await current.fetch(new Request("https://session/status"));
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.refreshToken, undefined);
  assert.equal(JSON.stringify(body).includes(refreshToken), false);
  assert.equal(body.spotifyReady, true);
});

test("the server lyric cache stays bounded", async () => {
  const current = session();
  for (let index = 0; index < 105; index++) {
    await current.cacheLyrics(`lyrics:track-${index}`, [{ t: 0, text: `Line ${index}` }]);
  }
  const index = await current.state.storage.get("lyricsCacheIndex");
  assert.equal(index.length, 100);
  assert.equal(await current.state.storage.get("lyrics:track-0"), undefined);
  assert.deepEqual(await current.state.storage.get("lyrics:track-104"), [{ t: 0, text: "Line 104" }]);
});

test("the last LRC offset declaration wins", async () => {
  const { parseLRC } = await import("../src/session.js");
  assert.deepEqual(parseLRC("[offset:100]\n[offset:250]\n[00:01.00]Line"), [{ t: 0.75, text: "Line" }]);
});

test("an update-token 410 clears the token without inventing a dismissal", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("gone", { status: 410 });
  try {
    const current = session({ updateToken: "token" });
    current.pushJwt = async () => "jwt";
    assert.equal(await current.apnsRequest("token", { aps: {} }, 10, "update"), 410);
    assert.equal(await current.state.storage.get("updateToken"), "");
    assert.notEqual(await current.state.storage.get("playbackSessionDismissed"), true);
    assert.equal(await current.state.storage.get("phoneActivityState"), "none");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("only an explicit dismissed heartbeat records user dismissal", async () => {
  const current = session({ updateToken: "token" });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "dismissed",
      clientSchemaVersion: 2,
      localRevision: 4,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
    }),
  }));
  const body = await response.json();
  assert.equal(body.playbackSessionDismissed, true);
  assert.equal(body.dismissalSource, "phone");
  assert.equal(await current.state.storage.get("updateToken"), "");
});

test("a new active update token clears an obsolete dismissal", async () => {
  const current = session({
    playbackSessionDismissed: true,
    dismissalSource: "phone",
  });
  const response = await current.fetch(new Request("https://session/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      activityState: "active",
      updateToken: "new-token",
      clientSchemaVersion: 2,
      localRevision: 5,
      sentAtMs: Date.now(),
      lyricOffsetMs: 0,
    }),
  }));
  const body = await response.json();
  assert.equal(body.playbackSessionDismissed, false);
  assert.equal(body.dismissalSource, null);
  assert.equal(await current.state.storage.get("updateToken"), "new-token");
});
