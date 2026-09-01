import assert from "node:assert/strict";
import test from "node:test";
import worker from "../src/worker.js";

function testEnv({ token = "secret", sessionFetch = async () => json({ ok: true }) } = {}) {
  const stub = {
    fetch: sessionFetch,
  };
  return {
    ...(token == null ? {} : { SYNC_AUTH_TOKEN: token }),
    SESSION: {
      idFromName: () => "main",
      get: () => stub,
    },
  };
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function body(response) {
  return JSON.parse(await response.text());
}

test("health is public", async () => {
  const response = await worker.fetch(new Request("https://sync.test/health"), testEnv());
  assert.equal(response.status, 200);
  assert.deepEqual(await body(response), { ok: true, service: "dynamicallyrics-sync" });
});

test("protected routes reject missing or invalid credentials", async () => {
  const missing = await worker.fetch(new Request("https://sync.test/status"), testEnv());
  assert.equal(missing.status, 401);

  const invalid = await worker.fetch(
    new Request("https://sync.test/status", { headers: { authorization: "Bearer wrong" } }),
    testEnv()
  );
  assert.equal(invalid.status, 401);
});

test("protected routes fail closed when the server token is not configured", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/status"),
    testEnv({ token: null })
  );
  assert.equal(response.status, 503);
});

test("registration can bootstrap without a server token", async () => {
  let forwarded;
  const response = await worker.fetch(
    new Request("https://sync.test/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pushToStartToken: "abcdef0123456789abcdef0123456789",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
      }),
    }),
    testEnv({
      token: null,
      sessionFetch: async (input, init) => {
        forwarded = { input, body: JSON.parse(init.body) };
        return json({ ok: true, authToken: "server-token" });
      },
    })
  );
  assert.equal(response.status, 200);
  assert.equal(forwarded.input, "https://session/register");
  assert.equal(forwarded.body.bootstrap, true);
});

test("dynamic server tokens authorize protected routes", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/status", {
      headers: { authorization: "Bearer dynamic-token" },
    }),
    testEnv({
      token: null,
      sessionFetch: async (input) => input.endsWith("/authorize")
        ? json({ ok: true })
        : json({ ok: true }),
    })
  );
  assert.equal(response.status, 200);
});

test("registration validates input and forwards authenticated requests", async () => {
  let forwarded;
  const response = await worker.fetch(
    new Request("https://sync.test/register", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        updateToken: "0123456789abcdef0123456789abcdef",
        pushToStartToken: "",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
        lyricOffsetMs: 250,
        requiresUserStart: false,
      }),
    }),
    testEnv({
      sessionFetch: async (input, init) => {
        forwarded = { input, init, body: JSON.parse(init.body) };
        return json({ ok: true });
      },
    })
  );

  assert.equal(response.status, 200);
  assert.equal(forwarded.input, "https://session/register");
  assert.equal(forwarded.init.method, "POST");
  assert.equal(forwarded.body.updateToken, "0123456789abcdef0123456789abcdef");
  assert.equal(forwarded.body.clientSchemaVersion, 2);
  assert.equal(forwarded.body.lyricOffsetMs, 250);
  assert.equal(forwarded.body.requiresUserStart, false);
});

test("registration accepts only a push-to-start token", async () => {
  let forwarded;
  const response = await worker.fetch(
    new Request("https://sync.test/register", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        pushToStartToken: "abcdef0123456789abcdef0123456789",
        spotifyRefreshToken: "refresh-token-123",
        clientSchemaVersion: 2,
        supportsInputPushToken: true,
      }),
    }),
    testEnv({
      sessionFetch: async (input, init) => {
        forwarded = { input, body: JSON.parse(init.body) };
        return json({ ok: true });
      },
    })
  );
  assert.equal(response.status, 200);
  assert.equal(forwarded.input, "https://session/register");
  assert.equal(forwarded.body.updateToken, undefined);
  assert.equal(forwarded.body.supportsInputPushToken, true);
});

test("heartbeat validates and forwards the phone writer lease", async () => {
  let forwarded;
  const response = await worker.fetch(
    new Request("https://sync.test/heartbeat", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        activityState: "active",
        updateToken: "0123456789abcdef0123456789abcdef",
        sentAtMs: 1_700_000_000_000,
        localRevision: 8,
        trackID: "track-1",
        lyricOffsetMs: -300,
        clientSchemaVersion: 2,
        requiresUserStart: true,
      }),
    }),
    testEnv({
      sessionFetch: async (input, init) => {
        forwarded = { input, body: JSON.parse(init.body) };
        return json({ ok: true, writer: "phone" });
      },
    })
  );
  assert.equal(response.status, 200);
  assert.equal(forwarded.input, "https://session/heartbeat");
  assert.equal(forwarded.body.activityState, "active");
  assert.equal(forwarded.body.localRevision, 8);
  assert.equal(forwarded.body.requiresUserStart, true);
});

test("heartbeat rejects an unknown activity state", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/heartbeat", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({ activityState: "hidden", clientSchemaVersion: 2 }),
    }),
    testEnv()
  );
  assert.equal(response.status, 400);
});

test("heartbeat forwards an explicit activity end separately from a plain none state", async () => {
  let forwarded;
  const response = await worker.fetch(
    new Request("https://sync.test/heartbeat", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        activityState: "none",
        activityEnded: true,
        sentAtMs: Date.now(),
        localRevision: 9,
        lyricOffsetMs: 0,
        clientSchemaVersion: 2,
      }),
    }),
    testEnv({
      sessionFetch: async (input, init) => {
        forwarded = { input, body: JSON.parse(init.body) };
        return json({ ok: true, accepted: true });
      },
    })
  );
  assert.equal(response.status, 200);
  assert.equal(forwarded.input, "https://session/heartbeat");
  assert.equal(forwarded.body.activityState, "none");
  assert.equal(forwarded.body.activityEnded, true);
});

test("heartbeat rejects a non-boolean activity end flag", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/heartbeat", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        activityState: "none",
        activityEnded: "true",
        sentAtMs: Date.now(),
        localRevision: 9,
        lyricOffsetMs: 0,
        clientSchemaVersion: 2,
      }),
    }),
    testEnv()
  );
  assert.equal(response.status, 400);
});

test("registration rejects a JSON null payload", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/register", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: "null",
    }),
    testEnv()
  );
  assert.equal(response.status, 400);
});

test("unknown paths and wrong methods return 404", async () => {
  const response = await worker.fetch(
    new Request("https://sync.test/status", {
      method: "POST",
      headers: { authorization: "Bearer secret" },
    }),
    testEnv()
  );
  assert.equal(response.status, 404);
});
