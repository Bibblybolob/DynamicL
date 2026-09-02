import { createRuntime, unseal, sealForWorker } from "./heroku-v2.js";
import {
  activityPayload,
  buildActivityContentState,
  contentStateBytes,
  mergeSpotifyPlayer,
  reliabilityConstants,
  sendAPNs,
} from "./reliability-v2.js";
import { lookupLyrics, lyricCacheTTL } from "./lyrics-v2.js";

const SPOTIFY_PLAYER_URL = "https://api.spotify.com/v1/me/player";
const SPOTIFY_CURRENTLY_PLAYING_URL = `${SPOTIFY_PLAYER_URL}/currently-playing`;
const SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token";
const NO_ITEM_CONFIRMATIONS = 2;
const START_RETRY_MS = 30_000;
const KEEPALIVE_MS = 45_000;

/**
 * Claims due installations with PostgreSQL row locks. The worker is the
 * background authority only after the phone lease expires.
 */
export async function pollOnce(runtime, limit = 20, options = {}) {
  const installations = await runtime.store.claimDue(limit);
  const results = [];
  for (const installation of installations) {
    try {
      results.push(await pollInstallation(installation, runtime, options));
    } catch (error) {
      const current = await runtime.store.getInstallation(installation.id);
      if (current) {
        await runtime.store.updateInstallation(installation.id, {
          state: {
            ...(current.state ?? {}),
            lastError: safeError(error),
            lastErrorAt: new Date().toISOString(),
          },
          lockUntil: null,
          nextPollAt: new Date(Date.now() + spotifyBackoffMs(error)).toISOString(),
        });
      }
      results.push({ id: installation.id, error: safeError(error) });
    }
  }
  return results;
}

