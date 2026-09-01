import crypto from "node:crypto";

const DEFAULT_LRCLIB_GET_URL = "https://lrclib.net/api/get";
const DEFAULT_LRCLIB_SEARCH_URL = "https://lrclib.net/api/search";
const PROVIDER_TIMEOUT_MS = 3_000;
const TOTAL_LOOKUP_TIMEOUT_MS = 5_000;
const SUCCESS_CACHE_MS = 30 * 24 * 60 * 60 * 1_000;
const NEGATIVE_CACHE_MS = 15 * 60 * 1_000;

/**
 * Normalized lyric result used by the Heroku worker and the candidate API.
 * Provider-specific response fields never leave this module.
 */
export function documentFromLines({ trackID, title, artist, durationSec = 0, source = "unknown", lines }) {
  const normalizedLines = (Array.isArray(lines) ? lines : [])
    .map(line => ({
      t: finiteNumber(line?.t, 0),
      text: cleanText(line?.text),
    }))
    .filter(line => line.text)
    .sort((left, right) => left.t - right.t);
  if (!normalizedLines.length) return null;
  const content = JSON.stringify({
    schemaVersion: 2,
    trackID: cleanText(trackID) ?? "",
    title: cleanText(title) ?? "",
    artist: cleanText(artist) ?? "",
    durationSec: finiteNumber(durationSec, 0),
    source: cleanText(source) ?? "unknown",
    lines: normalizedLines,
  });
  return {
    schemaVersion: 2,
    trackID: cleanText(trackID) ?? "",
    title: cleanText(title) ?? "",
    artist: cleanText(artist) ?? "",
    durationSec: finiteNumber(durationSec, 0),
    source: cleanText(source) ?? "unknown",
    lines: normalizedLines,
    contentHash: crypto.createHash("sha256").update(content).digest("hex"),
  };
}

/** Parses LRC, enhanced LRC, and repeated timestamp lines. */
export function parseLRC(lrc) {
  const parsed = [];
  let offsetSec = 0;
  for (const raw of String(lrc ?? "").split("\n")) {
    const line = raw.replace(/\r$/, "");
    const offset = line.match(/^\[offset:\s*([+-]?\d+)\]\s*$/i);
    if (offset) {
      // The final valid offset declaration is the effective declaration.
      offsetSec = Number(offset[1]) / 1_000;
      continue;
    }
    let rest = line;
    const times = [];
    let match;
    while ((match = rest.match(/^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/))) {
      const fraction = match[3]
        ? Number(match[3]) / (10 ** match[3].length)
        : 0;
      times.push(Math.max(0, Number(match[1]) * 60 + Number(match[2]) + fraction));
      rest = rest.slice(match[0].length);
    }
    const text = cleanText(rest);
    if (text) {
      for (const time of times) parsed.push({ t: Math.max(0, time - offsetSec), text });
    }
  }
  return parsed.sort((left, right) => left.t - right.t);
}

export function parsePlainLyrics(plainLyrics, durationSec = 0) {
  const texts = String(plainLyrics ?? "")
    .split(/\r?\n/)
    .map(cleanText)
    .filter(Boolean);
  if (!texts.length) return [];
  const interval = texts.length > 1 && durationSec > 0
    ? durationSec / (texts.length - 1)
    : 3;
  return texts.map((text, index) => ({ t: index * interval, text }));
}

/**
 * Unicode-aware matching. ASCII-only matching caused non-Latin songs to miss
 * valid candidates and made provider quality appear random.
 */
export function normalizedText(value) {
  return String(value ?? "")
    .normalize("NFKC")
    .toLocaleLowerCase()
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

export function candidateScore(candidate, track) {
  const title = similarity(candidate.title ?? candidate.trackName, track.title);
  const artist = similarity(candidate.artist ?? candidate.artistName, track.artist);
  let score = title * 4 + artist * 3;
  const duration = finiteNumber(candidate.durationSec ?? candidate.duration, 0);
  if (track.durationSec > 0 && duration > 0) {
    const difference = Math.abs(duration - track.durationSec);
    const tolerance = Math.max(5, track.durationSec * 0.08);
    if (difference <= tolerance) score += 3;
    else if (difference <= 30) score += 1;
    else score -= 2;
  }
  if (candidate.synced) score += 1;
  return score;
}

function similarity(left, right) {
  const lhs = normalizedText(left);
  const rhs = normalizedText(right);
  if (!lhs || !rhs) return 0;
  if (lhs === rhs) return 2;
  return lhs.includes(rhs) || rhs.includes(lhs) ? 1 : 0;
}

/**
 * Resolves lyrics concurrently. Only LRCLIB is enabled by default. Other
 * providers are opt-in through an explicit URL and feature flag because their
 * terms and response stability must be reviewed before a public release.
 */
export async function lookupLyrics(track, options = {}) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const env = options.env ?? process.env;
  const providerNames = providerList(env, options.providers);
  const totalController = new AbortController();
  const totalTimer = setTimeout(() => totalController.abort(), TOTAL_LOOKUP_TIMEOUT_MS);
  try {
    const jobs = providerNames.map(name => lookupProvider(name, track, {
      env,
      fetchImpl,
      signal: totalController.signal,
    }));
    const settled = await Promise.allSettled(jobs);
    const candidates = settled
      .flatMap(result => result.status === "fulfilled" && result.value ? [result.value] : [])
      .filter(candidate => candidate.document);
    candidates.sort((left, right) => right.score - left.score);
    const best = candidates[0] ?? null;
    return {
      candidates,
      best: best && best.score >= 5 ? best.document : null,
      negative: !best || best.score < 5,
      retryAt: !best || best.score < 5 ? Date.now() + NEGATIVE_CACHE_MS : null,
    };
  } finally {
    clearTimeout(totalTimer);
  }
}

