import crypto from "node:crypto";
import {
  buildContentState as buildSharedContentState,
  compactContentState,
  contentStateSize,
} from "./session.js";

export const reliabilityConstants = Object.freeze({
  phoneLeaseMs: 15_000,
  fastPollMs: 5_000,
  idlePollMs: 10_000,
  pauseEndMs: 10 * 60 * 1_000,
  requestTimeoutMs: 10_000,
  apnsTimeoutMs: 8_000,
  apnsRetries: 3,
  scheduleHorizonSec: 120,
  scheduleMaxLines: 64,
  payloadLimitBytes: 3_500,
});

const PROD_APNS_HOST = "https://api.push.apple.com";
const SANDBOX_APNS_HOST = "https://api.sandbox.push.apple.com";
const APNS_TOPIC = "com.jonathantran.dynamicallyrics.la.push-type.liveactivity";
const RETRYABLE_APNS_STATUS = new Set([429, 500, 502, 503, 504]);
const TERMINAL_APNS_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "TopicDisallowed",
  "Unregistered",
]);

/**
 * Merge a Spotify response without allowing a partial response to erase the
 * accepted track, artwork, duration, position, or play state.
 */
export function mergeSpotifyPlayer(previous, raw, nowMs = Date.now()) {
  const old = previous && typeof previous === "object" ? previous : null;
  if (!raw || typeof raw !== "object") {
    return {
      player: old ? projectPlayer(old, nowMs) : null,
      kind: old ? "transient-no-item" : "unchanged",
      confirmedStop: false,
      sameTrack: Boolean(old),
    };
  }

  const itemReported = Object.prototype.hasOwnProperty.call(raw, "item");
  if (!itemReported) {
    return {
      player: old ? projectPlayer(old, nowMs) : null,
      kind: old ? "partial" : "unchanged",
      confirmedStop: false,
      sameTrack: Boolean(old),
    };
  }
  if (raw.item == null) {
    return { player: null, kind: "confirmed-stop", confirmedStop: true, sameTrack: false };
  }

  const item = raw.item;
  const responseTrackID = clean(item.id ?? item.uri);
  const responseTitle = clean(item.name);
  const responseArtist = clean(item.artists?.[0]?.name ?? item.show?.publisher);
  const responseAlbum = clean(item.album?.name);
  const responseDuration = positiveNumber(item.duration_ms);
  const responseArtwork = preferredArtworkURL(item.album?.images);
  const eventTimestampMs = positiveInteger(raw.timestamp);
  if (eventTimestampMs && old?.playbackChangeAtMs &&
      eventTimestampMs < old.playbackChangeAtMs) {
    return {
      player: projectPlayer(old, nowMs),
      kind: "stale",
      confirmedStop: false,
      sameTrack: true,
    };
  }

  const metadataMatches = Boolean(old) &&
    (!responseTitle || old.title === responseTitle) &&
    (!responseArtist || old.artist === responseArtist) &&
    (!responseAlbum || !old.albumName || old.albumName === responseAlbum) &&
    (!responseDuration || !old.durationMs ||
      Math.abs(old.durationMs - responseDuration) <= 2_000);
  const trackID = responseTrackID ?? (metadataMatches
    ? old.trackID
    : fallbackTrackID(responseTitle, responseArtist));
  const sameTrack = Boolean(old) && (
    old.trackID === trackID || (!responseTrackID && metadataMatches)
  );
  const title = responseTitle ?? (sameTrack ? old.title : "Unknown track");
  const artist = responseArtist ?? (sameTrack ? old.artist : "");
  const durationMs = responseDuration ?? (sameTrack ? old.durationMs ?? 0 : 0);
  const isPlaying = typeof raw.is_playing === "boolean"
    ? raw.is_playing
    : (sameTrack ? old.isPlaying === true : false);
  const hasProgress = raw.progress_ms !== null && raw.progress_ms !== undefined &&
    Number.isFinite(Number(raw.progress_ms));
  const projected = sameTrack ? projectedProgress(old, nowMs) : 0;
  const progressMs = clamp(
    hasProgress ? Number(raw.progress_ms) : projected,
    0,
    durationMs > 0 ? durationMs : Number.MAX_SAFE_INTEGER,
  );
  const completed = typeof raw.is_playing === "boolean" && !raw.is_playing &&
    durationMs > 0 && progressMs >= durationMs - 750;
  const playbackChangeAtMs = eventTimestampMs
    ? Math.max(eventTimestampMs, sameTrack ? old?.playbackChangeAtMs ?? 0 : 0)
    : (sameTrack ? old?.playbackChangeAtMs ?? null : null);
  const player = {
    trackID,
    title,
    artist,
    albumName: responseAlbum ?? (sameTrack ? old?.albumName ?? null : null),
    albumImageURL: responseArtwork ?? (sameTrack ? old?.albumImageURL ?? null : null),
    durationMs,
    progressMs,
    progressObservedAt: nowMs,
    isPlaying: isPlaying && !completed,
    completed,
    playbackChangeAtMs,
  };

  let kind = "unchanged";
  if (!sameTrack) kind = "track";
  else if ((old?.isPlaying === true) !== (player.isPlaying === true)) kind = "play state";
  else if (hasProgress && Math.abs(progressMs - projected) > 750) kind = "seek";
  else if (player.albumImageURL !== old?.albumImageURL) kind = "artwork";
  else if (player.title !== old?.title || player.artist !== old?.artist ||
           player.durationMs !== old?.durationMs) kind = "metadata";
  else if (hasProgress) kind = "progress";

  return { player, kind, confirmedStop: false, sameTrack };
}