/** Poll one installation and publish a complete canonical Activity state. */
export async function pollInstallation(installation, runtime, options = {}) {
  const nowMs = finiteNumber(options.nowMs, Date.now());
  const fetchImpl = options.fetchImpl ?? fetch;
  const current = await runtime.store.getInstallation(installation.id) ?? installation;
  let state = { ...(current.state ?? {}) };

  if (finiteNumber(state.phoneLeaseExpiresAt, 0) > nowMs) {
    const recovery = await recoverPendingLyricsDuringPhoneLease(
      current,
      runtime,
      state,
      nowMs,
      options,
    );
    if (recovery) return recovery;
    await releaseClaim(current, runtime, nowMs, state.phoneActivityState === "active");
    return { skipped: "phone-lease", id: current.id };
  }

  const clientID = clean(state.spotifyClientID) ?? clean(runtime.env.SPOTIFY_CLIENT_ID);
  if (!clientID) throw new Error("Spotify client ID is not configured");
  const refreshToken = unseal(current.refreshTokenCiphertext, runtime.encryptionKey);
  const tokenResult = await refreshAccessToken(refreshToken, clientID, fetchImpl);
  if (tokenResult.refreshToken && tokenResult.refreshToken !== refreshToken) {
    await runtime.store.updateInstallation(current.id, {
      refreshTokenCiphertext: sealForWorker(tokenResult.refreshToken, runtime.encryptionKey),
    });
  }

  let response;
  try {
    response = await fetchPlayer(tokenResult.accessToken, fetchImpl);
  } catch (error) {
    // Spotify access tokens can expire between refresh and the player request.
    // Refresh once and retry the player request. Do not loop: repeated 401s
    // must reach the poll backoff path instead of creating a request storm.
    if (error?.status !== 401) throw error;
    const replacement = await refreshAccessToken(refreshToken, clientID, fetchImpl);
    if (replacement.refreshToken && replacement.refreshToken !== refreshToken) {
      await runtime.store.updateInstallation(current.id, {
        refreshTokenCiphertext: sealForWorker(replacement.refreshToken, runtime.encryptionKey),
      });
    }
    response = await fetchPlayer(replacement.accessToken, fetchImpl);
  }
  const merged = mergeSpotifyPlayer(state.activeTrack, response.player, nowMs);
  if (merged.kind === "stale") {
    await releaseClaim(current, runtime, nowMs, state.isPlaying === true);
    return { id: current.id, ignored: "stale-player-response" };
  }

  if (merged.confirmedStop || !merged.player) {
    return handleNoItem(current, runtime, state, nowMs, merged.confirmedStop, options);
  }

  const player = merged.player;
  state = advancePlaybackSession(state, player, nowMs);
  if (currentOwner(state, nowMs) === "phone") {
    await runtime.store.updateInstallation(current.id, {
      state,
      lockUntil: null,
      nextPollAt: new Date(nowMs + (player.isPlaying ? reliabilityConstants.fastPollMs : reliabilityConstants.idlePollMs)).toISOString(),
    });
    return { id: current.id, skipped: "phone-lease" };
  }

  // Start with a valid compact state before the lyric network lookup. This is
  // the difference between a remote activity appearing quickly and waiting
  // for a slow provider/search round trip.
  const updateTokenRecord = await activityToken(current, runtime, "update");
  if (player.isPlaying && !updateTokenRecord) {
    const bootstrap = buildActivityContentState(
      withArtworkColor(player, state),
      [{ t: 0, text: "♪" }],
      activityOptions(state, nowMs),
    );
    state = await storeCanonical(current, runtime, state, player, bootstrap, nowMs, {
      lyricStatus: "pending",
    });
    await deliverStartIfNeeded(current, runtime, state, bootstrap, nowMs, options);
    state = (await runtime.store.getInstallation(current.id))?.state ?? state;
  }

  const lyricResult = await resolveLyricsForPlayer(player, current, runtime, fetchImpl, nowMs);
  // Lyric lookup can update the negative cache and can overlap a phone
  // heartbeat. Reload the state before constructing the canonical payload so
  // that asynchronous lookup never restores an older state snapshot.
  const persistedAfterLyrics = await runtime.store.getInstallation(current.id);
  if (persistedAfterLyrics?.state) {
    state = { ...state, ...persistedAfterLyrics.state };
  }
  const lines = lyricResult.document?.lines ?? [{ t: 0, text: "♪" }];
  const contentState = buildActivityContentState(
    withArtworkColor(player, state),
    lines,
    activityOptions(state, nowMs),
  );
  state = await storeCanonical(current, runtime, state, player, contentState, nowMs, {
    lyricStatus: lyricResult.document ? "ready" : "missing",
    lyricSource: lyricResult.document?.source ?? null,
    lyricContentHash: lyricResult.document?.contentHash ?? null,
  });

  // Reload tokens because a remote start can wake the app and the app can
  // register its update token while lyrics are being resolved.
  const latest = await runtime.store.getInstallation(current.id) ?? current;
  state = latest.state ?? state;
  if (currentOwner(state, nowMs) !== "server") {
    await releaseClaim(latest, runtime, nowMs, player.isPlaying);
    return { id: current.id, skipped: "phone-took-ownership" };
  }
  await deliverState(latest, runtime, state, contentState, merged.kind, nowMs, options);
  await releaseClaim(latest, runtime, nowMs, player.isPlaying);
  return {
    id: current.id,
    owner: "server",
    trackID: player.trackID,
    kind: merged.kind,
    playing: player.isPlaying === true,
    payloadSize: contentStateBytes(contentState),
  };
}

/**
 * A remote start intentionally sends a compact placeholder before lyric lookup
 * finishes. The app then wakes, registers the Activity update token, and takes
 * the normal playback lease. That lease must not strand the placeholder. This
 * narrow exception only completes lyrics for the already accepted track; it
 * does not poll Spotify or make the server a competing playback writer.
 */