export function providerList(env = process.env, explicit) {
  if (Array.isArray(explicit) && explicit.length) return explicit.map(String);
  const configured = String(env.LYRICS_PROVIDERS ?? "lrclib")
    .split(",")
    .map(item => item.trim().toLowerCase())
    .filter(Boolean);
  return configured.length ? [...new Set(configured)] : ["lrclib"];
}

async function lookupProvider(name, track, options) {
  switch (String(name).toLowerCase()) {
    case "lrclib":
      return lookupLRCLIB(track, options);
    case "qq":
    case "kugou":
    case "netease":
      return lookupConfiguredProvider(String(name).toLowerCase(), track, options);
    default:
      return null;
  }
}

async function lookupLRCLIB(track, { env, fetchImpl, signal }) {
  const getURL = new URL(env.LRCLIB_GET_URL || DEFAULT_LRCLIB_GET_URL);
  getURL.searchParams.set("track_name", track.title);
  getURL.searchParams.set("artist_name", track.artist);
  if (track.durationSec > 0) getURL.searchParams.set("duration", String(track.durationSec));
  const direct = await fetchJSON(getURL, fetchImpl, signal, "lrclib");
  const directCandidate = candidateFromProvider("lrclib", direct, track);
  if (directCandidate?.document) return directCandidate;

  const searchURL = new URL(env.LRCLIB_SEARCH_URL || DEFAULT_LRCLIB_SEARCH_URL);
  searchURL.searchParams.set("q", `${track.title} ${track.artist}`.trim());
  const searched = await fetchJSON(searchURL, fetchImpl, signal, "lrclib");
  const results = Array.isArray(searched) ? searched : [];
  return results
    .map(result => candidateFromProvider("lrclib", result, track))
    .filter(Boolean)
    .sort((left, right) => right.score - left.score)[0] ?? null;
}

async function lookupConfiguredProvider(name, track, { env, fetchImpl, signal }) {
  const key = name.toUpperCase();
  const configuredURL = cleanText(env[`LYRICS_${key}_URL`]);
  if (!configuredURL) return null;
  const url = new URL(configuredURL);
  url.searchParams.set("track_name", track.title);
  url.searchParams.set("artist_name", track.artist);
  if (track.durationSec > 0) url.searchParams.set("duration", String(track.durationSec));
  const payload = await fetchJSON(url, fetchImpl, signal, name);
  return candidateFromProvider(name, payload, track);
}

async function fetchJSON(url, fetchImpl, totalSignal, provider) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
  const abort = () => controller.abort();
  totalSignal?.addEventListener("abort", abort, { once: true });
  try {
    const response = await fetchImpl(url, {
      headers: { "user-agent": "OpenLyrics/1.2 (private beta lyric sync)" },
      signal: controller.signal,
    });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
    totalSignal?.removeEventListener("abort", abort);
  }
}

function candidateFromProvider(source, payload, track) {
  if (!payload) return null;
  const result = Array.isArray(payload) ? payload[0] : payload;
  if (!result || result.instrumental === true) return null;
  const title = cleanText(result.trackName ?? result.track_name ?? result.title ?? track.title);
  const artist = cleanText(result.artistName ?? result.artist_name ?? result.artist ?? track.artist);
  const durationSec = finiteNumber(result.duration ?? result.durationSec, track.durationSec);
  const syncedText = firstString(result.syncedLyrics, result.synced_lyrics, result.lrc, result.qrc, result.krc, result.yrc);
  const plainText = firstString(result.plainLyrics, result.plain_lyrics, result.lyrics, result.text);
  const syncedLines = syncedText ? parseLRC(syncedText) : [];
  const lines = syncedLines.length ? syncedLines : parsePlainLyrics(plainText, durationSec);
  if (!lines.length) return null;
  const document = documentFromLines({
    trackID: track.trackID,
    title,
    artist,
    durationSec,
    source,
    lines,
  });
  if (!document) return null;
  return {
    source,
    title,
    artist,
    durationSec,
    synced: syncedLines.length > 0,
    score: candidateScore({ title, artist, durationSec, synced: syncedLines.length > 0 }, track),
    document,
  };
}

function firstString(...values) {
  return values.find(value => typeof value === "string" && value.trim()) ?? null;
}

function cleanText(value) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text || null;
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

export const lyricCacheTTL = {
  successMs: SUCCESS_CACHE_MS,
  negativeMs: NEGATIVE_CACHE_MS,
};