export function projectPlayer(player, nowMs = Date.now()) {
  if (!player || typeof player !== "object") return null;
  return {
    ...player,
    progressMs: projectedProgress(player, nowMs),
    progressObservedAt: nowMs,
  };
}

export function projectedProgress(player, nowMs = Date.now()) {
  const position = Math.max(0, finiteNumber(player?.progressMs, 0));
  if (player?.isPlaying !== true) return position;
  const observedAt = finiteNumber(player?.progressObservedAt, nowMs);
  const elapsed = Math.max(0, nowMs - observedAt);
  const projected = position + elapsed;
  const duration = positiveNumber(player?.durationMs);
  return duration ? Math.min(projected, duration) : projected;
}

/** Build the same bounded ActivityKit state used by the Cloudflare fallback. */
export function buildActivityContentState(player, lines, options = {}) {
  const state = buildSharedContentState({
    ...player,
    progressMs: projectedProgress(player, options.nowMs ?? Date.now()),
    lines: Array.isArray(lines) && lines.length ? lines : [{ t: 0, text: "♪" }],
  }, {
    ...options,
    schemaVersion: 2,
    requiresUserStart: false,
  });
  return compactContentState(state, reliabilityConstants.payloadLimitBytes);
}

export function activityPayload(event, state, options = {}) {
  const nowEpoch = finiteNumber(options.nowEpoch, Date.now() / 1_000);
  const payloadState = compactContentState({
    ...state,
    schemaVersion: 2,
    source: "server",
    generatedAtEpoch: nowEpoch,
  }, reliabilityConstants.payloadLimitBytes);
  const aps = {
    timestamp: Math.floor(nowEpoch),
    event,
    "content-state": payloadState,
    // A positive relevance score keeps lyrics ahead of less relevant Live
    // Activities when iOS chooses the prominent Lock Screen/Island surface.
    "relevance-score": 1.0,
  };
  if (event === "start") {
    aps["attributes-type"] = "LyricsActivityAttributes";
    aps.attributes = { sessionID: "lyrics" };
    aps.alert = {
      title: "OpenLyrics",
      body: `Lyrics are ready for ${payloadState.trackTitle}.`,
    };
    aps["stale-date"] = staleDateFor(payloadState, nowEpoch);
    if (options.inputPushToken === true) aps["input-push-token"] = 1;
  } else if (event === "update") {
    if (payloadState.isPlaying) aps["stale-date"] = staleDateFor(payloadState, nowEpoch);
  } else if (event === "end") {
    aps["dismissal-date"] = Math.floor(nowEpoch);
  }
  return { aps };
}

export function staleDateFor(state, nowEpoch = Date.now() / 1_000) {
  const schedule = Array.isArray(state?.scheduledLinesV2) ? state.scheduledLinesV2 : [];
  const last = schedule.at(-1);
  const horizon = finiteNumber(last?.endDateEpoch ?? last?.dateEpoch, nowEpoch);
  return Math.ceil(Math.max(nowEpoch + 60, horizon + 15));
}

export function contentStateBytes(state) {
  return contentStateSize(state);
}

export function preferredArtworkURL(images) {
  if (!Array.isArray(images) || !images.length) return null;
  const preferred = [...images].reverse().find(image =>
    clean(image?.url) && finiteNumber(image?.width, 0) >= 300
  );
  return clean(preferred?.url) ?? clean(images.at(-1)?.url);
}