async function recoverPendingLyricsDuringPhoneLease(
  installation,
  runtime,
  state,
  nowMs,
  options = {},
) {
  const preparedState = state.activeContentState;
  const realPlayer = state.activeTrack;
  const player = realPlayer?.trackID ? realPlayer : preparedState?.trackID ? {
    trackID: preparedState.trackID,
    title: preparedState.trackTitle ?? "",
    artist: preparedState.artistName ?? "",
    albumImageURL: preparedState.albumImageURL ?? null,
    isPlaying: preparedState.isPlaying === true,
  } : null;
  if (!player?.trackID) return null;
  if (state.phoneTrackID && state.phoneTrackID !== player.trackID) return null;
  const hasUnsentPreparedLyrics =
    ["ready", "missing"].includes(state.lyricStatus) &&
    preparedState?.trackID === player.trackID &&
    preparedLyricsNeedDelivery(state, preparedState);
  if (state.lyricStatus !== "pending" && !hasUnsentPreparedLyrics) return null;
  // A pending placeholder still needs server-side lyric lookup metadata. A
  // completed phone payload can be relayed without an earlier server poll.
  if (state.lyricStatus === "pending" && !realPlayer?.trackID) return null;

  // Do not resolve lyrics until Apple has supplied an update token for the
  // remotely started Activity. Otherwise a successful lookup could be marked
  // complete without any way to replace the visible placeholder.
  if (!await activityToken(installation, runtime, "update")) return null;

  let latest = installation;
  let latestState = state;
  let latestPlayer = player;
  let contentState = preparedState;
  let canonical = state;

  if (state.lyricStatus === "pending") {
    const fetchImpl = options.fetchImpl ?? fetch;
    const lyricResult = await resolveLyricsForPlayer(
      realPlayer,
      installation,
      runtime,
      fetchImpl,
      nowMs,
    );
    latest = await runtime.store.getInstallation(installation.id) ?? installation;
    latestState = { ...(latest.state ?? {}) };
    latestPlayer = latestState.activeTrack;

    // A phone heartbeat can report a skip while lookup is running. Never put
    // lyrics from the old track into the new Activity.
    if (latestState.lyricStatus !== "pending" ||
        latestPlayer?.trackID !== realPlayer.trackID ||
        (latestState.phoneTrackID && latestState.phoneTrackID !== realPlayer.trackID) ||
        !await activityToken(latest, runtime, "update")) {
      await releaseClaim(latest, runtime, nowMs, latestState.phoneActivityState === "active");
      return { id: installation.id, skipped: "stale-lyric-recovery" };
    }

    const lines = lyricResult.document?.lines ?? [{ t: 0, text: "♪" }];
    contentState = buildActivityContentState(
      withArtworkColor(latestPlayer, latestState),
      lines,
      activityOptions(latestState, nowMs),
    );
    canonical = await storeCanonical(
      latest,
      runtime,
      latestState,
      latestPlayer,
      contentState,
      nowMs,
      {
        lyricStatus: lyricResult.document ? "ready" : "missing",
        lyricSource: lyricResult.document?.source ?? null,
        lyricContentHash: lyricResult.document?.contentHash ?? null,
        lastLyricRecoveryAt: new Date(nowMs).toISOString(),
      },
    );
  }

  if (!contentState) return null;
  const delivery = await deliverState(
    latest,
    runtime,
    canonical,
    contentState,
    "lyric recovery",
    nowMs,
    options,
  );

  // Keep the recovery eligible for the next worker pass if APNs did not
  // accept it. A transient APNs error must not make "Finding lyrics..." final.
  if (!delivery?.accepted) {
    await runtime.store.updateInstallation(installation.id, {
      state: { lyricStatus: "pending" },
    });
  }
  await releaseClaim(latest, runtime, nowMs, latestPlayer.isPlaying === true);
  return {
    id: installation.id,
    owner: "phone",
    completed: delivery?.accepted ? "pending-lyrics" : null,
    retry: delivery?.accepted ? null : "pending-lyrics",
    trackID: latestPlayer.trackID,
    payloadSize: contentStateBytes(contentState),
  };
}

function preparedLyricsNeedDelivery(state, contentState) {
  if (state.lastSentTrackID !== contentState.trackID) return true;
  if (state.lastSentCurrentLine !== contentState.currentLine) return true;
  if (state.lastSentNextLine !== (contentState.nextLine ?? null)) return true;
  const sent = Array.isArray(state.lastSentScheduleV2) ? state.lastSentScheduleV2 : [];
  const prepared = Array.isArray(contentState.scheduledLinesV2) ? contentState.scheduledLinesV2 : [];
  const sentHorizon = sent.at(-1)?.endDateEpoch ?? sent.at(-1)?.dateEpoch ?? 0;
  const preparedHorizon = prepared.at(-1)?.endDateEpoch ?? prepared.at(-1)?.dateEpoch ?? 0;
  return prepared.length > 0 && preparedHorizon > sentHorizon + 1;
}

