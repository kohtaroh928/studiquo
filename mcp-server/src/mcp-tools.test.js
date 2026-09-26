import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker from "./app.js";

// Covers app.js's own usage of the MCP_INBOX contract — how the /mcp tool
// handlers and the /api/mcp/inbox routes route between a paired external
// account (env.MCP_INBOX) and a bare device connection (queueAction's
// STUDIQUO_DATA fallback) — rather than the Durable Object's own SQL logic,
// which mcp-inbox.test.js already exercises directly, or the OAuth
// mechanics (PKCE, token exchange, grants), which mcp-oauth.test.js already
// covers end to end.

const hash = value => createHash("sha256").update(value).digest("hex");

function fakeMCPInboxBinding() {
  const accounts = new Map();
  function items(account) {
    if (!accounts.has(account)) accounts.set(account, new Map());
    return accounts.get(account);
  }
  const consumed = new Set();
  return {
    getByName(account) {
      const store = items(account);
      return {
        async enqueue(id, kind, payload, source) {
          const pendingCount = [...store.values()].filter(item => item.status === "pending").length;
          if (pendingCount >= 100) throw new Error("Studiquo has 100 pending imports. Open the iPad app before sending more.");
          if (!store.has(id)) {
            store.set(id, { id, kind, payload: { type: kind, ...payload }, source, status: "pending", createdAt: Date.now() });
          }
          return { id, status: "pending" };
        },
        async list() {
          return [...store.values()].filter(item => item.status === "pending").sort((a, b) => a.createdAt - b.createdAt);
        },
        async status(id) { return store.get(id) ?? null; },
        async acknowledge(id) {
          const item = store.get(id);
          if (item?.status === "pending") item.status = "imported";
          return { id, status: item?.status ?? "missing" };
        },
        async consumeOnce(id) {
          const key = `${account}:${id}`;
          if (consumed.has(key)) return false;
          consumed.add(key);
          return true;
        },
      };
    },
  };
}

function environment() {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) { return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })) }; },
    },
    MCP_INBOX: fakeMCPInboxBinding(),
    RATE_LIMIT_MCP_REGISTER: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_AUTHORIZE: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_TOKEN: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_PAIR: { async limit() { return { success: true }; } },
  };
}

const noopCtx = { waitUntil() {} };

function freshDeviceToken(suffix) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(64)}`;
}

const fetchApp = (env, path, options = {}) =>
  worker.fetch(new Request(`https://example.test${path}`, options), env, noopCtx);

async function signIn(env, deviceToken, sub) {
  await env.STUDIQUO_DATA.put(`session:${hash(deviceToken)}`, JSON.stringify({ sub }));
}

// Runs the whole OAuth pairing dance (register client, authorize, approve
// from the signed-in device, exchange the code) and returns a working
// access token — the same sequence mcp-oauth.test.js's one big test
// performs inline, pulled out here so each test below can ask for exactly
// the scope it needs.
async function pairMCPClient(env, deviceToken, { scope } = {}) {
  const redirectUri = "https://claude.example/callback";
  const registered = await fetchApp(env, "/oauth/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "Claude", redirect_uris: [redirectUri] }),
  });
  const { client_id: clientId } = await registered.json();
  const verifier = "v".repeat(43);
  const challenge = hash(verifier);
  const challengeB64 = Buffer.from(challenge, "hex").toString("base64url");
  const scopeParam = scope ? `&scope=${encodeURIComponent(scope)}` : "";
  const authorize = await fetchApp(
    env,
    `/oauth/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&code_challenge_method=S256&code_challenge=${challengeB64}&state=abc${scopeParam}`
  );
  const page = await authorize.text();
  const pairingCode = page.match(/<code>([A-Z2-9]{12})<\/code>/)?.[1];
  const requestId = page.match(/\/oauth\/status\?id=([a-f0-9]{64})/)?.[1];
  await fetchApp(env, "/api/mcp/pair", {
    method: "POST",
    headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" },
    body: JSON.stringify({ code: pairingCode }),
  });
  const status = await fetchApp(env, `/oauth/status?id=${requestId}`);
  const callback = new URL((await status.json()).redirect);
  const code = callback.searchParams.get("code");
  const token = await fetchApp(env, "/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code, code_verifier: verifier,
    }),
  });
  const { access_token } = await token.json();
  return access_token;
}

