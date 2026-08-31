const MAX_BODY = 16_000;

function json(value, status = 200) {
  return Response.json(value, { status, headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } });
}

function bearer(request) {
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.get("authorization") ?? "");
  const token = match?.[1]?.trim() ?? "";
  return token.length >= 32 && token.length <= 256 ? token : null;
}

async function hash(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function readBody(request) {
  if (!request.body || Number(request.headers.get("content-length") ?? 0) > MAX_BODY) return null;
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) { await reader.cancel(); return null; }
    text += decoder.decode(value, { stream: true });
  }
  try { return JSON.parse(text + decoder.decode()); } catch { return null; }
}

function code() {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[value % 32]).join("");
}

async function ensureUser(env, key, name = null) {
  const storageKey = `chat:user:${key}`;
  let user = await env.STUDIQUO_DATA.get(storageKey, "json");
  if (user) {
    const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
    if (cleaned && cleaned !== user.name) {
      user.name = cleaned;
      await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return user;
  }
  let friendCode;
  do { friendCode = code(); } while (await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`));
  user = { key, name: String(name ?? "").trim().slice(0, 80) || "Studiquoユーザー", code: friendCode, friends: [] };
  await Promise.all([
    env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user)),
    env.STUDIQUO_DATA.put(`chat:code:${friendCode}`, key),
  ]);
  return user;
}

async function roomID(first, second) {
  return hash([first, second].sort().join(":"));
}

export async function handleChat(url, request, env) {
  if (!url.pathname.startsWith("/api/chat/")) return null;
  const token = bearer(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  const key = await hash(token);

  if (url.pathname === "/api/chat/me" && request.method === "POST") {
    const body = await readBody(request);
    const user = await ensureUser(env, key, body?.name);
    return json({ code: user.code, name: user.name });
  }

  if (url.pathname === "/api/chat/friends" && request.method === "GET") {
    const user = await ensureUser(env, key);
    return json(user.friends ?? []);
  }

  if (url.pathname === "/api/chat/friends" && request.method === "POST") {
    const body = await readBody(request);
    const friendCode = String(body?.code ?? "").trim().toUpperCase();
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (!otherKey || otherKey === key) return json({ error: "Friend not found." }, 404);
    const [user, other] = await Promise.all([ensureUser(env, key), ensureUser(env, otherKey)]);
    const room = await roomID(key, otherKey);
    const mine = { code: other.code, name: other.name, roomID: room };
    const theirs = { code: user.code, name: user.name, roomID: room };
    user.friends = [...(user.friends ?? []).filter(item => item.code !== other.code), mine].slice(-500);
    other.friends = [...(other.friends ?? []).filter(item => item.code !== user.code), theirs].slice(-500);
    await Promise.all([
      env.STUDIQUO_DATA.put(`chat:user:${key}`, JSON.stringify(user)),
      env.STUDIQUO_DATA.put(`chat:user:${otherKey}`, JSON.stringify(other)),
      env.CHAT_ROOM.getByName(room).initialize(room, [key, otherKey]),
    ]);
    return json(mine);
  }

  const match = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages$/.exec(url.pathname);
  if (match && request.method === "GET") {
    const after = Math.max(0, Number(url.searchParams.get("after") ?? 0) || 0);
    return json(await env.CHAT_ROOM.getByName(match[1]).listMessages(key, after));
  }
  if (match && request.method === "POST") {
    const body = await readBody(request);
    const text = String(body?.text ?? "").trim().slice(0, 2_000);
    if (!text) return json({ error: "Message is required." }, 400);
    return json(await env.CHAT_ROOM.getByName(match[1]).sendMessage(key, text));
  }

  return json({ error: "Not found" }, 404);
}
