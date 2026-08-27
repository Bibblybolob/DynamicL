import { PlaybackSessionV2 } from "./session.js";

export { PlaybackSessionV2 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ ok: true, service: "dynamicallyrics-sync" });
    }

    const protectedRoute =
      url.pathname === "/register" || url.pathname === "/status" || url.pathname === "/reset";
    if (protectedRoute) {
      const authError = authorize(request, env);
      if (authError) return authError;
    }

    if (request.method === "POST" && url.pathname === "/register") {
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
      if (!isHexToken(updateToken) || !isHexToken(pushToStartToken, true) ||
          typeof spotifyRefreshToken !== "string" || spotifyRefreshToken.length < 10) {
        return json({ error: "updateToken and spotifyRefreshToken required" }, 400);
      }
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      const resp = await stub.fetch("https://session/register", {
        method: "POST",
        body: JSON.stringify({ updateToken, pushToStartToken, spotifyRefreshToken }),
      });
      return json(await resp.json(), resp.status);
    }

    if (request.method === "GET" && url.pathname === "/status") {
      const stub = env.SESSION.get(env.SESSION.idFromName("main"));
      return json(await (await stub.fetch("https://session/status")).json());
    }

    if (request.method === "POST" && url.pathname === "/reset") {
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

function authorize(request, env) {
  const expected = typeof env.SYNC_AUTH_TOKEN === "string" ? env.SYNC_AUTH_TOKEN.trim() : "";
  if (!expected) return json({ error: "server access token is not configured" }, 503);

  const header = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  if (!header.startsWith(prefix) || !constantTimeEqual(header.slice(prefix.length), expected)) {
    return json({ error: "unauthorized" }, 401);
  }
  return null;
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
