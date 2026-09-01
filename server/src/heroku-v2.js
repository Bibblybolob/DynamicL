import http from "node:http";
import crypto from "node:crypto";

const MAX_BODY_BYTES = 96 * 1024;
const PHONE_LEASE_MS = 15_000;
const COMMAND_TTL_MS = 8_000;
const DEFAULT_PORT = 3000;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS installations (
  id TEXT PRIMARY KEY,
  auth_token_hash TEXT NOT NULL UNIQUE,
  spotify_refresh_token TEXT NOT NULL,
  state JSONB NOT NULL DEFAULT '{}'::jsonb,
  next_poll_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lock_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS activity_tokens (
  installation_id TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('update', 'pushToStart')),
  token_ciphertext TEXT NOT NULL,
  environment TEXT NOT NULL DEFAULT 'production',
  capabilities JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (installation_id, kind)
);
CREATE TABLE IF NOT EXISTS lyric_documents (
  content_hash TEXT PRIMARY KEY,
  track_id TEXT NOT NULL,
  source TEXT NOT NULL,
  document JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS lyric_documents_track_idx ON lyric_documents(track_id);
CREATE TABLE IF NOT EXISTS lyric_corrections (
  installation_id TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  track_id TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (installation_id, track_id)
);
CREATE TABLE IF NOT EXISTS commands (
  installation_id TEXT NOT NULL REFERENCES installations(id) ON DELETE CASCADE,
  command_id TEXT NOT NULL,
  command TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL,
  result JSONB NOT NULL,
  PRIMARY KEY (installation_id, command_id)
);
`;

/** A small in-memory store used for local tests. Heroku should use Postgres. */
export class MemoryStore {
  constructor() {
    this.installations = new Map();
    this.commands = new Map();
    this.documents = new Map();
    this.corrections = new Map();
  }

  async init() {}

  async createInstallation(record) {
    this.installations.set(record.id, structuredClone(record));
    return this.getInstallation(record.id);
  }

  async findByAuthHash(hash) {
    for (const installation of this.installations.values()) {
      if (constantTimeEqual(installation.authHash, hash)) {
        return structuredClone(installation);
      }
    }
    return null;
  }

  async getInstallation(id) {
    const installation = this.installations.get(id);
    return installation ? structuredClone(installation) : null;
  }

  async firstInstallation() {
    return this.installations.values().next().value
      ? structuredClone(this.installations.values().next().value)
      : null;
  }

  async updateInstallation(id, patch) {
    const current = this.installations.get(id);
    if (!current) return null;
    const nextPatch = structuredClone(patch);
    // Match PostgresStore.updateInstallation: a partial state patch must not
    // erase the rest of the installation state. The lyric negative cache and
    // token-rotation paths rely on this behavior in local worker tests.
    if (nextPatch.state) {
      current.state = { ...(current.state ?? {}), ...nextPatch.state };
      delete nextPatch.state;
    }
    Object.assign(current, nextPatch);
    current.updatedAt = new Date().toISOString();
    this.installations.set(id, current);
    return this.getInstallation(id);
  }

  async upsertActivityToken(id, kind, tokenCiphertext, options = {}) {
    const current = this.installations.get(id);
    if (!current) return;
    current.tokens ??= {};
    current.tokens[kind] = {
      ciphertext: tokenCiphertext,
      environment: options.environment ?? "production",
      capabilities: options.capabilities ?? {},
      lastSeenAt: new Date().toISOString(),
    };
    this.installations.set(id, current);
  }

  async deleteActivityToken(id, kind) {
    const current = this.installations.get(id);
    if (current?.tokens) delete current.tokens[kind];
  }

  async getActivityTokens(id) {
    const current = await this.getInstallation(id);
    return current?.tokens ?? {};
  }

  async getCommand(id, commandID) {
    const value = this.commands.get(`${id}:${commandID}`);
    return value ? structuredClone(value) : null;
  }

  async saveCommand(id, commandID, value) {
    this.commands.set(`${id}:${commandID}`, structuredClone(value));
  }

  async clearCommands(id) {
    for (const key of this.commands.keys()) {
      if (key.startsWith(`${id}:`)) this.commands.delete(key);
    }
  }

  async saveCorrection(id, trackID, contentHash) {
    this.corrections.set(`${id}:${trackID}`, contentHash);
  }

  async getCorrection(id, trackID) {
    return this.corrections.get(`${id}:${trackID}`) ?? null;
  }

  async deleteInstallation(id) {
    this.installations.delete(id);
    for (const key of this.commands.keys()) if (key.startsWith(`${id}:`)) this.commands.delete(key);
    for (const key of this.corrections.keys()) if (key.startsWith(`${id}:`)) this.corrections.delete(key);
  }

  async claimDue(limit = 20) {
    const now = Date.now();
    const claimed = [];
    for (const installation of this.installations.values()) {
      const due = Date.parse(installation.nextPollAt ?? "") <= now;
      const unlocked = !installation.lockUntil || Date.parse(installation.lockUntil) <= now;
      if (!due || !unlocked) continue;
      installation.lockUntil = new Date(now + 30_000).toISOString();
      this.installations.set(installation.id, installation);
      claimed.push(structuredClone(installation));
      if (claimed.length >= limit) break;
    }
    return claimed;
  }

  async saveDocument(document) {
    this.documents.set(document.contentHash, structuredClone(document));
  }

  async documentsForTrack(trackID) {
    return [...this.documents.values()]
      .filter(document => document.trackID === trackID)
      .map(document => structuredClone(document));
  }
}

export class PostgresStore {
  constructor(databaseURL, PoolClass) {
    this.pool = new PoolClass({
      connectionString: databaseURL,
      ssl: databaseURL.includes("localhost") ? false : { rejectUnauthorized: false },
      max: 5,
      idleTimeoutMillis: 30_000,
    });
  }

  async init() {
    await this.pool.query(SCHEMA);
  }

  row(row) {
    if (!row) return null;
    return {
      id: row.id,
      authHash: row.auth_token_hash,
      refreshTokenCiphertext: row.spotify_refresh_token,
      state: row.state ?? {},
      tokens: row.tokens ?? {},
      nextPollAt: new Date(row.next_poll_at).toISOString(),
      lockUntil: row.lock_until ? new Date(row.lock_until).toISOString() : null,
    };
  }

  async createInstallation(record) {
    const result = await this.pool.query(
      `INSERT INTO installations (id, auth_token_hash, spotify_refresh_token, state, next_poll_at)
       VALUES ($1, $2, $3, $4::jsonb, NOW()) RETURNING *`,
      [record.id, record.authHash, record.refreshTokenCiphertext, JSON.stringify(record.state ?? {})]
    );
    return this.getInstallation(result.rows[0].id);
  }

  async findByAuthHash(hash) {
    const result = await this.pool.query(
      `SELECT i.*, COALESCE(jsonb_object_agg(a.kind, jsonb_build_object(
        'ciphertext', a.token_ciphertext, 'environment', a.environment,
        'capabilities', a.capabilities, 'lastSeenAt', a.last_seen_at
      )) FILTER (WHERE a.kind IS NOT NULL), '{}'::jsonb) AS tokens
       FROM installations i LEFT JOIN activity_tokens a ON a.installation_id = i.id
       WHERE i.auth_token_hash = $1 GROUP BY i.id`,
      [hash]
    );
    return this.row(result.rows[0]);
  }

  async getInstallation(id) {
    const result = await this.pool.query(
      `SELECT i.*, COALESCE(jsonb_object_agg(a.kind, jsonb_build_object(
        'ciphertext', a.token_ciphertext, 'environment', a.environment,
        'capabilities', a.capabilities, 'lastSeenAt', a.last_seen_at
      )) FILTER (WHERE a.kind IS NOT NULL), '{}'::jsonb) AS tokens
       FROM installations i LEFT JOIN activity_tokens a ON a.installation_id = i.id
       WHERE i.id = $1 GROUP BY i.id`,
      [id]
    );
    return this.row(result.rows[0]);
  }

  async firstInstallation() {
    const result = await this.pool.query(
      `SELECT i.*, COALESCE(jsonb_object_agg(a.kind, jsonb_build_object(
        'ciphertext', a.token_ciphertext, 'environment', a.environment,
        'capabilities', a.capabilities, 'lastSeenAt', a.last_seen_at
      )) FILTER (WHERE a.kind IS NOT NULL), '{}'::jsonb) AS tokens
       FROM installations i LEFT JOIN activity_tokens a ON a.installation_id = i.id
       GROUP BY i.id ORDER BY i.created_at ASC LIMIT 1`
    );
    return this.row(result.rows[0]);
  }

  async updateInstallation(id, patch) {
    const current = await this.getInstallation(id);
    if (!current) return null;
    const state = { ...current.state, ...(patch.state ?? {}) };
    const nextPollAt = patch.nextPollAt ?? current.nextPollAt;
    const lockUntil = patch.lockUntil === undefined ? current.lockUntil : patch.lockUntil;
    await this.pool.query(
      `UPDATE installations SET state = $2::jsonb, next_poll_at = $3,
       lock_until = $4, updated_at = NOW(), spotify_refresh_token = COALESCE($5, spotify_refresh_token)
       WHERE id = $1`,
      [id, JSON.stringify(state), nextPollAt, lockUntil, patch.refreshTokenCiphertext ?? null]
    );
    return this.getInstallation(id);
  }

  async upsertActivityToken(id, kind, tokenCiphertext, options = {}) {
    await this.pool.query(
      `INSERT INTO activity_tokens (installation_id, kind, token_ciphertext, environment, capabilities)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (installation_id, kind) DO UPDATE SET token_ciphertext = EXCLUDED.token_ciphertext,
       environment = EXCLUDED.environment, capabilities = EXCLUDED.capabilities, last_seen_at = NOW()`,
      [id, kind, tokenCiphertext, options.environment ?? "production", JSON.stringify(options.capabilities ?? {})]
    );
  }

  async deleteActivityToken(id, kind) {
    await this.pool.query(`DELETE FROM activity_tokens WHERE installation_id = $1 AND kind = $2`, [id, kind]);
  }

  async getActivityTokens(id) {
    const result = await this.pool.query(
      `SELECT kind, token_ciphertext AS ciphertext, environment, capabilities, last_seen_at AS "lastSeenAt"
       FROM activity_tokens WHERE installation_id = $1`,
      [id]
    );
    return Object.fromEntries(result.rows.map(row => [row.kind, row]));
  }

  async getCommand(id, commandID) {
    const result = await this.pool.query(
      `SELECT result FROM commands WHERE installation_id = $1 AND command_id = $2`,
      [id, commandID]
    );
    return result.rows[0]?.result ?? null;
  }

  async saveCommand(id, commandID, value) {
    await this.pool.query(
      `INSERT INTO commands (installation_id, command_id, command, issued_at, result)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (installation_id, command_id) DO NOTHING`,
      [id, commandID, value.command, value.issuedAt, JSON.stringify(value)]
    );
  }

  async clearCommands(id) {
    await this.pool.query(`DELETE FROM commands WHERE installation_id = $1`, [id]);
  }

  async saveCorrection(id, trackID, contentHash) {
    await this.pool.query(
      `INSERT INTO lyric_corrections (installation_id, track_id, content_hash)
       VALUES ($1, $2, $3) ON CONFLICT (installation_id, track_id)
       DO UPDATE SET content_hash = EXCLUDED.content_hash, updated_at = NOW()`,
      [id, trackID, contentHash]
    );
  }

  async getCorrection(id, trackID) {
    const result = await this.pool.query(
      `SELECT content_hash FROM lyric_corrections WHERE installation_id = $1 AND track_id = $2`,
      [id, trackID]
    );
    return result.rows[0]?.content_hash ?? null;
  }

  async deleteInstallation(id) {
    await this.pool.query(`DELETE FROM installations WHERE id = $1`, [id]);
  }

  async claimDue(limit = 20) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query(
        `SELECT * FROM installations WHERE next_poll_at <= NOW()
         AND (lock_until IS NULL OR lock_until < NOW())
         ORDER BY next_poll_at ASC FOR UPDATE SKIP LOCKED LIMIT $1`,
        [limit]
      );
      const lockUntil = new Date(Date.now() + 30_000);
      for (const row of result.rows) {
        await client.query(`UPDATE installations SET lock_until = $2 WHERE id = $1`, [row.id, lockUntil]);
      }
      await client.query("COMMIT");
      return Promise.all(result.rows.map(row => this.getInstallation(row.id)));
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async saveDocument(document) {
    await this.pool.query(
      `INSERT INTO lyric_documents (content_hash, track_id, source, document, expires_at)
       VALUES ($1, $2, $3, $4::jsonb, $5) ON CONFLICT (content_hash) DO NOTHING`,
      [document.contentHash, document.trackID, document.source, JSON.stringify(document.document), document.expiresAt]
    );
  }

  async documentsForTrack(trackID) {
    const result = await this.pool.query(
      `SELECT content_hash, track_id, source, document, expires_at
       FROM lyric_documents WHERE track_id = $1 AND expires_at > NOW()`,
      [trackID]
    );
    return result.rows.map(row => ({
      contentHash: row.content_hash,
      trackID: row.track_id,
      source: row.source,
      document: row.document,
      expiresAt: row.expires_at,
    }));
  }
}

export async function createRuntime(env = process.env) {
  const databaseURL = env.DATABASE_URL;
  let store;
  if (databaseURL) {
    const { Pool } = await import("pg");
    store = new PostgresStore(databaseURL, Pool);
  } else {
    store = new MemoryStore();
  }
  await store.init();
  return {
    env,
    store,
    encryptionKey: encryptionKey(env),
  };
}

export async function handleRequest(request, response, runtime) {
  const url = new URL(request.url, "http://localhost");
  const path = normalizePath(url.pathname);
  try {
    if (request.method === "GET" && path === "/health") {
      return writeJSON(response, 200, { ok: true, service: "openlyrics-sync", database: runtime.store instanceof PostgresStore ? "postgres" : "memory" });
    }
    if (request.method === "OPTIONS") {
      return writeJSON(response, 204, null);
    }
    const body = request.method === "GET" || request.method === "DELETE" ? {} : await readJSON(request);
    const installation = await authorizedInstallation(request, runtime, path === "/register");

    if (request.method === "POST" && path === "/register") {
      return register(body, installation, runtime, request, response);
    }
    if (!installation) return writeJSON(response, 401, { error: "unauthorized" });
    if (request.method === "POST" && path === "/heartbeat") return heartbeat(body, installation, runtime, response);
    if (request.method === "POST" && path === "/wake") return wake(body, installation, runtime, response);
    if (request.method === "POST" && path === "/command") return command(body, installation, runtime, response);
    if (request.method === "GET" && path === "/status") return status(installation, runtime, response);
    if (request.method === "GET" && path === "/lyrics/candidates") return candidates(url, installation, runtime, response);
    if (request.method === "POST" && path === "/lyrics/select") return selectLyric(body, installation, runtime, response);
    if (request.method === "DELETE" && path === "/unregister") {
      await runtime.store.deleteInstallation(installation.id);
      return writeJSON(response, 200, { ok: true, deleted: true });
    }
    if (request.method === "POST" && path === "/reset") {
      await runtime.store.clearCommands?.(installation.id);
      await runtime.store.updateInstallation(installation.id, {
        state: {
          phoneLeaseExpiresAt: 0,
          playbackSessionID: null,
          playbackSessionDismissed: false,
          playbackSessionStartAttempted: false,
          playbackSessionClosed: true,
          activeTrack: null,
          activeContentState: null,
          spotifyTrackID: null,
          lyricNegativeCache: {},
          serverRevision: 0,
        },
        nextPollAt: new Date().toISOString(),
      });
      return writeJSON(response, 200, { ok: true, reset: true });
    }
    return writeJSON(response, 404, { error: "not found" });
  } catch (error) {
    const statusCode = error?.statusCode ?? 500;
    return writeJSON(response, statusCode, {
      error: statusCode === 500 ? "internal server error" : error.message,
      ...(runtime.env.NODE_ENV === "test" ? { detail: String(error?.stack ?? error).slice(0, 500) } : {}),
    });
  }
}

async function register(body, installation, runtime, request, response) {
  if (!isObject(body) || typeof body.spotifyRefreshToken !== "string" || body.spotifyRefreshToken.length < 10) {
    return writeJSON(response, 400, { error: "spotifyRefreshToken is required" });
  }
  const updateToken = optionalHex(body.updateToken);
  const pushToStartToken = optionalHex(body.pushToStartToken);
  if (!updateToken && !pushToStartToken) {
    return writeJSON(response, 400, { error: "an Activity token is required" });
  }
  if (!validSchemaVersion(body.clientSchemaVersion) || !validNumber(body.lyricOffsetMs)) {
    return writeJSON(response, 400, { error: "invalid client schema or lyric offset" });
  }
  if (!runtime.encryptionKey) {
    return writeJSON(response, 503, { error: "TOKEN_ENCRYPTION_KEY is not configured" });
  }

  let current = installation;
  let authToken;
  let previousRefreshToken = null;
  if (current?.refreshTokenCiphertext) {
    try {
      previousRefreshToken = unseal(current.refreshTokenCiphertext, runtime.encryptionKey);
    } catch {
      // A legacy or rotated encryption key is treated as an account change.
      // The new token is still accepted after the server has been configured
      // with the current encryption key.
      previousRefreshToken = "__unreadable_previous_token__";
    }
  }
  const accountChanged = Boolean(current && previousRefreshToken !== body.spotifyRefreshToken);
  if (!current) {
    authToken = crypto.randomBytes(32).toString("hex");
    current = await runtime.store.createInstallation({
      id: crypto.randomUUID(),
      authHash: hashToken(authToken),
      refreshTokenCiphertext: seal(body.spotifyRefreshToken, runtime.encryptionKey),
      state: {},
    });
  } else {
    await runtime.store.updateInstallation(current.id, {
      refreshTokenCiphertext: seal(body.spotifyRefreshToken, runtime.encryptionKey),
    });
  }

  const previousState = current.state ?? {};
  const resetState = accountChanged ? {
    // Never carry an access token, track, lyric schedule, negative-cache entry,
    // dismissal, or playback session across Spotify accounts.
    accessToken: "",
    accessTokenExpiresAt: 0,
    activeTrack: null,
    activeContentState: null,
    spotifyTrackID: null,
    trackTitle: null,
    artistName: null,
    albumImageURL: null,
    playbackSessionID: null,
    playbackSessionStartAttempted: false,
    playbackSessionDismissed: false,
    playbackSessionClosed: true,
    lastStartAttemptAt: 0,
    lastStartAttemptCount: 0,
    lastSentTrackID: "",
    lastSentScheduleV2: [],
    lastSchedulePushAt: 0,
    lastSentPlaybackChangeAtMs: 0,
    lastSentProgressStartEpoch: null,
    lastSentAlbumImageURL: null,
    lyricNegativeCache: {},
    noItemSamples: 0,
  } : {};
  const state = {
    ...previousState,
    ...resetState,
    clientSchemaVersion: numericVersion(body.clientSchemaVersion),
    spotifyClientID: clean(body.spotifyClientID ?? body.spotifyClientId),
    supportsRemoteStart: body.supportsRemoteStart !== false,
    supportsInputPushToken: body.supportsInputPushToken === true,
    lyricOffsetMs: numberOr(body.lyricOffsetMs, 0),
    autoStartEnabled: body.autoStartEnabled !== false,
    requiresUserStart: body.requiresUserStart === true,
    phoneLeaseExpiresAt: Date.now() + PHONE_LEASE_MS,
    currentOwner: "phone",
    serverRevision: Number(current.state?.serverRevision ?? 0),
    lastRegistrationAt: new Date().toISOString(),
    ...(accountChanged ? { accountChangedAt: new Date().toISOString() } : {}),
  };
  // An update token belongs to a newly active Activity. Do not return a
  // dismissal stored for the previous token; the iOS client would otherwise
  // end the replacement card immediately after a successful registration.
  if (updateToken) {
    state.playbackSessionDismissed = false;
    state.dismissalSource = null;
  }
  await runtime.store.updateInstallation(current.id, {
    state,
    nextPollAt: new Date(Date.now() + 1_000).toISOString(),
    lockUntil: null,
  });
  if (updateToken) await runtime.store.upsertActivityToken(current.id, "update", seal(updateToken, runtime.encryptionKey), tokenOptions(body));
  if (pushToStartToken) await runtime.store.upsertActivityToken(current.id, "pushToStart", seal(pushToStartToken, runtime.encryptionKey), tokenOptions(body));
  const latest = await runtime.store.getInstallation(current.id);
  return writeJSON(response, 200, {
    ok: true,
    ...(authToken ? { authToken } : {}),
    installationID: current.id,
    writer: "phone",
    leaseExpiresAt: state.phoneLeaseExpiresAt,
    serverRevision: state.serverRevision,
    playbackSessionDismissed: state.playbackSessionDismissed === true,
    pushToStartAvailable: Boolean(latest?.tokens?.pushToStart),
  });
}

async function heartbeat(body, installation, runtime, response) {
  if (!isObject(body) || !["active", "none", "dismissed"].includes(body.activityState) ||
      !validNumber(body.sentAtMs) || !validNumber(body.localRevision) ||
      !validNumber(body.lyricOffsetMs) || !validSchemaVersion(body.clientSchemaVersion)) {
    return writeJSON(response, 400, { error: "invalid heartbeat payload" });
  }
  const current = await runtime.store.getInstallation(installation.id);
  const oldState = current?.state ?? {};
  const incomingAt = numberOr(body.sentAtMs, Date.now());
  const oldAt = numberOr(oldState.phoneGeneratedAtMs, 0);
  const oldRevision = numberOr(oldState.phoneRevision, 0);
  if (incomingAt < oldAt || (incomingAt === oldAt && numberOr(body.localRevision, 0) < oldRevision)) {
    return writeJSON(response, 200, {
      ok: true,
      accepted: false,
      stale: true,
      writer: owner(oldState),
      leaseExpiresAt: oldState.phoneLeaseExpiresAt ?? null,
      serverRevision: numberOr(oldState.serverRevision, 0),
    });
  }
  const state = {
    ...oldState,
    phoneLeaseExpiresAt: Date.now() + PHONE_LEASE_MS,
    currentOwner: "phone",
    phoneActivityState: body.activityState,
    phoneRevision: numberOr(body.localRevision, 0),
    phoneGeneratedAtMs: incomingAt,
    phoneTrackID: clean(body.trackID),
    clientSchemaVersion: numericVersion(body.clientSchemaVersion),
    lyricOffsetMs: numberOr(body.lyricOffsetMs, 0),
    autoStartEnabled: body.autoStartEnabled !== false,
    ...(Object.hasOwn(body, "requiresUserStart") ? { requiresUserStart: body.requiresUserStart === true } : {}),
  };
  if (body.activityState === "dismissed") {
    state.playbackSessionDismissed = true;
    state.dismissalSource = "phone";
    await runtime.store.deleteActivityToken(installation.id, "update");
  } else if (body.updateToken) {
    const token = optionalHex(body.updateToken);
    if (token) {
      await runtime.store.upsertActivityToken(installation.id, "update", seal(token, runtime.encryptionKey), tokenOptions(body));
      if (body.activityState === "active") {
        state.playbackSessionDismissed = false;
        state.dismissalSource = null;
      }
    }
  }
  if (body.activityEnded === true && body.activityState === "none") {
    await runtime.store.deleteActivityToken(installation.id, "update");
  }
  state.serverRevision = numberOr(state.serverRevision, 0) + 1;
  await runtime.store.updateInstallation(installation.id, { state, nextPollAt: new Date(Date.now() + 1_000).toISOString() });
  return writeJSON(response, 200, {
    ok: true,
    accepted: true,
    writer: "phone",
    leaseExpiresAt: state.phoneLeaseExpiresAt,
    serverRevision: state.serverRevision,
    playbackSessionDismissed: state.playbackSessionDismissed === true,
    dismissalSource: state.dismissalSource ?? null,
  });
}

async function wake(body, installation, runtime, response) {
  const current = await runtime.store.getInstallation(installation.id);
  const state = {
    ...(current?.state ?? {}),
    wakeRequestedAt: Date.now(),
    lastWakeReason: clean(body?.reason) ?? "shortcut",
  };
  await runtime.store.updateInstallation(installation.id, {
    state,
    nextPollAt: new Date().toISOString(),
  });
  return writeJSON(response, 202, { ok: true, accepted: true, serverRevision: numberOr(state.serverRevision, 0) });
}

async function command(body, installation, runtime, response) {
  if (!isObject(body) || !["toggle", "next", "previous"].includes(body.command) ||
      typeof body.commandID !== "string" || !/^[A-Za-z0-9-]{8,80}$/.test(body.commandID) ||
      !validNumber(body.issuedAtMs) || Math.abs(Date.now() - numberOr(body.issuedAtMs, 0)) > COMMAND_TTL_MS) {
    return writeJSON(response, 400, { error: "expired or invalid command" });
  }
  const existing = await runtime.store.getCommand(installation.id, body.commandID);
  if (existing) return writeJSON(response, 200, existing);
  const current = await runtime.store.getInstallation(installation.id);
  const result = {
    ok: true,
    accepted: true,
    queued: true,
    commandID: body.commandID,
    command: body.command,
    issuedAt: new Date(numberOr(body.issuedAtMs, Date.now())).toISOString(),
    serverRevision: numberOr(current?.state?.serverRevision, 0),
  };
  await runtime.store.saveCommand(installation.id, body.commandID, {
    ...result,
  });
  const state = { ...(current?.state ?? {}), wakeRequestedAt: Date.now(), pendingCommand: body.command };
  await runtime.store.updateInstallation(installation.id, { state, nextPollAt: new Date().toISOString() });
  return writeJSON(response, 202, result);
}

async function status(installation, runtime, response) {
  const current = await runtime.store.getInstallation(installation.id);
  const state = current?.state ?? {};
  const lease = numberOr(state.phoneLeaseExpiresAt, 0);
  const hasRefreshToken = Boolean(current?.refreshTokenCiphertext);
  const apnsReady = Boolean(runtime.env.APNS_KEY_P8 && runtime.env.APNS_KEY_ID && runtime.env.APNS_TEAM_ID);
  return writeJSON(response, 200, {
    ok: true,
    updateOwner: owner(state),
    currentOwner: owner(state),
    phoneLeaseExpiresAt: lease || null,
    pushToStartAvailable: Boolean(current?.tokens?.pushToStart) && state.autoStartEnabled !== false,
    pushToStartSupported: state.supportsRemoteStart === true,
    inputPushTokenSupported: state.supportsInputPushToken === true,
    playbackSessionID: state.playbackSessionID ?? null,
    startAttempted: state.playbackSessionStartAttempted === true,
    lastAPNsResult: state.lastAPNsResult ?? null,
    payloadSchema: numericVersion(state.clientSchemaVersion),
    payloadSize: state.lastPayloadSize ?? null,
    schedule: {
      count: numberOr(state.lastScheduleCount, 0),
      horizonEpoch: state.lastScheduleHorizonEpoch ?? null,
    },
    artwork: state.lastArtworkStatus ?? null,
    readiness: {
      reachable: true,
      spotify: hasRefreshToken && Boolean(state.spotifyClientID || runtime.env.SPOTIFY_CLIENT_ID),
      apns: apnsReady,
      database: runtime.store instanceof PostgresStore,
    },
  });
}

async function candidates(url, installation, runtime, response) {
  const trackID = clean(url.searchParams.get("trackID"));
  if (!trackID) return writeJSON(response, 400, { error: "trackID is required" });
  const documents = await runtime.store.documentsForTrack(trackID);
  return writeJSON(response, 200, {
    trackID,
    selectedContentHash: await runtime.store.getCorrection(installation.id, trackID),
    candidates: documents,
  });
}

async function selectLyric(body, installation, runtime, response) {
  if (!isObject(body) || !clean(body.trackID) || !clean(body.contentHash)) {
    return writeJSON(response, 400, { error: "trackID and contentHash are required" });
  }
  await runtime.store.saveCorrection(installation.id, clean(body.trackID), clean(body.contentHash));
  return writeJSON(response, 200, { ok: true, selected: true });
}

async function authorizedInstallation(request, runtime, isRegister) {
  const bearer = request.headers?.authorization ?? "";
  const token = bearer.startsWith("Bearer ") ? bearer.slice(7).trim() : "";
  if (!token) return isRegister ? null : null;
  if (runtime.env.SYNC_AUTH_TOKEN && constantTimeEqual(token, runtime.env.SYNC_AUTH_TOKEN.trim())) {
    // The legacy shared token maps to the first installation during the
    // migration window. New clients receive an opaque per-install token.
    return runtime.store.firstInstallation();
  }
  const installation = await runtime.store.findByAuthHash(hashToken(token));
  if (installation) return installation;
  throw httpError(401, "unauthorized");
}

function normalizePath(path) {
  const normalized = path.replace(/^\/v1(?=\/|$)/, "");
  return normalized || "/";
}

function owner(state) {
  return numberOr(state.phoneLeaseExpiresAt, 0) > Date.now() ? "phone" : "server";
}

function tokenOptions(body) {
  return {
    environment: body.environment === "sandbox" ? "sandbox" : "production",
    capabilities: {
      supportsRemoteStart: body.supportsRemoteStart === true,
      supportsInputPushToken: body.supportsInputPushToken === true,
    },
  };
}

function encryptionKey(env) {
  const value = env.TOKEN_ENCRYPTION_KEY ?? env.SYNC_ENCRYPTION_KEY ?? env.SYNC_AUTH_TOKEN;
  return value ? crypto.createHash("sha256").update(String(value)).digest() : null;
}

function seal(value, key) {
  if (!key) throw httpError(503, "TOKEN_ENCRYPTION_KEY is not configured");
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(String(value), "utf8"), cipher.final()]);
  return [iv.toString("base64url"), cipher.getAuthTag().toString("base64url"), ciphertext.toString("base64url")].join(".");
}

// Used by the worker when Spotify rotates a refresh token. Keep the helper
// private in behavior: callers receive only the encrypted value, never the
// key or plaintext token.
export function sealForWorker(value, key) {
  return seal(value, key);
}

export function unseal(value, key) {
  const [ivText, tagText, cipherText] = String(value ?? "").split(".");
  if (!key || !ivText || !tagText || !cipherText) throw new Error("invalid encrypted value");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));
  return Buffer.concat([decipher.update(Buffer.from(cipherText, "base64url")), decipher.final()]).toString("utf8");
}

function hashToken(token) {
  return crypto.createHash("sha256").update(String(token)).digest("hex");
}

function constantTimeEqual(left, right) {
  const a = Buffer.from(String(left ?? ""));
  const b = Buffer.from(String(right ?? ""));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function optionalHex(value) {
  if (value == null || value === "") return null;
  return /^[0-9a-f]{16,512}$/i.test(String(value)) ? String(value) : null;
}

function validSchemaVersion(value) {
  return value == null || value === 1 || value === 2;
}

function numericVersion(value) {
  return numberOr(value, 1) >= 2 ? 2 : 1;
}

function validNumber(value) {
  return value == null || (typeof value === "number" && Number.isFinite(value));
}

function numberOr(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function clean(value) {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result || null;
}

function isObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function httpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}

function readJSON(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let value = "";
    request.setEncoding("utf8");
    request.on("data", chunk => {
      size += Buffer.byteLength(chunk);
      if (size > MAX_BODY_BYTES) {
        reject(httpError(413, "request body is too large"));
        request.destroy();
        return;
      }
      value += chunk;
    });
    request.on("end", () => {
      try {
        resolve(value ? JSON.parse(value) : {});
      } catch {
        reject(httpError(400, "invalid JSON"));
      }
    });
    request.on("error", reject);
  });
}

function writeJSON(response, status, value) {
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.setHeader("cache-control", "no-store");
  response.setHeader("access-control-allow-origin", "*");
  response.setHeader("access-control-allow-headers", "authorization, content-type");
  response.setHeader("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
  if (status === 204) return response.end();
  response.end(JSON.stringify(value));
}

export async function start({ env = process.env, port = Number(process.env.PORT) || DEFAULT_PORT } = {}) {
  const runtime = await createRuntime(env);
  const server = http.createServer((request, response) => {
    handleRequest(request, response, runtime);
  });
  await new Promise(resolve => server.listen(port, "0.0.0.0", resolve));
  let stopPolling = null;
  if (embeddedWorkerEnabled(env)) {
    // Run the polling authority in the already-paid web dyno. This avoids a
    // freeze after the phone lease expires when Heroku's worker formation is
    // scaled to zero. A dynamic import avoids a module-initialization cycle.
    const { startPollingLoop } = await import("./heroku-worker-v2.js");
    stopPolling = startPollingLoop(runtime);
    console.log("OpenLyrics embedded polling worker started");
  }
  server.once("close", () => stopPolling?.());
  return { server, runtime, stopPolling };
}

export function embeddedWorkerEnabled(env = process.env) {
  const configured = String(env.EMBEDDED_WORKER_ENABLED ?? "true").trim().toLowerCase();
  return env.NODE_ENV === "production" && !["0", "false", "off", "no"].includes(configured);
}

if (process.argv[1] && process.argv[1].endsWith("heroku-v2.js")) {
  start().then(({ server }) => {
    console.log(`OpenLyrics sync server listening on ${server.address().port}`);
  }).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