function advancePlaybackSession(state, player, nowMs) {
  const previousTrackID = state.spotifyTrackID;
  const previousPlaying = state.isPlaying === true;
  const previousPausedAt = finiteNumber(state.pausedAt, 0);
  const trackChanged = Boolean(previousTrackID) && previousTrackID !== player.trackID;
  const resumedAfterLongPause = player.isPlaying && previousPausedAt > 0 &&
    nowMs - previousPausedAt >= reliabilityConstants.pauseEndMs;
  if (player.isPlaying && (!state.playbackSessionID || !previousPlaying || resumedAfterLongPause || trackChanged)) {
    state.playbackSessionID = `${Math.floor(nowMs)}-${player.trackID}`;
    state.playbackSessionStartAttempted = false;
    state.playbackSessionDismissed = false;
    state.dismissalSource = null;
    state.lastStartAttemptAt = 0;
    state.lastStartAttemptCount = 0;
    state.lastSentTrackID = "";
    state.lastSentScheduleV2 = [];
    state.lastSchedulePushAt = 0;
    state.playbackSessionClosed = false;
  }
  if (player.isPlaying) {
    state.pausedAt = 0;
    state.lastPlayingAt = nowMs;
  } else if (!previousPausedAt) {
    state.pausedAt = nowMs;
  }
  state.activeTrack = player;
  state.spotifyTrackID = player.trackID;
  state.trackTitle = player.title;
  state.artistName = player.artist;
  state.albumImageURL = player.albumImageURL ?? (trackChanged ? null : state.albumImageURL ?? null);
  state.durationMs = player.durationMs;
  state.progressMs = player.progressMs;
  state.isPlaying = player.isPlaying === true;
  state.lastPollAt = new Date(nowMs).toISOString();
  state.reachable = true;
  state.noItemSamples = 0;
  return state;
}

async function handleNoItem(installation, runtime, state, nowMs, explicit, options = {}) {
  const samples = finiteNumber(state.noItemSamples, 0) + 1;
  state.noItemSamples = samples;
  state.lastPollAt = new Date(nowMs).toISOString();
  state.reachable = true;
  state.isPlaying = false;
  if (samples < NO_ITEM_CONFIRMATIONS) {
    await runtime.store.updateInstallation(installation.id, {
      state,
      lockUntil: null,
      nextPollAt: new Date(nowMs + reliabilityConstants.idlePollMs).toISOString(),
    });
    return { id: installation.id, retained: "awaiting-stop-confirmation", explicit };
  }

  const latest = await runtime.store.getInstallation(installation.id) ?? installation;
  if (currentOwner(state, nowMs) === "server") {
    const ended = await deliverEnd(
      latest,
      runtime,
      state,
      "no active item",
      nowMs,
      runtime.env,
      options.fetchImpl ?? fetch,
    );
    if (!ended) {
      await runtime.store.updateInstallation(installation.id, {
        state,
        lockUntil: null,
        nextPollAt: new Date(nowMs + reliabilityConstants.idlePollMs).toISOString(),
      });
      return { id: installation.id, retained: "end-retry" };
    }
  }
  state.activeTrack = null;
  state.activeContentState = null;
  state.spotifyTrackID = null;
  state.trackTitle = null;
  state.artistName = null;
  state.albumImageURL = null;
  state.lastArtworkStatus = { trackID: null, hasURL: false, confirmedStop: true };
  state.playbackSessionID = null;
  state.playbackSessionStartAttempted = false;
  state.playbackSessionDismissed = false;
  state.playbackSessionClosed = true;
  state.lastSentTrackID = "";
  state.lastSentScheduleV2 = [];
  state.lastSchedulePushAt = 0;
  await runtime.store.updateInstallation(installation.id, {
    state,
    lockUntil: null,
    nextPollAt: new Date(nowMs + reliabilityConstants.idlePollMs).toISOString(),
  });
  return { id: installation.id, stopped: true };
}

