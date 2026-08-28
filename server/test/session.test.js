import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  PlaybackSessionV2,
  buildContentState,
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
    }),
  }));
  const body = await response.json();
  assert.equal(body.writer, "phone");
  assert.equal(await current.currentWriter(), "phone");
  assert.ok(body.leaseExpiresAt > Date.now() + 14_000);
});

test("an update-token 410 records dismissal for the current session", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("gone", { status: 410 });
  try {
    const current = session({ updateToken: "token" });
    current.pushJwt = async () => "jwt";
    assert.equal(await current.apnsRequest("token", { aps: {} }, 10, "update"), 410);
    assert.equal(await current.state.storage.get("updateToken"), "");
    assert.equal(await current.state.storage.get("playbackSessionDismissed"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