async function callTool(env, accessToken, name, args) {
  const response = await fetchApp(env, "/mcp", {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
  });
  return response.json();
}

test("POST /api/mcp/inbox/:id with a non-UUID-shaped id is rejected with 400", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("a");
  await signIn(env, deviceToken, "student-A");

  const response = await fetchApp(env, "/api/mcp/inbox/not-a-real-id", {
    method: "POST",
    headers: { authorization: `Bearer ${deviceToken}` },
  });
  assert.equal(response.status, 400);
});

test("a device connection with no paired MCP account queues writes locally instead of touching the inbox", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("b");
  await signIn(env, deviceToken, "student-B");
  await fetchApp(env, "/api/snapshot", {
    method: "PUT",
    headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" },
    body: JSON.stringify({ version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" }),
  });

  const result = await callTool(env, deviceToken, "create_flashcards", {
    deckTitle: "英単語", cards: [{ question: "apple", answer: "りんご" }],
  });
  const value = result.result.structuredContent.result;
  // The device-only fallback shape (queueAction) is distinct from the
  // paired-account shape ({ id, status: "pending" }) — no MCP_INBOX id at all.
  assert.deepEqual(value, { queued: true, deckTitle: "英単語", cardCount: 1 });

  const queued = await env.STUDIQUO_DATA.get(`actions:${hash(deviceToken)}`, "json");
  assert.equal(queued.length, 1);
  assert.equal(queued[0].type, "create_flashcards");
});

test("a read-only MCP connection cannot create materials, and nothing is queued", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("c");
  await signIn(env, deviceToken, "student-C");
  const accessToken = await pairMCPClient(env, deviceToken, { scope: "studiquo.read" });

  const result = await callTool(env, accessToken, "create_document", { title: "メモ", body: "本文" });
  assert.equal(result.result.isError, true);
  assert.match(result.result.content[0].text, /read-only/);

  const inbox = await fetchApp(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } });
  assert.deepEqual(await inbox.json(), []);
});

test("get_import_status on a write-only MCP connection (no read scope) is rejected", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("d");
  await signIn(env, deviceToken, "student-D");
  const accessToken = await pairMCPClient(env, deviceToken, { scope: "studiquo.write" });

  const result = await callTool(env, accessToken, "get_import_status", { id: "00000000-0000-4000-8000-000000000000" });
  assert.equal(result.result.isError, true);
  assert.match(result.result.content[0].text, /cannot read/);
});

test("get_import_status on a device-only connection (no paired account) resolves to null rather than erroring", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("e");
  await signIn(env, deviceToken, "student-E");
  await fetchApp(env, "/api/snapshot", {
    method: "PUT",
    headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" },
    body: JSON.stringify({ version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" }),
  });

  const result = await callTool(env, deviceToken, "get_import_status", { id: "00000000-0000-4000-8000-000000000000" });
  assert.equal(result.result.isError, undefined);
  assert.equal(result.result.structuredContent.result, null);
});

test("a paired account's 101st queued item is reported back as a tool error, not a crash", async () => {
  const env = environment();
  const deviceToken = freshDeviceToken("f");
  await signIn(env, deviceToken, "student-F");
  const accessToken = await pairMCPClient(env, deviceToken);

  for (let i = 0; i < 100; i += 1) {
    const created = await callTool(env, accessToken, "create_document", { title: `doc ${i}`, body: "本文" });
    assert.ok(created.result.structuredContent.result.id, `item ${i} should have queued successfully`);
  }

  const overflow = await callTool(env, accessToken, "create_document", { title: "one too many", body: "本文" });
  assert.equal(overflow.result.isError, true);
  assert.match(overflow.result.content[0].text, /100 pending imports/);
});