async function resolveLyricsForPlayer(player, installation, runtime, fetchImpl, nowMs) {
  const documents = await runtime.store.documentsForTrack(player.trackID);
  const correction = await runtime.store.getCorrection(installation.id, player.trackID);
  const corrected = correction && documents.find(item => item.contentHash === correction);
  const cached = corrected ?? documents[0];
  if (cached?.document?.lines?.length) return { document: cached.document, cached: true };

  const state = installation.state ?? {};
  const negative = state.lyricNegativeCache?.[player.trackID];
  if (negative && finiteNumber(negative.retryAt, 0) > nowMs) {
    return { document: null, cached: true, negative: true };
  }
  const result = await lookupLyrics({
    trackID: player.trackID,
    title: player.title,
    artist: player.artist,
    durationSec: finiteNumber(player.durationMs, 0) / 1_000,
  }, { env: runtime.env, fetchImpl });
  if (result.best) {
    const expiresAt = new Date(nowMs + lyricCacheTTL.successMs).toISOString();
    await runtime.store.saveDocument({
      contentHash: result.best.contentHash,
      trackID: player.trackID,
      source: result.best.source,
      document: result.best,
      expiresAt,
    });
    return { document: result.best, cached: false };
  }
  const negatives = { ...(state.lyricNegativeCache ?? {}) };
  negatives[player.trackID] = { retryAt: nowMs + lyricCacheTTL.negativeMs };
  const keys = Object.keys(negatives);
  while (keys.length > 100) delete negatives[keys.shift()];
  await runtime.store.updateInstallation(installation.id, {
    state: { lyricNegativeCache: negatives },
  });
  return { document: null, cached: false, negative: true };
}

function withArtworkColor(player, state) {
  const color = state.albumDominantTrackID === player.trackID
    ? state.albumDominantRGB
    : null;
  return { ...player, albumDominantRGB: validRGB(color) ? color : null };
}

function activityOptions(state, nowMs) {
  return {
    nowMs,
    offsetMs: finiteNumber(state.lyricOffsetMs, 0),
    schemaVersion: 2,
    revision: finiteNumber(state.serverRevision, 0) + 1,
    requiresUserStart: false,
  };
}

async function storeCanonical(installation, runtime, state, player, contentState, nowMs, extra = {}) {
  const schedule = contentState.scheduledLinesV2 ?? [];
  const revision = finiteNumber(state.serverRevision, 0) + 1;
  const next = {
    ...state,
    ...extra,
    serverRevision: revision,
    activeTrack: player,
    activeContentState: contentState,
    spotifyTrackID: player.trackID,
    trackTitle: player.title,
    artistName: player.artist,
    albumImageURL: player.albumImageURL ?? null,
    isPlaying: player.isPlaying === true,
    progressMs: player.progressMs,
    lastPayloadSize: contentStateBytes(contentState),
    lastScheduleCount: schedule.length,
    lastScheduleHorizonEpoch: schedule.at(-1)?.endDateEpoch ?? schedule.at(-1)?.dateEpoch ?? null,
    lastArtworkStatus: {
      trackID: player.trackID,
      hasURL: Boolean(player.albumImageURL),
      preservedFromSameTrack: player.albumImageURL == null && state.spotifyTrackID === player.trackID,
    },
    lastPollAt: new Date(nowMs).toISOString(),
    reachable: true,
  };
  await runtime.store.updateInstallation(installation.id, { state: next });
  return next;
}

async function deliverStartIfNeeded(installation, runtime, state, contentState, nowMs, options) {
  if (!state.playbackSessionID || state.playbackSessionDismissed === true ||
      state.autoStartEnabled === false || state.supportsRemoteStart === false ||
      state.playbackSessionStartAttempted === true) return;
  const lastAttemptAt = finiteNumber(state.lastStartAttemptAt, 0);
  if (nowMs - lastAttemptAt < START_RETRY_MS) return;
  const tokenRecord = await activityToken(installation, runtime, "pushToStart");
  if (!tokenRecord) return;
  const token = unseal(tokenRecord.ciphertext, runtime.encryptionKey);
  const payload = activityPayload("start", contentState, {
    nowEpoch: nowMs / 1_000,
    inputPushToken: state.supportsInputPushToken === true,
  });
  const result = await sendAPNs({
    token,
    tokenRecord,
    payload,
    priority: 10,
    kind: "start",
    env: runtime.env,
    fetchImpl: options.fetchImpl ?? fetch,
    nowEpoch: nowMs / 1_000,
  });
  const next = {
    ...state,
    lastStartAttemptAt: nowMs,
    lastStartAttemptCount: finiteNumber(state.lastStartAttemptCount, 0) + 1,
    lastAPNsResult: result,
    lastPayloadSize: contentStateBytes(contentState),
    lastPushReason: "automatic start",
  };
  if (result.accepted) {
    next.playbackSessionStartAttempted = true;
    next.phoneActivityState = "active";
  }
  if (result.terminal) await runtime.store.deleteActivityToken(installation.id, "pushToStart");
  if (!result.accepted && result.reason) {
    next.lastError = `APNs start: ${result.reason}`;
    next.lastErrorAt = new Date(nowMs).toISOString();
  }
  await runtime.store.updateInstallation(installation.id, { state: next });
}

