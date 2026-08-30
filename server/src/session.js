// The phone owns Live Activity updates while its heartbeat lease is valid.
// This Durable Object polls Spotify and becomes the fallback writer only when
// the phone stops reporting healthy data.

const PLAYER_URL = "https://api.spotify.com/v1/me/player";
const TOKEN_URL = "https://accounts.spotify.com/api/token";
const LRCLIB_URL = "https://lrclib.net/api/get";
const PUSH_HOST_PROD = "https://api.push.apple.com";
const PUSH_HOST_SANDBOX = "https://api.sandbox.push.apple.com";
const APNS_TOPIC = "com.jonathantran.dynamicallyrics.la.push-type.liveactivity";
const FAST_POLL_MS = 5_000;
const IDLE_POLL_MS = 10_000;
const PHONE_LEASE_MS = 15_000;
const PAUSE_SESSION_MS = 10 * 60 * 1_000;
const KEEPALIVE_MS = 45_000;
const SCHEDULE_HORIZON_SEC = 75;
const SCHEDULE_MAX_LINES = 32;
const SCHEDULE_REFILL_LEAD_SEC = 20;
const SCHEDULE_REFILL_MIN_MS = 15_000;
const PAYLOAD_LIMIT_BYTES = 3_500;
const SWIFT_REFERENCE_EPOCH_OFFSET = 978_307_200;
const REQUEST_TIMEOUT_MS = 10_000;
const APNS_TIMEOUT_MS = 8_000;
const COMMAND_TTL_MS = 8_000;
const START_RETRY_MS = 30_000;

export class PlaybackSessionV2 {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/register") {
      const body = await request.json();
      const bootstrap = body.bootstrap === true;
      const oldRefreshToken = await this.state.storage.get("refreshToken");
      const existingClientAuthToken = await this.state.storage.get("clientAuthToken");
      if (bootstrap && existingClientAuthToken) {
        return Response.json({ error: "server is already paired" }, { status: 401 });
      }

      // The first registration is allowed without a bearer token. Validate
      // the Spotify refresh token before issuing a private server token so an
      // unrelated caller cannot claim the single-user session.
      if (bootstrap) {
        const previousAccessToken = await this.state.storage.get("accessToken");
        const previousAccessTokenExpiresAt = await this.state.storage.get("accessTokenExpiresAt");
        await this.state.storage.put({
          refreshToken: body.spotifyRefreshToken,
          accessToken: "",
          accessTokenExpiresAt: 0,
        });
        try {
          await this.accessToken();
        } catch {
          if (oldRefreshToken) {
            await this.state.storage.put({
              refreshToken: oldRefreshToken,
              accessToken: previousAccessToken ?? "",
              accessTokenExpiresAt: previousAccessTokenExpiresAt ?? 0,
            });
          } else {
            await this.state.storage.delete("refreshToken");
            await this.state.storage.delete("accessToken");
            await this.state.storage.delete("accessTokenExpiresAt");
          }
          return Response.json({ error: "Spotify token validation failed" }, { status: 401 });
        }
      }

