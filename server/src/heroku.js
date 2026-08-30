import http from "node:http";
import pg from "pg";
import worker from "./worker.js";
import { PlaybackSessionV2 } from "./session.js";

const { Pool } = pg;
const PORT = Number(process.env.PORT ?? 3000);
const MAX_BODY_BYTES = 512 * 1024;
const DEFAULT_APNS_HOST = "https://api.push.apple.com";

if (!process.env.DATABASE_URL) {
  console.error("DATABASE_URL is required for the Heroku sync server.");
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5,
  connectionTimeoutMillis: 10_000,
  idleTimeoutMillis: 30_000,
  ssl: process.env.NODE_ENV === "production"
    ? { rejectUnauthorized: false }
    : undefined,
});

const storage = new PostgresState(pool);
await storage.init();

const state = { storage };
const env = {
  ...process.env,
  APNS_HOST: process.env.APNS_HOST || DEFAULT_APNS_HOST,
  SESSION: {
    idFromName() {
      return "main";
    },
    get() {
      return sessionStub;
    },
  },
};
const session = new PlaybackSessionV2(state, env);
const sessionStub = {
  fetch(input, init) {
    return session.fetch(new Request(input, init));
  },
};

let operation = Promise.resolve();
let wakeTimer;

const server = http.createServer(async (incoming, outgoing) => {
  try {
    const body = await readBody(incoming);
    const headers = new Headers();
    for (const [name, value] of Object.entries(incoming.headers)) {
      if (Array.isArray(value)) headers.set(name, value.join(", "));
      else if (value != null) headers.set(name, value);
    }
    const request = new Request(
      `http://${incoming.headers.host || "localhost"}${incoming.url || "/"}`,
      {
        method: incoming.method,
        headers,
        body: body.length > 0 && incoming.method !== "GET" && incoming.method !== "HEAD"
          ? body
          : undefined,
      },
    );
    const response = await serial(() => worker.fetch(request, env));
    outgoing.statusCode = response.status;
    response.headers.forEach((value, name) => outgoing.setHeader(name, value));
    if (incoming.method === "HEAD") {
      outgoing.end();
      return;
    }
    outgoing.end(Buffer.from(await response.arrayBuffer()));
    scheduleWake();
  } catch (error) {
    console.error("request failed", error?.stack || error);
    if (!outgoing.headersSent) {
      outgoing.statusCode = 500;
      outgoing.setHeader("content-type", "application/json");
      outgoing.end(JSON.stringify({ error: "internal server error" }));
    } else {
      outgoing.end();
    }
  }
});

server.listen(PORT, "0.0.0.0", async () => {
  if (await storage.get("refreshToken") && !storage.alarmAt) {
    await storage.setAlarm(Date.now() + 1_000);
  }
  scheduleWake();
  console.log(`OpenLyrics sync server listening on port ${PORT}`);
});

process.on("SIGTERM", async () => {
  clearTimeout(wakeTimer);
  server.close();
  await pool.end();
});

function serial(task) {
  const next = operation.then(task, task);
  operation = next.catch(() => undefined);
  return next;
}

function scheduleWake() {
  clearTimeout(wakeTimer);
  if (!storage.alarmAt) return;
  const delay = Math.max(10, Math.min(storage.alarmAt - Date.now(), 2_147_000_000));
  wakeTimer = setTimeout(() => {
    serial(async () => {
      await storage.deleteAlarm();
      await session.alarm();
    }).catch(error => console.error("scheduled poll failed", error?.stack || error))
      .finally(scheduleWake);
  }, delay);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", chunk => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        request.resume();
        reject(new Error("request body too large"));
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

class PostgresState {
  constructor(database) {
    this.database = database;
    this.cache = new Map();
    this.initialized = false;
    this.alarmAt = null;
  }

  async init() {
    if (this.initialized) return;
    await this.database.query(`
      CREATE TABLE IF NOT EXISTS openlyrics_state (
        "key" TEXT PRIMARY KEY,
        "value" JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    const result = await this.database.query(
      'SELECT "key", "value" FROM openlyrics_state',
    );
    for (const row of result.rows) this.cache.set(row.key, row.value);
    this.alarmAt = finiteTimestamp(this.cache.get("alarmAt"));
    this.initialized = true;
  }

  async get(key) {
    await this.init();
    return this.cache.get(key);
  }

  async put(keyOrValues, value) {
    await this.init();
    const values = typeof keyOrValues === "string"
      ? [[keyOrValues, value]]
      : Object.entries(keyOrValues || {});
    const entries = values.filter(([, item]) => item !== undefined);
    const removals = values.filter(([, item]) => item === undefined).map(([key]) => key);
    const client = await this.database.connect();
    try {
      await client.query("BEGIN");
      for (const [key, item] of entries) {
        await client.query(
          `INSERT INTO openlyrics_state ("key", "value", updated_at)
           VALUES ($1, $2::jsonb, NOW())
           ON CONFLICT ("key") DO UPDATE
           SET "value" = EXCLUDED."value", updated_at = NOW()`,
          [key, JSON.stringify(item)],
        );
      }
      for (const key of removals) {
        await client.query('DELETE FROM openlyrics_state WHERE "key" = $1', [key]);
      }
      await client.query("COMMIT");
      for (const [key, item] of entries) this.cache.set(key, item);
      for (const key of removals) this.cache.delete(key);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async delete(key) {
    await this.init();
    await this.database.query('DELETE FROM openlyrics_state WHERE "key" = $1', [key]);
    this.cache.delete(key);
    if (key === "alarmAt") this.alarmAt = null;
  }

  async deleteAll() {
    await this.init();
    await this.database.query("DELETE FROM openlyrics_state");
    this.cache.clear();
    this.alarmAt = null;
  }

  async setAlarm(timestamp) {
    this.alarmAt = finiteTimestamp(timestamp);
    await this.put("alarmAt", this.alarmAt);
  }

  async deleteAlarm() {
    await this.delete("alarmAt");
  }
}

function finiteTimestamp(value) {
  const timestamp = Number(value);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : null;
}