async function deliverState(installation, runtime, state, contentState, kind, nowMs, options) {
  const tokenRecord = await activityToken(installation, runtime, "update");
  if (!tokenRecord) {
    if (contentState.isPlaying) await deliverStartIfNeeded(installation, runtime, state, contentState, nowMs, options);
    return null;
  }
  const previousSchedule = Array.isArray(state.lastSentScheduleV2) ? state.lastSentScheduleV2 : [];
  const currentSchedule = contentState.scheduledLinesV2 ?? [];
  const nowEpoch = nowMs / 1_000;
  const remaining = previousSchedule.filter(line => finiteNumber(line.dateEpoch, 0) > nowEpoch);
  const currentHorizon = currentSchedule.at(-1)?.endDateEpoch ?? currentSchedule.at(-1)?.dateEpoch ?? 0;
  const previousHorizon = remaining.at(-1)?.endDateEpoch ?? remaining.at(-1)?.dateEpoch ?? 0;
  const scheduleRefill = contentState.isPlaying && (
    remaining.length < 6 || previousHorizon - nowEpoch < 40
  ) && currentHorizon > previousHorizon + 1;
  const trackChanged = state.lastSentTrackID !== contentState.trackID;
  const playChanged = state.lastSentPlaying !== contentState.isPlaying;
  const eventChanged = finiteNumber(state.activeTrack?.playbackChangeAtMs, 0) >
    finiteNumber(state.lastSentPlaybackChangeAtMs, 0);
  const seeked = typeof state.lastSentProgressStartEpoch === "number" &&
    typeof contentState.progressStartEpoch === "number" &&
    Math.abs(state.lastSentProgressStartEpoch - contentState.progressStartEpoch) > 0.75;
  const offsetChanged = state.lastSentOffsetMs !== state.lyricOffsetMs;
  const artworkChanged = state.lastSentAlbumImageURL !== contentState.albumImageURL;
  const lineChanged = state.lastSentCurrentLine !== contentState.currentLine ||
    state.lastSentNextLine !== (contentState.nextLine ?? null);
  const previousScheduleRunway = previousHorizon - nowEpoch;
  const scheduleCanAdvance = contentState.isPlaying && remaining.length > 0 &&
    previousScheduleRunway >= 8;
  const lineFallback = lineChanged && !scheduleCanAdvance;
  // A phone heartbeat marks itself as the last writer. Once its lease ends,
  // send one immediate full state before routine low-priority schedule
  // refills begin. This makes app-to-server handoff explicit without sending
  // every lyric line twice.
  const takeover = state.lastUpdateOwner === "phone";
  const staleKeepalive = nowMs - finiteNumber(state.lastPushAt, 0) >= KEEPALIVE_MS;
  const reason = trackChanged ? "track"
    : playChanged ? "play state"
      : eventChanged ? "playback event"
        : seeked ? "seek"
          : offsetChanged ? "offset"
            : artworkChanged ? "artwork"
              : takeover ? "phone takeover"
                : scheduleRefill ? "schedule"
                  : lineFallback ? "line fallback"
                    : staleKeepalive ? "keepalive" : null;
  if (!reason) return null;

  const token = unseal(tokenRecord.ciphertext, runtime.encryptionKey);
  // Keep routine schedule refills and keepalives at priority 5. Timestamped
  // lyric boundaries render without an APNs request. Priority 10 is reserved
  // for user-visible playback changes, takeover, and schedule failure.
  const urgent = [
    "track", "play state", "playback event", "seek", "offset", "artwork",
    "phone takeover", "line fallback",
  ].includes(reason);
  const payload = activityPayload("update", contentState, { nowEpoch });
  const result = await sendAPNs({
    token,
    tokenRecord,
    payload,
    priority: urgent ? 10 : 5,
    kind: "update",
    env: runtime.env,
    fetchImpl: options.fetchImpl ?? fetch,
    nowEpoch,
  });
  const deliveryPatch = {
    lastAPNsResult: result,
    lastPayloadSize: contentStateBytes(contentState),
    lastPushReason: reason,
  };
  if (result.accepted) {
    const latestAfterDelivery = await runtime.store.getInstallation(installation.id);
    const phoneReclaimedOwnership = finiteNumber(
      latestAfterDelivery?.state?.phoneLeaseExpiresAt,
      0,
    ) > nowMs;
    Object.assign(deliveryPatch, {
      lastPushAt: nowMs,
      lastSentTrackID: contentState.trackID ?? "",
      lastSentPlaying: contentState.isPlaying,
      lastSentPlaybackChangeAtMs: finiteNumber(state.activeTrack?.playbackChangeAtMs, 0),
      lastSentProgressStartEpoch: contentState.progressStartEpoch ?? null,
      lastSentOffsetMs: state.lyricOffsetMs,
      lastSentAlbumImageURL: contentState.albumImageURL ?? null,
      lastSentCurrentLine: contentState.currentLine ?? "",
      lastSentNextLine: contentState.nextLine ?? null,
      lastSentScheduleV2: currentSchedule,
      lastSchedulePushAt: scheduleRefill ? nowMs : state.lastSchedulePushAt ?? 0,
      // Do not erase a heartbeat that arrived while Apple processed this
      // request. The current payload was accepted, but the phone remains the
      // next writer until its newly acquired lease ends.
      lastUpdateOwner: phoneReclaimedOwnership ? "phone" : "server",
    });
  } else if (result.reason) {
    deliveryPatch.lastError = `APNs update: ${result.reason}`;
    deliveryPatch.lastErrorAt = new Date(nowMs).toISOString();
  }
  // Write only delivery fields. A phone heartbeat can arrive while APNs is
  // processing this request; restoring the worker's old full-state snapshot
  // would erase that new lease and make both writers compete again.
  await runtime.store.updateInstallation(installation.id, { state: deliveryPatch });
  if (result.terminal) {
    await runtime.store.deleteActivityToken(installation.id, "update");
    if (result.status === 410 && contentState.isPlaying) {
      await runtime.store.updateInstallation(installation.id, {
        state: {
          playbackSessionStartAttempted: false,
          lastStartAttemptAt: 0,
          phoneActivityState: "none",
        },
      });
    }
  }
  return result;
}

