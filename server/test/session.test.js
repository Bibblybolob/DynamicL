import assert from "node:assert/strict";
import test from "node:test";
import { PlaybackSessionV2 } from "../src/session.js";

class MemoryStorage {
  constructor(entries = {}) {
    this.values = new Map(Object.entries(entries));
  }

  async get(key) {
    return this.values.get(key);
  }

  async put(key, value) {
    if (typeof key === "object") {
      for (const [entryKey, entryValue] of Object.entries(key)) {
        this.values.set(entryKey, entryValue);
      }
      return;
    }
    this.values.set(key, value);
  }

  async delete(key) {
    this.values.delete(key);
  }
}

function session(entries = {}, env = {}) {
  return new PlaybackSessionV2(
    { storage: new MemoryStorage(entries) },
    env
  );
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

test("ending an activity sends APNs dismissal-date and clears its token", async () => {
  const current = session({ updateToken: "token" });
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