/** Create an APNs provider JWT without logging the private key or token. */
export function createAPNsJWT({ keyP8, keyID, teamID, nowEpoch = Date.now() / 1_000 }) {
  if (!clean(keyP8) || !clean(keyID) || !clean(teamID)) {
    throw new Error("APNs credentials are not configured");
  }
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = base64url(JSON.stringify({ iss: teamID, iat: Math.floor(nowEpoch) }));
  const input = `${header}.${claims}`;
  const key = crypto.createPrivateKey(keyP8);
  const signature = crypto.sign("sha256", Buffer.from(input), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${input}.${base64url(signature)}`;
}

/**
 * Send one APNs request with bounded retries and Retry-After handling.
 * `fetchImpl` is injectable so payload and retry behavior can be tested
 * without contacting Apple.
 */
export async function sendAPNs({
  token,
  tokenRecord = {},
  payload,
  priority = 5,
  kind = "update",
  env = process.env,
  fetchImpl = fetch,
  nowEpoch = Date.now() / 1_000,
}) {
  if (!clean(token)) return deliveryResult({ kind, status: 0, reason: "missing token" });
  let jwt;
  try {
    jwt = createAPNsJWT({
      keyP8: env.APNS_KEY_P8,
      keyID: env.APNS_KEY_ID,
      teamID: env.APNS_TEAM_ID,
      nowEpoch,
    });
  } catch (error) {
    return deliveryResult({ kind, status: 0, reason: error.message });
  }
  const host = apnsHost(env, tokenRecord.environment);
  const requestBody = JSON.stringify(payload);
  let response = null;
  let reason = null;
  let attempts = 0;
  for (let attempt = 1; attempt <= reliabilityConstants.apnsRetries; attempt++) {
    attempts = attempt;
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      reliabilityConstants.apnsTimeoutMs,
    );
    try {
      response = await fetchImpl(`${host}/3/device/${token}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "liveactivity",
          "apns-priority": String(priority),
          ...(kind === "update" ? { "apns-collapse-id": "openlyrics-current-state" } : {}),
          authorization: `bearer ${jwt}`,
        },
        body: requestBody,
        signal: controller.signal,
      });
    } catch (error) {
      clearTimeout(timeout);
      if (attempt === reliabilityConstants.apnsRetries) {
        return deliveryResult({
          kind,
          status: 0,
          reason: error?.name === "AbortError" ? "timeout" : "network error",
          attempts,
        });
      }
      await waitForRetry(null, attempt);
      continue;
    }
    clearTimeout(timeout);
    const responseText = response.ok ? "" : await response.text().catch(() => "");
    reason = apnsReason(responseText);
    if (!RETRYABLE_APNS_STATUS.has(response.status) || attempt === reliabilityConstants.apnsRetries) {
      break;
    }
    await waitForRetry(response.headers?.get("Retry-After"), attempt);
  }
  const status = response?.status ?? 0;
  return deliveryResult({
    kind,
    status,
    reason: reason ?? (status === 200 ? null : "APNs request failed"),
    attempts,
    terminal: status === 410 || TERMINAL_APNS_REASONS.has(reason),
  });
}

function deliveryResult({ kind, status, reason, attempts = 1, terminal = false }) {
  return {
    kind,
    status,
    accepted: status === 200,
    terminal,
    reason: reason ?? null,
    attempts,
    at: new Date().toISOString(),
  };
}

function apnsHost(env, environment) {
  const configured = clean(env.APNS_HOST);
  const host = configured || (environment === "sandbox" ? SANDBOX_APNS_HOST : PROD_APNS_HOST);
  if (host !== PROD_APNS_HOST && host !== SANDBOX_APNS_HOST) {
    throw new Error("APNS_HOST must be a supported Apple push host");
  }
  return host;
}

async function waitForRetry(value, attempt) {
  const parsed = parseRetryAfter(value);
  // Keep tests and a real outage bounded. A production response can request a
  // longer delay, but the worker will claim the installation again later.
  const delayMs = Math.min(5_000, Math.max(250, parsed ?? attempt * 1_000));
  await new Promise(resolve => setTimeout(resolve, delayMs));
}

function parseRetryAfter(value) {
  if (value == null || value === "") return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return seconds * 1_000;
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - Date.now()) : null;
}

function apnsReason(responseText) {
  if (!responseText) return null;
  try {
    const value = JSON.parse(responseText);
    return typeof value?.reason === "string" ? value.reason : null;
  } catch {
    return null;
  }
}

function fallbackTrackID(title, artist) {
  return `fallback:${normalizedText(title)}:${normalizedText(artist)}`;
}

function normalizedText(value) {
  return String(value ?? "")
    .normalize("NFKC")
    .toLocaleLowerCase()
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

function clean(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}