async function deliverEnd(installation, runtime, state, reason, nowMs, env, fetchImpl = fetch) {
  const tokenRecord = await activityToken(installation, runtime, "update");
  if (!tokenRecord) return true;
  const token = unseal(tokenRecord.ciphertext, runtime.encryptionKey);
  const stored = state.activeContentState ?? {
    trackTitle: state.trackTitle ?? "",
    artistName: state.artistName ?? "",
    albumImageURL: state.albumImageURL ?? null,
    currentLine: "",
    nextLine: null,
    isPlaying: false,
  };
  const endState = compactEndedState(stored);
  const payload = activityPayload("end", endState, { nowEpoch: nowMs / 1_000 });
  const result = await sendAPNs({
    token,
    tokenRecord,
    payload,
    priority: 10,
    kind: "end",
    env,
    fetchImpl,
    nowEpoch: nowMs / 1_000,
  });
  await runtime.store.updateInstallation(installation.id, {
    state: {
      lastAPNsResult: result,
      lastEndReason: reason,
      lastPayloadSize: contentStateBytes(endState),
    },
  });
  if (result.accepted || result.status === 410 || result.terminal) {
    await runtime.store.deleteActivityToken(installation.id, "update");
    return true;
  }
  return false;
}

function compactEndedState(state) {
  return {
    ...state,
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
  };
}

async function releaseClaim(installation, runtime, nowMs, playing) {
  await runtime.store.updateInstallation(installation.id, {
    lockUntil: null,
    nextPollAt: new Date(nowMs + (playing ? reliabilityConstants.fastPollMs : reliabilityConstants.idlePollMs)).toISOString(),
  });
}

