// PlaybackSession — one alarm-driven loop that polls Spotify, computes the
// current lyric line, and pushes Live Activity updates over APNs. Runs
// entirely independent of the phone app: this is the never-stall guarantee.

const PLAYER_URL = "https://api.spotify.com/v1/me/player";
const TOKEN_URL = "https://accounts.spotify.com/api/token";
const LRCLIB_URL = "https://lrclib.net/api/get";
const PUSH_HOST_PROD = "https://api.push.apple.com";
const PUSH_HOST_SANDBOX = "https://api.sandbox.push.apple.com";
const APNS_TOPIC = "com.jonathantran.dynamicallyrics.la.push-type.liveactivity";

const FAST_POLL_MS = 5000;    // while playing
const IDLE_POLL_MS = 30000;   // while paused/stopped
const RESUME_GRACE_MS = 10 * 60 * 1000; // idle longer than this -> end activity

export class PlaybackSessionV2 {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.ctx = state; // storage via state.storage
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/register") {
      const body = await request.json();
      await this.state.storage.put({
        updateToken: body.updateToken,
        pushToStartToken: body.pushToStartToken ?? "",
        refreshToken: body.spotifyRefreshToken,
      });
      // Kick the loop immediately.
      await this.state.storage.setAlarm(Date.now() + 1000);
      return Response.json({ ok: true });
    }
    if (url.pathname === "/status") {
      const s = await this.snapshot();
      return Response.json(s);
    }
    if (url.pathname === "/reset") {
      await this.state.storage.deleteAll();
      await this.state.storage.setAlarm(Date.now() + 1000);
      return Response.json({ ok: true, reset: true });
    }
    return new Response("not found", { status: 404 });
  }

  async snapshot() {
    const out = {};
    try {
      const keys = [
        "lastTrackTitle", "lastLine", "isPlaying", "lastError", "lastErrorAt",
        "lastPushAt", "accessTokenExpiresAt", "lastTickAt",
      ];
      for (const k of keys) out[k] = (await this.state.storage.get(k)) ?? null;
      const der = pemToBuffer(this.env.APNS_KEY_P8);
      const digest = await crypto.subtle.digest("SHA-256", der);
      out.keyFp = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).slice(0, 16).join("");
    } catch (e) {
      out.snapshotError = String(e && e.stack ? e.stack : e).slice(0, 300);
    }
    return out;
  }

  // ---- alarm loop -------------------------------------------------------

  async alarm() {
    // Bulletproof scheduling: ANY failure above must never break the alarm
    // chain — a broken chain silently freezes the card forever.
    let playing = false;
    let registered = false;
    let retryDelayMs;
    try {
      await this.state.storage.put("lastTickAt", new Date().toISOString());
      const result = await this.tick();
      retryDelayMs = result?.retryDelayMs;
      playing = (await this.state.storage.get("isPlaying")) === true;
      registered = !!(await this.state.storage.get("updateToken"));
    } catch (err) {
      await this.state.storage.put("lastError", String(err).slice(0, 300));
      await this.state.storage.put("lastErrorAt", new Date().toISOString());
      registered = !!(await this.state.storage.get("updateToken").catch(() => null));
    }
    if (!registered) return;
    await this.state.storage.setAlarm(
      Date.now() + (retryDelayMs ?? (playing ? FAST_POLL_MS : IDLE_POLL_MS))
    );
  }

  async tick() {
    const token = await this.accessToken();
    let res = await fetch(PLAYER_URL, {
      headers: { Authorization: `Bearer ${token}` },
    });

    if (res.status === 401) {
      // Force refresh once.
      await this.state.storage.delete("accessToken");
      const fresh = await this.accessToken();
      res = await fetch(PLAYER_URL, { headers: { Authorization: `Bearer ${fresh}` } });
    }
    if (res.status === 429) {
      const wait = Number(res.headers.get("Retry-After") ?? 5);
      return { retryDelayMs: Math.max(1000, Math.min(wait, 30) * 1000) };
    }
    if (!res.ok && res.status !== 204) {
      throw new Error(`player HTTP ${res.status}`);
    }

    const wasPlaying = (await this.state.storage.get("isPlaying")) === true;
    if (res.status === 204) {
      await this.onStopped(wasPlaying, "no active device");
      return;
    }

    const player = await res.json();
    if (!player.item) {
      await this.onStopped(wasPlaying, "no item");
      return;
    }

    const isPlaying = player.is_playing === true;
    const lastPlayingAt = (await this.state.storage.get("lastPlayingAt")) ?? 0;
    if (!isPlaying && lastPlayingAt > 0 && Date.now() - lastPlayingAt > RESUME_GRACE_MS) {
      await this.onStopped(false, "paused too long");
      return;
    }
    const trackId = player.item.id;
    const title = player.item.name;
    const artist = player.item.artists?.[0]?.name ?? "";
    const durationSec = Math.round((player.item.duration_ms ?? 0) / 1000);
    const positionSec = Math.round((player.progress_ms ?? 0) / 1000);

    // Persist both sides of the state transition. Leaving this true after a
    // pause keeps the DO on the fast loop and makes every paused tick look
    // like a fresh play-state change.
    await this.state.storage.put("isPlaying", isPlaying);

    // Lyrics for this track (cached per track id).
    const lines = await this.lyricsFor(trackId, title, artist, durationSec);

    // Current + next line at the projected position.
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].t <= positionSec) idx = i; else break;
    }
    const currentLine = idx >= 0 ? lines[idx].text : "♪";
    const nextLine = idx >= 0 && idx + 1 < lines.length ? lines[idx + 1].text : null;

    const now = Math.floor(Date.now() / 1000);
    const progressStart = now - positionSec;
    const contentState = {
      trackTitle: title,
      artistName: artist,
      currentLine,
      nextLine,
      isPlaying,
      progressStart,
      progressEnd: progressStart + Math.max(durationSec, positionSec + 1),
    };

    // Push on meaningful change OR a ~45s keep-alive pulse while playing —
    // without the pulse, instrumental gaps let stale-date expire and the
    // card dims/freezes even though everything is healthy.
    const lastTrack = await this.state.storage.get("lastTrackId");
    const trackChanged = lastTrack !== trackId;
    const lineKey = `${title}|${currentLine}|${isPlaying}`;
    const lineChanged = lineKey !== (await this.state.storage.get("lastLineKey"));
    const lastPushAt = (await this.state.storage.get("lastPushAt")) ?? 0;
    const keepAlive = isPlaying && !trackChanged && !lineChanged &&
      Date.now() - lastPushAt > 45_000;

    if (trackChanged || lineChanged || keepAlive || (wasPlaying && !isPlaying)) {
      const priority = trackChanged || (wasPlaying && !isPlaying) ? 10 : 5;
      await this.push(contentState, priority);
      await this.state.storage.put("lastTrackId", trackId);
      await this.state.storage.put("lastLineKey", lineKey);
      await this.state.storage.put("lastTrackTitle", title);
      await this.state.storage.put("lastLine", currentLine);
    }
    if (isPlaying) await this.state.storage.put("lastPlayingAt", Date.now());
    console.log(`poll: "${title}" pos=${positionSec}s playing=${isPlaying} lines=${lines.length} pushed=${trackChanged ? "track" : lineChanged ? "line" : keepAlive ? "keepalive" : "no"}`);
  }

  async onStopped(wasPlaying, reason) {
    await this.state.storage.put("isPlaying", false);
    const lastPlayingAt = (await this.state.storage.get("lastPlayingAt")) ?? 0;
    const idleFor = Date.now() - lastPlayingAt;

    if (idleFor > RESUME_GRACE_MS) {
      // Long-gone: dismiss the card so it doesn't zombie on the lock screen.
      await this.pushEnd();
      await this.state.storage.put("lastLineKey", "");
      await this.state.storage.put("lastTrackId", "");
    } else if (wasPlaying) {
      // Brief pause: flip the card to paused rendering immediately.
      await this.push(
        {
          trackTitle: (await this.state.storage.get("lastTrackTitle")) ?? "Paused",
          artistName: "",
          currentLine: "Paused",
          nextLine: null,
          isPlaying: false,
          progressStart: Math.floor(Date.now() / 1000),
          progressEnd: null,
          frozenProgress: null,
        },
        10
      );
    }
    void reason;
  }

  // ---- Spotify auth -----------------------------------------------------

  async accessToken() {
    const expiresAt = await this.state.storage.get("accessTokenExpiresAt");
    const cached = await this.state.storage.get("accessToken");
    if (cached && typeof expiresAt === "number" && Date.now() < expiresAt - 60_000) {
      return cached;
    }
    const refreshToken = await this.state.storage.get("refreshToken");
    if (!refreshToken) throw new Error("no refresh token registered");

    const body = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: this.env.SPOTIFY_CLIENT_ID,
    });
    const res = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!res.ok) throw new Error(`token refresh HTTP ${res.status}`);
    const tokens = await res.json();
    await this.state.storage.put("accessToken", tokens.access_token);
    await this.state.storage.put(
      "accessTokenExpiresAt",
      Date.now() + (tokens.expires_in ?? 3600) * 1000
    );
    // Spotify may rotate the refresh token; keep the newest.
    if (tokens.refresh_token) {
      await this.state.storage.put("refreshToken", tokens.refresh_token);
    }
    return tokens.access_token;
  }

  // ---- lyrics -----------------------------------------------------------

  async lyricsFor(trackId, title, artist, durationSec) {
    const cached = await this.state.storage.get(`lyrics:${trackId}`);
    if (Array.isArray(cached)) return cached;
    if (cached?.kind === "fallback" && Date.now() < cached.retryAt) return cached.lines;

    const url = new URL(LRCLIB_URL);
    url.searchParams.set("track_name", title);
    url.searchParams.set("artist_name", artist);
    if (durationSec > 0) url.searchParams.set("duration", String(durationSec));

    const res = await fetch(url, {
      headers: { "user-agent": "Dynamicallyrics/0.1 (personal sync server)" },
    });
    let lines = [];
    if (res.ok) {
      const data = await res.json();
      if (data.syncedLyrics) {
        lines = parseLRC(data.syncedLyrics);
      }
    }
    if (lines.length === 0) {
      lines = [{ t: 0, text: "♪" }];
      // Do not cache a permanent miss: catalog updates and transient LRCLIB
      // failures should be able to heal without changing tracks. A short
      // negative-cache window prevents a paused/no-lyrics track from hammering
      // LRCLIB on every alarm.
      await this.state.storage.put(`lyrics:${trackId}`, {
        kind: "fallback",
        lines,
        retryAt: Date.now() + 15 * 60 * 1000,
      });
      return lines;
    }
    await this.state.storage.put(`lyrics:${trackId}`, lines);
    return lines;
  }

  // ---- APNs push --------------------------------------------------------

  async pushJwt() {
    // APNs rate-limits provider-token rotation (TooManyProviderTokenUpdates)
    // — mint once and reuse for ~50 minutes like every production sender.
    const cachedJwt = await this.state.storage.get("providerJwt");
    const cachedAt = await this.state.storage.get("providerJwtAt");
    if (cachedJwt && typeof cachedAt === "number" &&
        Date.now() - cachedAt < 50 * 60 * 1000) {
      return cachedJwt;
    }
    const [headerB64, claimsB64] = [
      b64url(JSON.stringify({ alg: "ES256", kid: this.env.APNS_KEY_ID })),
      b64url(JSON.stringify({ iss: this.env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })),
    ];
    const signingInput = `${headerB64}.${claimsB64}`;
    const keyData = pemToBuffer(this.env.APNS_KEY_P8);
    const key = await crypto.subtle.importKey(
      "pkcs8", keyData, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
    );
    const sig = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, key,
      new TextEncoder().encode(signingInput)
    ); // WebCrypto returns raw r||s — exactly what APNs wants.
    const jwt = `${headerB64}.${claimsB64}.${b64url(new Uint8Array(sig))}`;
    await this.state.storage.put("providerJwt", jwt);
    await this.state.storage.put("providerJwtAt", Date.now());
    return jwt;
  }

  async push(contentState, priority) {
    const updateToken = await this.state.storage.get("updateToken");
    if (!updateToken) return;
    const status = await this.apnsRequest(updateToken, {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "update",
        "stale-date": Math.floor(Date.now() / 1000) + 120,
        "content-state": contentState,
      },
    }, priority);
    if (status === 200) {
      await this.state.storage.put("lastPushAt", Date.now());
    }
    console.log(`push p${priority}: HTTP ${status} "${contentState.trackTitle}"`);
  }

  async pushEnd() {
    const updateToken = await this.state.storage.get("updateToken");
    if (!updateToken) return;
    const status = await this.apnsRequest(updateToken, {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "end",
        "dismissal-date": Math.floor(Date.now() / 1000),
        "content-state": {
          trackTitle: "", artistName: "", currentLine: "",
          nextLine: null, isPlaying: false,
        },
      },
    }, 10);
    if (status === 200 || status === 410) {
      // An ended activity cannot be updated again. Clearing the token also
      // stops the alarm chain from sending the same end event every 30s.
      await this.state.storage.put("updateToken", "");
      if (status === 200) await this.state.storage.put("lastPushAt", Date.now());
    }
  }

  async apnsRequest(token, payload, priority) {
    const jwt = await this.pushJwt();
    const pushHost = this.apnsHost();
    let res;
    // APNs occasionally serves 500s; retry with backoff before giving up.
    for (let attempt = 1; attempt <= 3; attempt++) {
      res = await fetch(`${pushHost}/3/device/${token}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "liveactivity",
          "apns-priority": String(priority ?? 10),
          "authorization": `bearer ${jwt}`,
        },
        body: JSON.stringify(payload),
      });
      if (res.status < 500 || attempt === 3) break;
      console.log(`push attempt ${attempt}: HTTP ${res.status}, retrying`);
      await new Promise(r => setTimeout(r, 1500 * attempt));
    }
    if (res.status === 410) {
      // Activity gone (user dismissed / ended): stop pushing until re-register.
      await this.state.storage.put("updateToken", "");
      await this.state.storage.put("lastError", "activity ended remotely (410)");
    } else if (!res.ok) {
      const text = await res.text();
      console.log(`push FAILED ${res.status}: ${text.slice(0, 200)}`);
      await this.state.storage.put("lastError", `push ${res.status}: ${text.slice(0, 200)}`);
      await this.state.storage.put("lastErrorAt", new Date().toISOString());
    }
    return res.status;
  }

  apnsHost() {
    const configured = typeof this.env.APNS_HOST === "string"
      ? this.env.APNS_HOST.trim().replace(/\/+$/, "")
      : "";
    const host = configured || PUSH_HOST_PROD;
    if (host !== PUSH_HOST_PROD && host !== PUSH_HOST_SANDBOX) {
      throw new Error("APNS_HOST must be a supported Apple push host");
    }
    return host;
  }
}

// ---- helpers -------------------------------------------------------------

function parseLRC(lrc) {
  const parsed = [];
  let offset = 0;
  for (const raw of lrc.split("\n")) {
    const line = raw.replace(/\r$/, "");
    const offsetMatch = line.match(/^\[offset:\s*([+-]?\d+)\]\s*$/i);
    if (offsetMatch) {
      offset += Number(offsetMatch[1]) / 1000;
      continue;
    }

    let rest = line;
    const times = [];
    let match;
    while ((match = rest.match(/^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/))) {
      const fraction = match[3] ? Number(match[3]) / (10 ** match[3].length) : 0;
      times.push(Math.max(0, Number(match[1]) * 60 + Number(match[2]) + fraction));
      rest = rest.slice(match[0].length);
    }
    const text = rest.trim();
    if (text) for (const t of times) parsed.push({ t, text });
  }
  const out = parsed.map(({ t, text }) => ({ t: Math.max(0, t - offset), text }));
  out.sort((a, b) => a.t - b.t);
  return out;
}

function pemToBuffer(pem) {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

function b64url(input) {
  // Accept strings (UTF-8 encoded) or bytes — iterating a raw string would
  // silently produce garbage base64 of char codes.
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