      const accountChanged = Boolean(oldRefreshToken && oldRefreshToken !== body.spotifyRefreshToken);
      const values = {
        refreshToken: body.spotifyRefreshToken,
        clientSchemaVersion: numericVersion(body.clientSchemaVersion),
        supportsRemoteStart: body.supportsRemoteStart !== false,
        supportsInputPushToken: body.supportsInputPushToken === true,
        lyricOffsetMs: finiteNumber(body.lyricOffsetMs, 0),
        albumDominantRGB: validRGB(body.albumDominantRGB) ? body.albumDominantRGB : null,
        albumDominantTrackID: body.trackID ?? null,
        autoStartEnabled: body.autoStartEnabled !== false,
        phoneLeaseExpiresAt: Date.now() + PHONE_LEASE_MS,
        currentWriter: "phone",
      };
      if (bootstrap) values.clientAuthToken = randomHex(32);
      if (accountChanged) {
        // A refresh token identifies the connected Spotify account. Never use
        // an access token or playback snapshot from the previous account.
        values.accessToken = "";
        values.accessTokenExpiresAt = 0;
        values.updateToken = "";
        values.phoneActivityState = "none";
        values.activeTrack = null;
        values.activeContentState = null;
        values.playbackSessionID = "";
        values.playbackSessionClosed = true;
        values.lastStartAttemptAt = 0;
        values.lastStartAttemptCount = 0;
        values.lastSentTrackID = "";
        values.lastSentScheduleV2 = [];
        values.lastSchedulePushAt = 0;
        values.forceServerUpdate = true;
        values.noItemSamples = 0;
        values.playbackSessionDismissed = false;
        values.dismissalSource = null;
      }
      if (body.updateToken) {
        values.updateToken = body.updateToken;
        values.phoneActivityState = "active";
        values.forceServerUpdate = true;
        values.playbackSessionDismissed = false;
        values.dismissalSource = null;
      }
      if (body.pushToStartToken) values.pushToStartToken = body.pushToStartToken;
      await this.state.storage.put(values);
      await this.state.storage.setAlarm(Date.now() + 1_000);
      return Response.json({
        ok: true,
        ...(bootstrap ? { authToken: values.clientAuthToken } : {}),
        writer: await this.currentWriter(),
        serverRevision: (await this.state.storage.get("serverRevision")) ?? 0,
        playbackSessionDismissed:
          (await this.state.storage.get("playbackSessionDismissed")) === true,
        dismissalSource: (await this.state.storage.get("dismissalSource")) ?? null,
      });
    }

    if (request.method === "POST" && url.pathname === "/authorize") {
      const body = await request.json();
      const expected = await this.state.storage.get("clientAuthToken");
      const token = typeof body?.token === "string" ? body.token : "";
      const authorized = Boolean(expected) && constantTimeEqual(token, expected);
      return Response.json(
        authorized ? { ok: true } : { error: "unauthorized" },
        { status: authorized ? 200 : 401 },
      );
    }

    if (request.method === "POST" && url.pathname === "/heartbeat") {
      const body = await request.json();
      const now = Date.now();
      const values = {
        phoneLeaseExpiresAt: now + PHONE_LEASE_MS,
        currentWriter: "phone",
        phoneActivityState: body.activityState,
        phoneRevision: finiteNumber(body.localRevision, 0),
        phoneGeneratedAtMs: finiteNumber(body.sentAtMs, now),
        phoneTrackID: typeof body.trackID === "string" ? body.trackID : "",
        clientSchemaVersion: numericVersion(body.clientSchemaVersion),
        lyricOffsetMs: finiteNumber(body.lyricOffsetMs, 0),
        autoStartEnabled: body.autoStartEnabled !== false,
      };
      if (Object.prototype.hasOwnProperty.call(body, "albumDominantRGB") &&
          validRGB(body.albumDominantRGB)) {
        values.albumDominantRGB = body.albumDominantRGB;
        values.albumDominantTrackID = body.trackID ?? null;
      }
      if (body.updateToken) {
        values.updateToken = body.updateToken;
        if (body.activityState === "active") {
          values.playbackSessionDismissed = false;
          values.dismissalSource = null;
        }
      }
      if (body.activityState === "dismissed") {
        values.updateToken = "";
        values.playbackSessionDismissed = true;
        values.dismissalSource = "phone";
      } else if (body.activityState === "none" && !body.updateToken) {
        values.updateToken = "";
      }
      await this.state.storage.put(values);
      return Response.json({
        ok: true,
        writer: "phone",
        leaseExpiresAt: now + PHONE_LEASE_MS,
        serverRevision: (await this.state.storage.get("serverRevision")) ?? 0,
        playbackSessionDismissed:
          (await this.state.storage.get("playbackSessionDismissed")) === true,
        dismissalSource: (await this.state.storage.get("dismissalSource")) ?? null,
      });
    }

    if (request.method === "POST" && url.pathname === "/command") {
      const body = await request.json();
      const commandID = String(body.commandID ?? "");
      const issuedAtMs = finiteNumber(body.issuedAtMs, Date.now());
      if (!commandID || Math.abs(Date.now() - issuedAtMs) > COMMAND_TTL_MS ||
          !["toggle", "next", "previous"].includes(body.command)) {
        return Response.json({ error: "expired or invalid command" }, { status: 400 });
      }
      const commandKey = `command:${commandID}`;
      const previous = await this.state.storage.get(commandKey);
      if (previous) return Response.json(previous);
      const accepted = await this.executeCommand(body.command);
      const result = {
        ok: accepted,
        accepted,
        commandID,
        serverRevision: (await this.state.storage.get("serverRevision")) ?? 0,
      };
      await this.state.storage.put(commandKey, result);
      await this.state.storage.setAlarm(Date.now() + 1_000);
      return Response.json(result, { status: accepted ? 200 : 502 });
    }

    if (request.method === "GET" && url.pathname === "/status") {
      return Response.json(await this.snapshot());
    }
    if (request.method === "POST" && url.pathname === "/reset") {
      if (typeof this.state.storage.deleteAlarm === "function") {
        await this.state.storage.deleteAlarm();
      }
      await this.state.storage.deleteAll();
      return Response.json({ ok: true, reset: true });
    }
    return new Response("not found", { status: 404 });
  }

  async snapshot() {
    const keys = [
      "phoneLeaseExpiresAt", "pushToStartToken", "playbackSessionID",
      "playbackSessionStartAttempted", "playbackSessionDismissed", "lastAPNsResult",
      "dismissalSource",
      "clientSchemaVersion", "lastPayloadSize", "lastScheduleCount",
      "lastScheduleHorizonEpoch", "lastArtworkStatus", "lastTrackTitle", "lastLine",
      "isPlaying", "lastError", "lastErrorAt", "lastPushAt", "lastTickAt",
      "serverRevision", "phoneRevision", "lyricOffsetMs", "autoStartEnabled",
      "supportsRemoteStart", "supportsInputPushToken", "lastStartAttemptAt",
      "lastStartAttemptCount", "lastPushReason", "lastSentCurrentLine",
      "lastSentNextLine", "lastSchedulePushAt", "lastEndReason", "refreshToken",
    ];
    const stored = {};
    for (const key of keys) stored[key] = (await this.state.storage.get(key)) ?? null;
    const lease = stored.phoneLeaseExpiresAt ?? 0;
    const out = {
      updateOwner: lease > Date.now() ? "phone" : "server",
      currentOwner: lease > Date.now() ? "phone" : "server",
      phoneLeaseExpiresAt: lease || null,
      phoneLeaseExpiration: lease || null,
      pushToStartAvailable: Boolean(stored.pushToStartToken) && stored.autoStartEnabled !== false,
      pushToStartSupported: stored.supportsRemoteStart === true,
      inputPushTokenSupported: stored.supportsInputPushToken === true,
      spotifyReady: Boolean(stored.refreshToken) && Boolean(this.env.SPOTIFY_CLIENT_ID),
      apnsReady: Boolean(this.env.APNS_KEY_P8 && this.env.APNS_KEY_ID && this.env.APNS_TEAM_ID),
      serverReady: Boolean(stored.refreshToken) && Boolean(this.env.SPOTIFY_CLIENT_ID) &&
        Boolean(this.env.APNS_KEY_P8 && this.env.APNS_KEY_ID && this.env.APNS_TEAM_ID),
      playbackSessionID: stored.playbackSessionID,
      startAttempted: stored.playbackSessionStartAttempted === true,
      startAttemptCount: stored.lastStartAttemptCount ?? 0,
      lastStartAttemptAt: stored.lastStartAttemptAt,
      sessionDismissed: stored.playbackSessionDismissed === true,
      lastAPNsResult: stored.lastAPNsResult,
      lastDeliveryResult: stored.lastAPNsResult,
      payloadSchema: stored.clientSchemaVersion ?? 1,
      payloadSize: stored.lastPayloadSize,
      schedule: {
        count: stored.lastScheduleCount ?? 0,
        horizonEpoch: stored.lastScheduleHorizonEpoch,
      },
      artwork: stored.lastArtworkStatus,
      trackTitle: stored.lastTrackTitle,
      currentLine: stored.lastLine,
      isPlaying: stored.isPlaying === true,
      serverRevision: stored.serverRevision ?? 0,
      phoneRevision: stored.phoneRevision ?? 0,
      lyricOffsetMs: stored.lyricOffsetMs ?? 0,
      lastPushAt: stored.lastPushAt,
      lastTickAt: stored.lastTickAt,
      lastError: stored.lastError,
      lastErrorAt: stored.lastErrorAt,
      readiness: {
        spotify: Boolean(stored.refreshToken) && Boolean(this.env.SPOTIFY_CLIENT_ID),
        apns: Boolean(this.env.APNS_KEY_P8 && this.env.APNS_KEY_ID && this.env.APNS_TEAM_ID),
      },
    };
    try {
      if (this.env.APNS_KEY_P8) {
        const digest = await crypto.subtle.digest("SHA-256", pemToBuffer(this.env.APNS_KEY_P8));
        out.keyFp = [...new Uint8Array(digest)]
          .map(byte => byte.toString(16).padStart(2, "0"))
          .slice(0, 16)
          .join("");
      }
    } catch (error) {
      out.keyError = String(error).slice(0, 160);
    }
    return out;
  }

  async alarm() {
    let isPlaying = false;
    let retryDelayMs;
    try {
      await this.state.storage.put("lastTickAt", new Date().toISOString());
      const result = await this.tick();
      retryDelayMs = result?.retryDelayMs;
      isPlaying = (await this.state.storage.get("isPlaying")) === true;
    } catch (error) {
      await this.recordError(error);
    }
    const refreshToken = await this.state.storage.get("refreshToken");
    const updateToken = await this.state.storage.get("updateToken");
    const startToken = await this.state.storage.get("pushToStartToken");
    if (!refreshToken || (!updateToken && !startToken)) return;
    await this.state.storage.setAlarm(
      Date.now() + (retryDelayMs ?? (isPlaying ? FAST_POLL_MS : IDLE_POLL_MS))
    );
  }

  async tick() {
    const result = await this.fetchPlayer();
    if (result.retryDelayMs) return result;
    if (!result.player?.item) {
      await this.onNoActiveItem();
      return {};
    }

    await this.state.storage.put("noItemSamples", 0);
    const player = await this.normalizedPlayer(result.player);
    const wasPlaying = (await this.state.storage.get("isPlaying")) === true;
    const pausedAt = (await this.state.storage.get("pausedAt")) ?? 0;
    const pauseExpired = !player.isPlaying && pausedAt > 0 &&
      Date.now() - pausedAt >= PAUSE_SESSION_MS;
    if (player.isPlaying) {
      const sessionMissing = !(await this.state.storage.get("playbackSessionID"));
      const resumedAfterLongPause = pausedAt > 0 &&
        Date.now() - pausedAt >= PAUSE_SESSION_MS;
      if (sessionMissing || resumedAfterLongPause) await this.beginPlaybackSession(player.trackID);
      await this.state.storage.put({ pausedAt: 0, lastPlayingAt: Date.now() });
    } else if (!pausedAt) {
      await this.state.storage.put("pausedAt", Date.now());
    }
    if (pauseExpired) await this.closePlaybackSession("paused for 10 minutes");

    await this.state.storage.put("isPlaying", player.isPlaying);
    const lines = await this.lyricsFor(
      player.trackID,
      player.title,
      player.artist,
      player.durationMs / 1_000
    );
    const offsetMs = finiteNumber(await this.state.storage.get("lyricOffsetMs"), 0);
    const schemaVersion = numericVersion(await this.state.storage.get("clientSchemaVersion"));
    const nextRevision = ((await this.state.storage.get("serverRevision")) ?? 0) + 1;
    const contentState = buildContentState(
      { ...player, lines },
      { nowMs: Date.now(), offsetMs, schemaVersion, revision: nextRevision }
    );
    await this.storeCurrentState(contentState);

    const writer = await this.currentWriter();
    const previousWriter = (await this.state.storage.get("currentWriter")) ?? "server";
    await this.state.storage.put("currentWriter", writer);
    if (writer === "phone") return {};

    const updateToken = await this.state.storage.get("updateToken");
    if (player.isPlaying && !updateToken) {
      await this.startActivityIfNeeded(contentState);
      return {};
    }
    if (!updateToken) return {};
    const reason = await this.updateReason(contentState, {
      ownershipChanged: previousWriter !== "server",
      wasPlaying,
    });
    if (reason) await this.pushUpdate(contentState, reason);
    return {};
  }

  async fetchPlayer() {
    const token = await this.accessToken();
    let response = await fetchWithTimeout(PLAYER_URL, {
      headers: { Authorization: `Bearer ${token}` },
    }, REQUEST_TIMEOUT_MS);
    if (response.status === 401) {
      await this.state.storage.delete("accessToken");
      response = await fetchWithTimeout(PLAYER_URL, {
        headers: { Authorization: `Bearer ${await this.accessToken()}` },
      }, REQUEST_TIMEOUT_MS);
    }
    if (response.status === 429) {
      const seconds = finiteNumber(response.headers.get("Retry-After"), 5);
      return { retryDelayMs: Math.max(1_000, Math.min(seconds, 30) * 1_000) };
    }
    if (response.status === 204) return { player: null };
    if (!response.ok) throw new Error(`player HTTP ${response.status}`);
    return { player: await response.json() };
  }

  async normalizedPlayer(raw) {
    const item = raw.item;
    const oldTrack = await this.state.storage.get("activeTrack");
    const responseTrackID = cleanString(item.id ?? item.uri);
    const responseTitle = cleanString(item.name);
    const responseArtist = cleanString(item.artists?.[0]?.name ?? item.show?.publisher);
    const metadataMatches = Boolean(oldTrack) &&
      (!responseTitle || oldTrack.title === responseTitle) &&
      (!responseArtist || oldTrack.artist === responseArtist);
    // Spotify can omit the item ID in a partial player response. Keep the
    // accepted stable ID when the returned metadata still identifies the same
    // song; otherwise a transient response would clear valid artwork.
    const trackID = responseTrackID ?? (metadataMatches
      ? oldTrack.trackID
      : `${responseTitle ?? "track"}:${item.duration_ms ?? 0}`);
    const sameTrack = oldTrack?.trackID === trackID ||
      (!responseTrackID && metadataMatches);
    const responseArtwork = cleanString(item.album?.images?.[0]?.url);
    const albumImageURL = responseArtwork ?? (sameTrack ? oldTrack?.albumImageURL ?? null : null);
    const artist = responseArtist
      ?? (sameTrack ? oldTrack?.artist ?? "" : "");
    const title = responseTitle ?? (sameTrack ? oldTrack?.title ?? "Unknown track" : "Unknown track");
    const durationMs = item.duration_ms == null
      ? (sameTrack ? oldTrack?.durationMs ?? 0 : 0)
      : Math.max(0, finiteNumber(item.duration_ms, 0));
    const heartbeatRGB = await this.state.storage.get("albumDominantRGB");
    const heartbeatTrackID = await this.state.storage.get("albumDominantTrackID");
    const hasReportedProgress = raw.progress_ms !== null &&
      raw.progress_ms !== undefined;
    const reportedProgress = Number(raw.progress_ms);
    const hasProgress = hasReportedProgress && Number.isFinite(reportedProgress);
    const previousProgress = sameTrack
      ? Math.max(0, finiteNumber(oldTrack?.progressMs, 0))
      : 0;
    const previousObservedAt = sameTrack
      ? finiteNumber(oldTrack?.progressObservedAt, 0)
      : 0;
    let progressMs = hasProgress ? Math.max(0, reportedProgress) : previousProgress;
    // Some Spotify responses omit progress_ms during a transient refresh.
    // Project the last trusted sample instead of jumping to zero.
    if (!hasProgress && raw.is_playing === true && previousObservedAt > 0) {
      progressMs += Math.max(0, Date.now() - previousObservedAt);
    }
    progressMs = durationMs > 0 ? Math.min(progressMs, durationMs) : progressMs;
    const completed = raw.is_playing !== true && durationMs > 0 &&
      progressMs >= durationMs - 750;
    const normalized = {
      trackID,
      title,
      artist: String(artist),
      albumImageURL,
      durationMs,
      progressMs,
      progressObservedAt: Date.now(),
      isPlaying: raw.is_playing === true && !completed,
      completed,
      albumDominantRGB: heartbeatTrackID === trackID && heartbeatRGB != null && validRGB(heartbeatRGB)
        ? heartbeatRGB
        : (sameTrack ? oldTrack?.albumDominantRGB ?? null : null),
    };
    await this.state.storage.put({
      activeTrack: normalized,
      lastArtworkStatus: {
        trackID,
        hasURL: Boolean(albumImageURL),
        preservedFromSameTrack: !responseArtwork && sameTrack && Boolean(albumImageURL),
      },
    });
    return normalized;
  }

  async beginPlaybackSession(trackID) {
    await this.state.storage.put({
      playbackSessionID: `${Date.now()}-${trackID}`,
      playbackSessionStartAttempted: false,
      lastStartAttemptAt: 0,
      lastStartAttemptCount: 0,
      playbackSessionDismissed: false,
      dismissalSource: null,
      playbackSessionClosed: false,
      forceServerUpdate: true,
      lastSchedulePushAt: 0,
    });
  }

  async closePlaybackSession(reason) {
    if ((await this.state.storage.get("playbackSessionClosed")) === true) return;
    if ((await this.currentWriter()) === "server") await this.pushEnd(reason);
    await this.state.storage.put({
      updateToken: "",
      playbackSessionID: "",
      playbackSessionStartAttempted: false,
      lastStartAttemptAt: 0,
      lastStartAttemptCount: 0,
      playbackSessionDismissed: false,
      dismissalSource: null,
      playbackSessionClosed: true,
      lastSentTrackID: "",
      lastSentScheduleV2: [],
      lastSchedulePushAt: 0,
    });
  }

  async onNoActiveItem() {
    const samples = ((await this.state.storage.get("noItemSamples")) ?? 0) + 1;
    await this.state.storage.put({ noItemSamples: samples, isPlaying: false });
    if (samples < 2) return;
    await this.closePlaybackSession("no active item");
    await this.state.storage.put({
      activeTrack: null,
      activeContentState: null,
      pausedAt: 0,
      lastArtworkStatus: { trackID: null, hasURL: false, confirmedStop: true },
    });
  }

  async currentWriter() {
    const lease = (await this.state.storage.get("phoneLeaseExpiresAt")) ?? 0;
    return lease > Date.now() ? "phone" : "server";
  }

  async executeCommand(command) {
    const token = await this.accessToken();
    const isPlaying = (await this.state.storage.get("isPlaying")) === true;
    const path = command === "toggle"
      ? (isPlaying ? "pause" : "play")
      : command;
    const method = command === "toggle" ? "PUT" : "POST";
    const response = await fetchWithTimeout(`${PLAYER_URL}/${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}` },
    }, REQUEST_TIMEOUT_MS);
    if (response.status === 401) {
      await this.state.storage.delete("accessToken");
      const retryToken = await this.accessToken();
      const retry = await fetchWithTimeout(`${PLAYER_URL}/${path}`, {
        method,
        headers: { Authorization: `Bearer ${retryToken}` },
      }, REQUEST_TIMEOUT_MS);
      if (!retry.ok) throw new Error(`command HTTP ${retry.status}`);
    } else if (!response.ok) {
      throw new Error(`command HTTP ${response.status}`);
    }
    await this.state.storage.put("forceServerUpdate", true);
    return true;
  }

  async updateReason(contentState, context) {
    if (context.ownershipChanged) return "server takeover";
    if ((await this.state.storage.get("forceServerUpdate")) === true) return "registration";
    if ((await this.state.storage.get("lastSentTrackID")) !== contentState.trackID) return "track";
    if ((await this.state.storage.get("lastSentPlaying")) !== contentState.isPlaying) {
      return "play state";
    }
    const hasFutureSchedule = contentState.isPlaying &&
      (contentState.scheduledLinesV2 ?? []).some(line => line.dateEpoch > Date.now() / 1_000);
    if (!hasFutureSchedule &&
        ((await this.state.storage.get("lastSentCurrentLine")) !== contentState.currentLine ||
         (await this.state.storage.get("lastSentNextLine")) !== (contentState.nextLine ?? null))) {
      return "line";
    }
    const oldAnchor = await this.state.storage.get("lastSentProgressStartEpoch");
    const newAnchor = contentState.progressStartEpoch;
    if (typeof oldAnchor === "number" && typeof newAnchor === "number" &&
        Math.abs(oldAnchor - newAnchor) > 0.75) return "seek";
    if ((await this.state.storage.get("lastSentOffsetMs")) !==
        (await this.state.storage.get("lyricOffsetMs"))) return "offset";
    if ((await this.state.storage.get("lastSentAlbumImageURL")) !== contentState.albumImageURL) {
      return "artwork";
    }
    if (contentState.isPlaying) {
      const now = Date.now() / 1_000;
      const sent = (await this.state.storage.get("lastSentScheduleV2")) ?? [];
      const remaining = sent.filter(line => line.dateEpoch > now);
      const horizon = remaining.at(-1)?.dateEpoch ?? 0;
      const candidate = contentState.scheduledLinesV2?.at(-1)?.dateEpoch ?? 0;
      const lastSchedulePushAt = finiteNumber(
        await this.state.storage.get("lastSchedulePushAt"),
        0
      );
      if ((remaining.length < 3 || horizon - now < SCHEDULE_REFILL_LEAD_SEC) &&
          candidate > horizon + 1 &&
          Date.now() - lastSchedulePushAt >= SCHEDULE_REFILL_MIN_MS) {
        return "schedule";
      }
    }
    const lastPushAt = (await this.state.storage.get("lastPushAt")) ?? 0;
    return Date.now() - lastPushAt >= KEEPALIVE_MS ? "keepalive" : null;
  }

  async storeCurrentState(contentState) {
    const schedule = contentState.scheduledLinesV2 ?? [];
    await this.state.storage.put({
      activeContentState: contentState,
      lastTrackTitle: contentState.trackTitle,
      lastLine: contentState.currentLine,
      lastPayloadSize: contentStateSize(contentState),
      lastScheduleCount: schedule.length,
      lastScheduleHorizonEpoch: schedule.at(-1)?.dateEpoch ?? null,
    });
  }

  async startActivityIfNeeded(contentState) {
    if ((await this.state.storage.get("autoStartEnabled")) === false) return;
    if ((await this.state.storage.get("supportsRemoteStart")) === false) return;
    if ((await this.state.storage.get("playbackSessionDismissed")) === true) return;
    // A phone heartbeat can report an active activity before its update token
    // reaches storage. Do not create a second activity during that gap.
    if ((await this.state.storage.get("phoneActivityState")) === "active") return;
    if ((await this.state.storage.get("playbackSessionStartAttempted")) === true) return;
    const startToken = await this.state.storage.get("pushToStartToken");
    if (!startToken) return;
    const lastAttemptAt = finiteNumber(await this.state.storage.get("lastStartAttemptAt"), 0);
    if (Date.now() - lastAttemptAt < START_RETRY_MS) return;
    await this.state.storage.put({
      lastStartAttemptAt: Date.now(),
      lastStartAttemptCount: finiteNumber(await this.state.storage.get("lastStartAttemptCount"), 0) + 1,
    });
    const state = await this.stampState(contentState);
    const aps = {
      timestamp: Math.floor(state.generatedAtEpoch),
      event: "start",
      "attributes-type": "LyricsActivityAttributes",
      attributes: { sessionID: "lyrics" },
      "content-state": state,
      alert: {
        title: "OpenLyrics",
        body: `Lyrics are ready for ${state.trackTitle}.`,
      },
      "stale-date": staleDateFor(state),
    };
    if ((await this.state.storage.get("supportsInputPushToken")) === true) {
      aps["input-push-token"] = 1;
    }
    const status = await this.apnsRequest(startToken, { aps }, 10, "start");
    if (status === 200) {
      await this.state.storage.put({
        playbackSessionStartAttempted: true,
        phoneActivityState: "active",
      });
      await this.recordSuccessfulPush(state, "automatic start");
    }
  }

  async pushUpdate(contentState, reason = "update") {
    const updateToken = await this.state.storage.get("updateToken");
    if (!updateToken) return;
    const state = await this.stampState(contentState);
    const aps = {
      timestamp: Math.floor(state.generatedAtEpoch),
      event: "update",
      "content-state": state,
    };
    if (state.isPlaying) aps["stale-date"] = staleDateFor(state);
    const urgent = ["track", "play state", "seek", "server takeover", "registration"].includes(reason);
    const status = await this.apnsRequest(updateToken, { aps }, urgent ? 10 : 5, "update");
    if (status === 200) await this.recordSuccessfulPush(state, reason);
  }

  async pushEnd(reason = "ended") {
    const updateToken = await this.state.storage.get("updateToken");
    if (!updateToken) return;
    const stored = await this.state.storage.get("activeContentState");
    const fallback = {
      trackTitle: "",
      artistName: "",
      albumImageURL: null,
      currentLine: "",
      nextLine: null,
      isPlaying: false,
    };
    // End events must not reuse a playing state. A stale playing payload can
    // leave the Lock Screen rendering a live progress bar after the server
    // has already closed the playback session.
    const endState = {
      ...(stored ?? fallback),
      isPlaying: false,
      progressStart: null,
      progressEnd: null,
      progressStartEpoch: null,
      progressEndEpoch: null,
      scheduledLines: null,
      scheduledLinesV2: [],
      karaokeStartDate: null,
      karaokeEndDate: null,
      karaokeStartEpoch: null,
      karaokeEndEpoch: null,
      frozenProgress: stored?.frozenProgress ?? null,
    };
    const state = await this.stampState(endState);
    const now = Math.floor(Date.now() / 1_000);
    const status = await this.apnsRequest(updateToken, {
      aps: {
        timestamp: now,
        event: "end",
        "dismissal-date": now,
        "content-state": state,
      },
    }, 10, "end");
    if (status === 200 || status === 410) {
      await this.state.storage.put({ updateToken: "", lastEndReason: reason });
    }
  }

  async stampState(contentState) {
    const revision = ((await this.state.storage.get("serverRevision")) ?? 0) + 1;
    const stamped = compactContentState({
      ...contentState,
      schemaVersion: numericVersion(await this.state.storage.get("clientSchemaVersion")),
      source: "server",
      revision,
      generatedAtEpoch: Date.now() / 1_000,
    });
    await this.state.storage.put("serverRevision", revision);
    return stamped;
  }

  async recordSuccessfulPush(state, reason) {
    const schedule = state.scheduledLinesV2 ?? [];
    await this.state.storage.put({
      forceServerUpdate: false,
      lastPushAt: Date.now(),
      lastSentTrackID: state.trackID ?? "",
      lastSentPlaying: state.isPlaying,
      lastSentProgressStartEpoch: state.progressStartEpoch ?? null,
      lastSentOffsetMs: await this.state.storage.get("lyricOffsetMs"),
      lastSentAlbumImageURL: state.albumImageURL ?? null,
      lastSentCurrentLine: state.currentLine ?? "",
      lastSentNextLine: state.nextLine ?? null,
      lastSentScheduleV2: schedule,
      ...(schedule.length > 0 ? { lastSchedulePushAt: Date.now() } : {}),
      lastPayloadSize: contentStateSize(state),
      lastScheduleCount: schedule.length,
      lastScheduleHorizonEpoch: schedule.at(-1)?.dateEpoch ?? null,
      lastPushReason: reason,
    });
  }

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
    const response = await fetchWithTimeout(TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    }, REQUEST_TIMEOUT_MS);
    if (!response.ok) throw new Error(`token refresh HTTP ${response.status}`);
    const tokens = await response.json();
    await this.state.storage.put({
      accessToken: tokens.access_token,
      accessTokenExpiresAt: Date.now() + finiteNumber(tokens.expires_in, 3_600) * 1_000,
    });
    if (tokens.refresh_token) await this.state.storage.put("refreshToken", tokens.refresh_token);
    return tokens.access_token;
  }

  async lyricsFor(trackID, title, artist, durationSec) {
    const key = `lyrics:${trackID}`;
    const cached = await this.state.storage.get(key);
    if (Array.isArray(cached)) return cached;
    if (cached?.kind === "fallback" && Date.now() < cached.retryAt) return cached.lines;
    const url = new URL(LRCLIB_URL);
    url.searchParams.set("track_name", title);
    url.searchParams.set("artist_name", artist);
    if (durationSec > 0) url.searchParams.set("duration", String(durationSec));
    const response = await fetchWithTimeout(url, {
      headers: { "user-agent": "OpenLyrics/1.2 (personal sync server)" },
    }, REQUEST_TIMEOUT_MS);
    let lines = [];
    if (response.ok) {
      const data = await response.json();
      if (data.syncedLyrics) lines = parseLRC(data.syncedLyrics);
    }
    if (!lines.length) {
      const searchURL = new URL("https://lrclib.net/api/search");
      searchURL.searchParams.set("q", `${title} ${artist}`.trim());
      const searchResponse = await fetchWithTimeout(searchURL, {
        headers: { "user-agent": "OpenLyrics/1.2 (personal sync server)" },
      }, REQUEST_TIMEOUT_MS);
      if (searchResponse.ok) {
        const results = await searchResponse.json();
        const best = Array.isArray(results)
          ? results
            .filter(result => result && !result.instrumental && (result.syncedLyrics || result.plainLyrics))
            .map(result => [result, serverMatchScore(result, title, artist, durationSec)])
            .sort((left, right) => right[1] - left[1])[0]
          : null;
        if (best && best[1] >= 5) {
          const result = best[0];
          if (result.syncedLyrics) lines = parseLRC(result.syncedLyrics);
          if (!lines.length && result.plainLyrics) {
            const plain = String(result.plainLyrics).split("\n").map(text => text.trim()).filter(Boolean);
            const interval = plain.length > 1 && durationSec > 0
              ? durationSec / (plain.length - 1)
              : 3;
            lines = plain.map((text, index) => ({ t: index * interval, text }));
          }
        }
      }
    }
    if (!lines.length) {
      lines = [{ t: 0, text: "♪" }];
      await this.cacheLyrics(key, {
        kind: "fallback",
        lines,
        retryAt: Date.now() + 5 * 60 * 1_000,
      });
      return lines;
    }
    await this.cacheLyrics(key, lines);
    return lines;
  }

  /// Durable Object storage has no automatic TTL for these per-track keys.
  /// Keep a bounded index so a long listening history cannot grow storage
  /// without limit.
  async cacheLyrics(key, value) {
    let index = await this.state.storage.get("lyricsCacheIndex");
    index = Array.isArray(index) ? index.filter(item => item !== key) : [];
    index.push(key);
    while (index.length > 100) {
      const removed = index.shift();
      if (removed) await this.state.storage.delete(removed);
    }
    await this.state.storage.put(key, value);
    await this.state.storage.put("lyricsCacheIndex", index);
  }

  async pushJwt() {
    const cached = await this.state.storage.get("providerJwt");
    const createdAt = await this.state.storage.get("providerJwtAt");
    if (cached && typeof createdAt === "number" && Date.now() - createdAt < 50 * 60 * 1_000) {
      return cached;
    }
    const header = b64url(JSON.stringify({ alg: "ES256", kid: this.env.APNS_KEY_ID }));
    const claims = b64url(JSON.stringify({
      iss: this.env.APNS_TEAM_ID,
      iat: Math.floor(Date.now() / 1_000),
    }));
    const input = `${header}.${claims}`;
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToBuffer(this.env.APNS_KEY_P8),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"]
    );
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(input)
    );
    const jwt = `${input}.${b64url(new Uint8Array(signature))}`;
    await this.state.storage.put({ providerJwt: jwt, providerJwtAt: Date.now() });
    return jwt;
  }

  async apnsRequest(token, payload, priority = 10, kind = "update") {
    const jwt = await this.pushJwt();
    const host = this.apnsHost();
    let response;
    for (let attempt = 1; attempt <= 3; attempt++) {
      response = await fetchWithTimeout(`${host}/3/device/${token}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "liveactivity",
          "apns-priority": String(priority),
          authorization: `bearer ${jwt}`,
        },
        body: JSON.stringify(payload),
      }, APNS_TIMEOUT_MS);
      if (![429, 500, 502, 503, 504].includes(response.status) || attempt === 3) break;
      const retryAfter = finiteNumber(response.headers.get("Retry-After"), attempt * 1.5);
      await new Promise(resolve => setTimeout(resolve, Math.min(5_000, Math.max(250, retryAfter * 1_000))));
    }
    let responseText = "";
    if (!response.ok) responseText = (await response.text()).slice(0, 200);
    await this.state.storage.put("lastAPNsResult", {
      kind,
      status: response.status,
      at: new Date().toISOString(),
      detail: responseText || "accepted",
    });
    if (response.status === 410) {
      if (kind === "start") {
        await this.state.storage.put("pushToStartToken", "");
      } else {
        await this.state.storage.put("updateToken", "");
        // APNs 410 means this update token is no longer valid. It does not
        // prove that the user dismissed the Activity. Only a phone heartbeat
        // with activityState=dismissed may suppress the current session.
        if (kind === "update") {
          await this.state.storage.put({
            phoneActivityState: "none",
            forceServerUpdate: true,
          });
        }
      }
    } else if (!response.ok) {
      await this.state.storage.put({
        lastError: `APNs ${kind} ${response.status}: ${responseText}`,
        lastErrorAt: new Date().toISOString(),
      });
    }
    return response.status;
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

  async recordError(error) {
    await this.state.storage.put({
      lastError: String(error?.stack ?? error).slice(0, 500),
      lastErrorAt: new Date().toISOString(),
    });
  }
}

export function buildContentState(player, options = {}) {
  const nowMs = finiteNumber(options.nowMs, Date.now());
  const nowEpoch = nowMs / 1_000;
  const offsetSec = finiteNumber(options.offsetMs, 0) / 1_000;
  const schemaVersion = numericVersion(options.schemaVersion);
  const revision = finiteNumber(options.revision, 0);
  const durationSec = Math.max(0, finiteNumber(player.durationMs, 0) / 1_000);
  const positionSec = Math.max(0, finiteNumber(player.progressMs, 0) / 1_000);
  const lines = Array.isArray(player.lines) && player.lines.length
    ? player.lines
    : [{ t: 0, text: "♪" }];
  let index = -1;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (lines[lineIndex].t + offsetSec <= positionSec) index = lineIndex;
    else break;
  }
  const currentLine = index >= 0 ? lines[index].text : "♪";
  const nextLine = index + 1 < lines.length ? lines[index + 1].text : null;
  const progressStartEpoch = player.isPlaying ? nowEpoch - positionSec : null;
  const progressEndEpoch = player.isPlaying && durationSec > 0
    ? progressStartEpoch + durationSec
    : null;
  const frozenProgress = !player.isPlaying && durationSec > 0
    ? clamp(positionSec / durationSec, 0, 1)
    : null;

  let karaokeStartEpoch = null;
  let karaokeEndEpoch = null;
  let frozenKaraokeProgress = null;
  if (index >= 0) {
    const lineStart = lines[index].t + offsetSec;
    const lineEnd = Math.max(
      lineStart + 0.25,
      index + 1 < lines.length
        ? lines[index + 1].t + offsetSec
        : Math.max(lineStart + 0.25, durationSec || lineStart + 4)
    );
    if (player.isPlaying) {
      karaokeStartEpoch = nowEpoch + lineStart - positionSec;
      karaokeEndEpoch = nowEpoch + lineEnd - positionSec;
    } else {
      frozenKaraokeProgress = clamp((positionSec - lineStart) / (lineEnd - lineStart), 0, 1);
    }
  }
  const scheduledLinesV2 = player.isPlaying
    ? lines
      .map((line, sourceIndex) => ({ line, sourceIndex }))
      .filter(({ line }) => line.t + offsetSec - positionSec > 0.05)
      .filter(({ line }) => line.t + offsetSec - positionSec <= SCHEDULE_HORIZON_SEC)
      .slice(0, SCHEDULE_MAX_LINES)
      .map(({ line, sourceIndex }) => {
        const dateEpoch = nowEpoch + line.t + offsetSec - positionSec;
        const nextTime = sourceIndex + 1 < lines.length
          ? lines[sourceIndex + 1].t + offsetSec
          : Math.max(line.t + offsetSec + 0.25, durationSec || line.t + offsetSec + 4);
        return {
          dateEpoch,
          endDateEpoch: Math.max(dateEpoch + 0.25, nowEpoch + nextTime - positionSec),
          text: line.text,
        };
      })
    : [];
  const common = {
    trackTitle: String(player.title ?? "Unknown track"),
    artistName: String(player.artist ?? ""),
    albumImageURL: player.albumImageURL ?? null,
    albumDominantRGB: validRGB(player.albumDominantRGB) ? player.albumDominantRGB : null,
    currentLine: String(currentLine),
    nextLine: nextLine == null ? null : String(nextLine),
    isPlaying: player.isPlaying === true,
    frozenProgress,
    frozenKaraokeProgress,
  };
  if (schemaVersion < 2) {
    return compactContentState({
      ...common,
      progressStart: nullableSwiftDate(progressStartEpoch),
      progressEnd: nullableSwiftDate(progressEndEpoch),
      scheduledLines: scheduledLinesV2.map(line => ({
        date: swiftReferenceSeconds(line.dateEpoch),
        endDate: line.endDateEpoch == null ? null : swiftReferenceSeconds(line.endDateEpoch),
        text: line.text,
      })),
      karaokeStartDate: nullableSwiftDate(karaokeStartEpoch),
      karaokeEndDate: nullableSwiftDate(karaokeEndEpoch),
    });
  }
  return compactContentState({
    schemaVersion: 2,
    source: "server",
    revision,
    generatedAtEpoch: nowEpoch,
    trackID: String(player.trackID ?? ""),
    ...common,
    // Keep legacy Date anchors for one compatibility release. The schedule is
    // not duplicated because the second copy can exceed ActivityKit's limit.
    progressStart: nullableSwiftDate(progressStartEpoch),
    progressEnd: nullableSwiftDate(progressEndEpoch),
    scheduledLines: null,
    karaokeStartDate: nullableSwiftDate(karaokeStartEpoch),
    karaokeEndDate: nullableSwiftDate(karaokeEndEpoch),
    progressStartEpoch,
    progressEndEpoch,
    scheduledLinesV2,
    karaokeStartEpoch,
    karaokeEndEpoch,
  });
}

export function compactContentState(contentState, maxBytes = PAYLOAD_LIMIT_BYTES) {
  const copy = JSON.parse(JSON.stringify(contentState));
  while (contentStateSize(copy) > maxBytes) {
    if (Array.isArray(copy.scheduledLinesV2) && copy.scheduledLinesV2.length) {
      copy.scheduledLinesV2.pop();
      continue;
    }
    if (Array.isArray(copy.scheduledLines) && copy.scheduledLines.length) {
      copy.scheduledLines.pop();
      continue;
    }
    break;
  }
  if (contentStateSize(copy) > maxBytes) {
    copy.nextLine = truncate(copy.nextLine, 400);
    copy.currentLine = truncate(copy.currentLine, 800);
    copy.trackTitle = truncate(copy.trackTitle, 200);
    copy.artistName = truncate(copy.artistName, 200);
  }
  if (contentStateSize(copy) > maxBytes) copy.nextLine = null;
  return copy;
}

export function contentStateSize(contentState) {
  return new TextEncoder().encode(JSON.stringify(contentState)).length;
}

export function swiftReferenceSeconds(unixSeconds) {
  return unixSeconds - SWIFT_REFERENCE_EPOCH_OFFSET;
}

export function parseLRC(lrc) {
  const parsed = [];
  let offset = 0;
  for (const raw of String(lrc).split("\n")) {
    const line = raw.replace(/\r$/, "");
    const offsetMatch = line.match(/^\[offset:\s*([+-]?\d+)\]\s*$/i);
    if (offsetMatch) {
      // The last valid offset declaration is the effective one.
      offset = Number(offsetMatch[1]) / 1_000;
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
    if (text) for (const time of times) parsed.push({ t: time, text });
  }
  const result = parsed.map(({ t, text }) => ({ t: Math.max(0, t - offset), text }));
  result.sort((left, right) => left.t - right.t);
  return result;
}

function staleDateFor(contentState) {
  const now = Date.now() / 1_000;
  const schedule = contentState.scheduledLinesV2 ?? [];
  const horizon = schedule.at(-1)?.dateEpoch ?? now;
  return Math.floor(Math.max(now + 60, horizon + 15));
}

function nullableSwiftDate(epoch) {
  return typeof epoch === "number" ? swiftReferenceSeconds(epoch) : null;
}

function numericVersion(value) {
  return Math.floor(finiteNumber(value, 1)) >= 2 ? 2 : 1;
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function cleanString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function validRGB(value) {
  return value == null || (
    Array.isArray(value) && value.length === 3 &&
    value.every(component => typeof component === "number" && Number.isFinite(component) && component >= 0 && component <= 1)
  );
}

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) {
    return false;
  }
  let result = 0;
  for (let index = 0; index < left.length; index++) {
    result |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return result === 0;
}

function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function serverMatchScore(result, title, artist, durationSec) {
  let score = normalizedSimilarity(result.trackName, title) * 4;
  score += normalizedSimilarity(result.artistName, artist) * 3;
  if (durationSec > 0 && Number.isFinite(Number(result.duration))) {
    const difference = Math.abs(Number(result.duration) - durationSec);
    const tolerance = Math.max(5, durationSec * 0.08);
    if (difference <= tolerance) score += 3;
    else if (difference <= 30) score += 1;
    else score -= 2;
  }
  return score;
}

function normalizedSimilarity(left, right) {
  const lhs = normalizedText(left);
  const rhs = normalizedText(right);
  if (!lhs || !rhs) return 0;
  if (lhs === rhs) return 2;
  return lhs.includes(rhs) || rhs.includes(lhs) ? 1 : 0;
}

function normalizedText(value) {
  return String(value ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

async function fetchWithTimeout(input, init = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function truncate(value, length) {
  return value == null ? value : String(value).slice(0, length);
}

function pemToBuffer(pem) {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function b64url(input) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
