import { PlaybackSessionV2 } from "./session.js";

export { PlaybackSessionV2 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Keep the unversioned routes for existing beta builds while accepting
    // the versioned contract used by new iOS clients.
    const routePath = url.pathname.replace(/^\/v1(?=\/|$)/, "") || "/";

    if (routePath === "/health") {
      return json({ ok: true, service: "dynamicallyrics-sync" });
    }

    const protectedRoute = ["/register", "/heartbeat", "/command", "/status", "/reset", "/wake"]
      .includes(routePath);
    if (protectedRoute) {
      const authError = await authorize(request, env, routePath);
      if (authError) return authError;
    }

    if (request.method === "POST" && routePath === "/register") {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid JSON" }, 400);
      }
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return json({ error: "invalid registration payload" }, 400);
      }
      const { updateToken, pushToStartToken, spotifyRefreshToken } = body;
      const hasActivityToken = isHexToken(updateToken, true) && Boolean(updateToken) ||
        isHexToken(pushToStartToken, true) && Boolean(pushToStartToken);
      if (!isHexToken(updateToken, true) || !isHexToken(pushToStartToken, true) ||
          !hasActivityToken || typeof spotifyRefreshToken !== "string" ||
          spotifyRefreshToken.length < 10 || !validOptionalNumber(body.lyricOffsetMs) ||
          !validSchemaVersion(body.clientSchemaVersion)) {
        return json({ error: "an Activity token and spotifyRefreshToken are required" }, 400);
      }
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const resp = await stub.fetch("https://session/register", {
        method: "POST",
        body: JSON.stringify({
          updateToken,
          pushToStartToken,
          spotifyRefreshToken,
          clientSchemaVersion: body.clientSchemaVersion,
          supportsRemoteStart: body.supportsRemoteStart !== false,
          supportsInputPushToken: body.supportsInputPushToken === true,
          lyricOffsetMs: body.lyricOffsetMs ?? 0,
          albumDominantRGB: validRGB(body.albumDominantRGB) ? body.albumDominantRGB : null,
          autoStartEnabled: body.autoStartEnabled !== false,
          ...(Object.prototype.hasOwnProperty.call(body, "requiresUserStart")
            ? { requiresUserStart: body.requiresUserStart === true }
            : {}),
          bootstrap: !request.headers.get("authorization"),
        }),
      });
      return json(await resp.json(), resp.status);
    }

    if (request.method === "POST" && routePath === "/heartbeat") {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid JSON" }, 400);
      }
      const validState = ["active", "none", "dismissed"].includes(body?.activityState);
      if (!body || typeof body !== "object" || Array.isArray(body) || !validState ||
          !isHexToken(body.updateToken, true) || !validOptionalNumber(body.sentAtMs) ||
          !validOptionalNumber(body.localRevision) || !validOptionalNumber(body.lyricOffsetMs) ||
          !validSchemaVersion(body.clientSchemaVersion) ||
          (body.activityEnded != null && typeof body.activityEnded !== "boolean") ||
          (body.trackID != null && (typeof body.trackID !== "string" || body.trackID.length > 256))) {
        return json({ error: "invalid heartbeat payload" }, 400);
      }
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const heartbeatBody = {
        activityState: body.activityState,
        updateToken: body.updateToken,
        sentAtMs: body.sentAtMs,
        localRevision: body.localRevision,
        trackID: body.trackID,
        lyricOffsetMs: body.lyricOffsetMs ?? 0,
        clientSchemaVersion: body.clientSchemaVersion,
        autoStartEnabled: body.autoStartEnabled !== false,
        ...(body.activityEnded === true ? { activityEnded: true } : {}),
      };
      if (Object.prototype.hasOwnProperty.call(body, "requiresUserStart")) {
        heartbeatBody.requiresUserStart = body.requiresUserStart === true;
      }
      if (Object.prototype.hasOwnProperty.call(body, "albumDominantRGB") &&
          validRGB(body.albumDominantRGB)) {
        heartbeatBody.albumDominantRGB = body.albumDominantRGB;
      }
      const resp = await stub.fetch("https://session/heartbeat", {
        method: "POST",
        body: JSON.stringify(heartbeatBody),
      });
      return json(await resp.json(), resp.status);
    }

    if (request.method === "POST" && routePath === "/command") {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid JSON" }, 400);
      }
      const command = body?.command;
      if (!body || typeof body !== "object" || Array.isArray(body) ||
          !["toggle", "next", "previous"].includes(command) ||
          typeof body.commandID !== "string" ||
          !/^[A-Za-z0-9-]{8,80}$/.test(body.commandID) ||
          !validOptionalNumber(body.issuedAtMs)) {
        return json({ error: "invalid command payload" }, 400);
      }
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const resp = await stub.fetch("https://session/command", {
        method: "POST",
        body: JSON.stringify({
          command,
          commandID: body.commandID,
          issuedAtMs: body.issuedAtMs ?? Date.now(),
        }),
      });
      return json(await resp.json(), resp.status);
    }

    if (request.method === "POST" && routePath === "/wake") {
      let body = {};
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid JSON" }, 400);
      }
      if (body != null && (typeof body !== "object" || Array.isArray(body))) {
        return json({ error: "invalid wake payload" }, 400);
      }
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const resp = await stub.fetch("https://session/wake", {
        method: "POST",
        body: JSON.stringify({ reason: typeof body?.reason === "string" ? body.reason : "shortcut" }),
      });
      return json(await resp.json(), resp.status);
    }

    if (request.method === "GET" && routePath === "/status") {
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      return json(await (await stub.fetch("https://session/status")).json());
    }

    if (request.method === "POST" && routePath === "/reset") {
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const resp = await stub.fetch("https://session/reset", { method: "POST" });
      return json(await resp.json(), resp.status);
    }

    return json({ error: "not found" }, 404);
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}

async function authorize(request, env, pathname) {
  const expected = typeof env.SYNC_AUTH_TOKEN === "string" ? env.SYNC_AUTH_TOKEN.trim() : "";
  const header = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  if (header.startsWith(prefix)) {
    const token = header.slice(prefix.length);
    if (expected) {
      return constantTimeEqual(token, expected)
        ? null
        : json({ error: "unauthorized" }, 401);
    }

    // The app receives a private per-install token on its first registration.
    // Keep the static token above for backward compatibility while allowing
    // the Heroku runtime to validate the dynamic token in session storage.
    const stub = env.SESSION.get(env.SESSION.idFromName("main"));
    const response = await stub.fetch("https://session/authorize", {
      method: "POST",
      body: JSON.stringify({ token }),
    });
    if (response.ok) return null;
    return json({ error: "unauthorized" }, 401);
  }

  // The first registration bootstraps a private token. The session validates
  // the Spotify refresh token and rejects bootstrap after the first pairing.
  if (pathname === "/register" && !header) return null;
  if (!expected) return json({ error: "server access token is not configured" }, 503);
  return json({ error: "unauthorized" }, 401);
}

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

function isHexToken(value, optional = false) {
  if (optional && (value == null || value === "")) return true;
  return typeof value === "string" && /^[0-9a-f]+$/i.test(value) && value.length >= 16 && value.length <= 512;
}

function validOptionalNumber(value) {
  return value == null || (typeof value === "number" && Number.isFinite(value));
}

function validSchemaVersion(value) {
  return value == null || value === 1 || value === 2;
}

function validRGB(value) {
  return value == null || (
    Array.isArray(value) && value.length === 3 &&
    value.every(component => typeof component === "number" && Number.isFinite(component) && component >= 0 && component <= 1)
  );
}