async function activityToken(installation, runtime, kind) {
  const tokens = await runtime.store.getActivityTokens(installation.id);
  return tokens[kind] ?? null;
}

function currentOwner(state, nowMs) {
  return finiteNumber(state.phoneLeaseExpiresAt, 0) > nowMs ? "phone" : "server";
}

export async function refreshAccessToken(refreshToken, clientID, fetchImpl = fetch) {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: clientID,
  });
  const response = await fetchImpl(SPOTIFY_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(reliabilityConstants.requestTimeoutMs),
  });
  if (!response.ok) {
    const retryAfter = response.headers?.get("Retry-After");
    throw spotifyHTTPError("Spotify token", response.status, retryAfter);
  }
  const payload = await response.json();
  if (typeof payload.access_token !== "string") throw new Error("Spotify token response is invalid");
  return {
    accessToken: payload.access_token,
    refreshToken: typeof payload.refresh_token === "string" ? payload.refresh_token : null,
  };
}

export async function fetchPlayer(accessToken, fetchImpl = fetch) {
  let response = await fetchImpl(SPOTIFY_CURRENTLY_PLAYING_URL, {
    headers: { authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(reliabilityConstants.requestTimeoutMs),
  });
  // Spotify can briefly disagree across its playback endpoints during device
  // handoff. Confirm an empty currently-playing response with the full player
  // state before the worker clears a valid session.
  if (response.status === 204) {
    response = await fetchImpl(SPOTIFY_PLAYER_URL, {
      headers: { authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(reliabilityConstants.requestTimeoutMs),
    });
  }
  if (response.status === 204) return { player: null };
  if (response.status === 401) throw spotifyHTTPError("Spotify player", 401);
  if (response.status === 429) {
    const retryAfter = response.headers?.get("Retry-After");
    throw spotifyHTTPError("Spotify player", 429, retryAfter);
  }
  if (!response.ok) throw spotifyHTTPError("Spotify player", response.status);
  return { player: await response.json() };
}

function spotifyHTTPError(service, status, retryAfter = null) {
  const suffix = retryAfter ? ` retry-after=${retryAfter}` : "";
  const error = new Error(`${service} HTTP ${status}${suffix}`);
  error.status = status;
  error.retryAfterMs = parseRetryAfterMs(retryAfter);
  return error;
}

function spotifyBackoffMs(error) {
  const requested = finiteNumber(error?.retryAfterMs, 0);
  // Keep a provider outage bounded. A later worker claim retries the
  // installation, while a Retry-After value still prevents hot polling.
  return Math.max(
    reliabilityConstants.idlePollMs,
    Math.min(5 * 60 * 1_000, requested || reliabilityConstants.idlePollMs),
  );
}

function parseRetryAfterMs(value) {
  if (value == null || value === "") return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1_000);
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - Date.now()) : null;
}

function finiteNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function clean(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function validRGB(value) {
  return Array.isArray(value) && value.length === 3 &&
    value.every(item => typeof item === "number" && Number.isFinite(item) && item >= 0 && item <= 1);
}

function safeError(error) {
  return String(error?.message ?? error).replace(/(Bearer\s+)[^\s]+/gi, "$1[redacted]").slice(0, 500);
}

/**
 * Run the due-installation poller inside either a dedicated worker dyno or
 * the existing web dyno. PostgreSQL row locks make this safe if a dedicated
 * worker is enabled later.
 */
export function startPollingLoop(runtime, options = {}) {
  const intervalMs = Math.max(250, finiteNumber(
    options.intervalMs,
    reliabilityConstants.fastPollMs,
  ));
  const reportError = options.onError ?? (error => console.error(safeError(error)));
  let stopped = false;
  let timer = null;

  const run = async () => {
    if (stopped) return;
    try {
      await pollOnce(runtime);
    } catch (error) {
      reportError(error);
    } finally {
      if (!stopped) timer = setTimeout(run, intervalMs);
    }
  };

  void run();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}

if (process.argv[1] && process.argv[1].endsWith("heroku-worker-v2.js")) {
  createRuntime().then(runtime => {
    startPollingLoop(runtime);
  }).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
