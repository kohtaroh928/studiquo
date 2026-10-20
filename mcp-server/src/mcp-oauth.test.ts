// @ts-nocheck 型の付け方は docs/notes/ts-migration.md の「テストの型検査」を参照。
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test, { mock } from "node:test";
import worker from "./app.ts";

const hash = value => createHash("sha256").update(value).digest("hex");

function environment() {
  const values = new Map();
  const items = new Map();
  const consumed = new Set();
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
    MCP_INBOX: { getByName(account) { return {
      async consumeOnce(id) { const key = `${account}:${id}`; if (consumed.has(key)) return false; consumed.add(key); return true; },
      async enqueue(id, kind, payload, source) {
        const record = { id, kind, payload: { type: kind, ...payload }, source, status: "pending" };
        items.set(`${account}:${id}`, record);
        return { id, status: "pending" };
      },
      async list() { return [...items].filter(([key, value]) => key.startsWith(`${account}:`) && value.status === "pending").map(([, value]) => value); },
      async status(id) { return items.get(`${account}:${id}`) ?? null; },
      async acknowledge(id) { const item = items.get(`${account}:${id}`); if (item) item.status = "imported"; return item ?? null; },
    }; } },
    RATE_COUNTER: { getByName() { return { async bump() { return true; } }; } },
    RATE_LIMIT_MCP_REGISTER: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_AUTHORIZE: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_TOKEN: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_PAIR: { async limit() { return { success: true }; } },
  };
}

// The owner makes a code in the app; the AI app's page takes it. Returns the
// answer of the page's POST /oauth/pair.
async function enterOwnerCode(env, flowId, sub, kind = "other") {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const { code } = await issueOwnerCode(env, sub, kind);
  return fetch(env, "/oauth/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: flowId, code }) });
}

const fetch = (env, path, options = {}) => worker.fetch(new Request(`https://example.test${path}`, options), env, { waitUntil() {} });

test("MCP connector pairs through the logged-in iPad, imports by account, and can be revoked", async () => {
  const env = environment();
  const deviceToken = `${Math.floor(Date.now() / 1000)}.${"a".repeat(64)}`;
  await env.STUDIQUO_DATA.put(`session:${hash(deviceToken)}`, JSON.stringify({ sub: "student-A" }));
  const redirectUri = "https://claude.example/callback";
  const registered = await fetch(env, "/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude", redirect_uris: [redirectUri] }) });
  assert.equal(registered.status, 201);
  const { client_id: clientId } = await registered.json();
  const verifier = "v".repeat(43);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const authorize = await fetch(env, `/oauth/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&code_challenge_method=S256&code_challenge=${challenge}&state=abc`);
  assert.equal(authorize.status, 200);
  // The page that shows the pairing code must not be embeddable in another site.
  assert.match(authorize.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.equal(authorize.headers.get("x-content-type-options"), "nosniff");
  const page = await authorize.text();
  const requestId = page.match(/id:'([a-f0-9]{64})'/)?.[1];
  assert.ok(requestId);
  assert.doesNotMatch(page, /<code>/, "the page no longer shows a code to copy");
  const issued = await fetch(env, "/api/mcp/pairing-code", { method: "POST", headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ kind: "other" }) });
  assert.equal(issued.status, 200);
  const { code: pairingCode, kind: issuedKind } = await issued.json();
  assert.match(pairingCode, /^[A-Z2-9]{12}$/);
  assert.equal(issuedKind, "other");
  const approve = await fetch(env, "/oauth/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: requestId, code: pairingCode }) });
  const callback = new URL((await approve.json()).redirect);
  assert.equal(callback.searchParams.get("state"), "abc");
  const code = callback.searchParams.get("code");
  const token = await fetch(env, "/oauth/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code, code_verifier: verifier }) });
  assert.equal(token.status, 200);
  const { access_token: accessToken } = await token.json();
  const replay = await fetch(env, "/oauth/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code, code_verifier: verifier }) });
  assert.equal(replay.status, 400);
  const call = await fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_document", arguments: { title: "統計", body: "平均と分散", folderPath: "" } } }) });
  assert.equal(call.status, 200);
  const response = await call.json();
  const itemId = response.result.structuredContent.result.id;
  assert.ok(itemId);
  const snapshot = await fetch(env, "/api/snapshot", { method: "PUT", headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ version: 1, notebooks: [], folders: [{ path: "数学" }] }) });
  assert.equal(snapshot.status, 200);
  for (const [name, args] of [
    ["create_flashcards", { deckTitle: "公式", folderPath: "数学", cards: [{ question: "1+1", answer: "2" }] }],
    ["create_notebook", { title: "まとめ", folderPath: "数学", pages: [{ title: "1", text: "内容" }] }],
  ]) {
    const created = await fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } }) });
    assert.equal(created.status, 200);
    assert.ok((await created.json()).result.structuredContent.result.id);
  }
  const invalidFolder = await fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_document", arguments: { title: "失敗", body: "本文", folderPath: "存在しない" } } }) });
  assert.equal((await invalidFolder.json()).result.isError, true);
  const inbox = await fetch(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } });
  const inboxItems = await inbox.json();
  assert.equal(inboxItems.length, 3);
  assert.equal(inboxItems[0].payload.body, "平均と分散");
  const sameAccountToken = `${Math.floor(Date.now() / 1000)}.${"b".repeat(64)}`;
  const otherAccountToken = `${Math.floor(Date.now() / 1000)}.${"c".repeat(64)}`;
  await env.STUDIQUO_DATA.put(`session:${hash(sameAccountToken)}`, JSON.stringify({ sub: "student-A" }));
  await env.STUDIQUO_DATA.put(`session:${hash(otherAccountToken)}`, JSON.stringify({ sub: "student-B" }));
  const sameInbox = await fetch(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${sameAccountToken}` } });
  assert.equal((await sameInbox.json()).length, 3);
  const otherInbox = await fetch(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${otherAccountToken}` } });
  assert.deepEqual(await otherInbox.json(), []);
  const ack = await fetch(env, `/api/mcp/inbox/${itemId}`, { method: "POST", headers: { authorization: `Bearer ${deviceToken}` } });
  assert.equal((await ack.json()).status, "imported");
  const importedStatus = await fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "get_import_status", arguments: { id: itemId } } }) });
  assert.equal((await importedStatus.json()).result.structuredContent.result.status, "imported");
  const emptyInbox = await fetch(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } });
  assert.equal((await emptyInbox.json()).length, 2);
  const revoke = await fetch(env, `/api/mcp/connections/${hash(clientId)}`, { method: "DELETE", headers: { authorization: `Bearer ${deviceToken}` } });
  assert.equal((await revoke.json()).revoked, true);
  const after = await fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" }, body: "{}" });
  assert.equal(after.status, 401);
});

test("a refresh token from before a revocation stays dead when the same app is approved again", async () => {
  const { revokeConnection } = await import("./mcp-oauth.ts");
  const env = environment();
  const sub = "apple:owner";
  const clientId = "studiquo_" + "a".repeat(32);
  const redirectUri = "https://client.example/callback";
  await env.STUDIQUO_DATA.put(`mcp:client:${clientId}`, JSON.stringify({ clientName: "App", redirectUris: [redirectUri] }));
  const refresh = token => fetch(env, "/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: token }).toString(),
  });

  // Approve once and take the refresh token the app now holds.
  const approve = async (id, code) => {
    await env.STUDIQUO_DATA.put(`mcp:auth:${id}`, JSON.stringify({ kind: "other", clientId, clientName: "App", redirectUri, codeChallenge: "c".repeat(43), scope: "studiquo.read" }));
    assert.equal((await enterOwnerCode(env, id, sub)).status, 200);
  };
  await approve("1".repeat(64), "ABCDEFGHJKMN");
  const grant = JSON.parse(await env.STUDIQUO_DATA.get(`mcp:grant:${hash(sub)}:${hash(clientId)}`));
  const stolen = "mcp_refresh_" + "s".repeat(40);
  await env.STUDIQUO_DATA.put(`mcp:refresh:${hash(stolen)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read", grantId: grant.nonce }));
  const legitimate = "mcp_refresh_" + "l".repeat(40);
  await env.STUDIQUO_DATA.put(`mcp:refresh:${hash(legitimate)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read", grantId: grant.nonce }));
  assert.equal((await refresh(legitimate)).status, 200, "valid while the connection exists");

  // The owner disconnects the app, then approves it again.
  await revokeConnection(env, sub, hash(clientId));
  assert.equal((await refresh(stolen)).status, 400, "dead once revoked");
  await approve("2".repeat(64), "QRSTUVWXYZ23");
  assert.equal((await refresh(stolen)).status, 400, "and not revived by approving the app again");
});

test("a registered client expires after a year instead of staying forever", async () => {
  const env = environment();
  const ttls = new Map();
  const put = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value, options) => { ttls.set(key, options?.expirationTtl); return put(key, value, options); };
  const response = await fetch(env, "/oauth/register", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://claude.ai/callback"] }),
  });
  assert.equal(response.status, 201);
  const { client_id } = await response.json();
  assert.equal(ttls.get(`mcp:client:${client_id}`), 365 * 24 * 3600);
});

test("a refresh token that was already exchanged cuts the whole connection", async () => {
  const env = environment();
  const sub = "apple:owner";
  const clientId = "studiquo_" + "b".repeat(32);
  const redirectUri = "https://client.example/callback";
  await env.STUDIQUO_DATA.put(`mcp:client:${clientId}`, JSON.stringify({ clientName: "App", redirectUris: [redirectUri] }));
  await env.STUDIQUO_DATA.put(`mcp:auth:${"3".repeat(64)}`, JSON.stringify({ kind: "other", clientId, clientName: "App", redirectUri, codeChallenge: "c".repeat(43), scope: "studiquo.read" }));
  assert.equal((await enterOwnerCode(env, "3".repeat(64), sub)).status, 200);
  const grant = JSON.parse(await env.STUDIQUO_DATA.get(`mcp:grant:${hash(sub)}:${hash(clientId)}`));
  const first = "mcp_refresh_" + "1".repeat(40);
  await env.STUDIQUO_DATA.put(`mcp:refresh:${hash(first)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read", grantId: grant.nonce }));
  const refresh = token => fetch(env, "/oauth/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: token }).toString(),
  });

  // The legitimate exchange rotates the token.
  const rotated = await refresh(first);
  assert.equal(rotated.status, 200);
  const { access_token: access, refresh_token: second } = await rotated.json();
  const mcp = token => fetch(env, "/mcp", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) });
  assert.notEqual((await mcp(access)).status, 401, "the new access token works");

  // The old token is shown again, by a client that retried or by whoever copied it.
  assert.equal((await refresh(first)).status, 400);

  // Everything issued under the connection is dead, including what was just rotated in.
  assert.equal(await env.STUDIQUO_DATA.get(`mcp:grant:${hash(sub)}:${hash(clientId)}`), null);
  assert.equal((await refresh(second)).status, 400);
  assert.equal((await mcp(access)).status, 401);
});

test("an unknown refresh token revokes nothing", async () => {
  const env = environment();
  const sub = "apple:owner";
  const clientId = "studiquo_" + "c".repeat(32);
  const grantKey = `mcp:grant:${hash(sub)}:${hash(clientId)}`;
  await env.STUDIQUO_DATA.put(grantKey, JSON.stringify({ clientName: "App", createdAt: 1, nonce: "n" }));
  const response = await fetch(env, "/oauth/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: "mcp_refresh_" + "9".repeat(40) }).toString(),
  });
  assert.equal(response.status, 400);
  assert.notEqual(await env.STUDIQUO_DATA.get(grantKey), null);
});

// ---- Owner-issued pairing code ---------------------------------------------------

// A counter that really counts, so single-use and attempt limits can be tested.
function countingCounter() {
  const counts = new Map();
  return { getByName(name) { return { async bump(limit, _window, amount = 1) {
    const used = (counts.get(name) ?? 0) + amount;
    if (used > limit) return false;
    counts.set(name, used);
    return true;
  } }; } };
}

async function startFlow(env, redirectUri, clientName = "Client") {
  const registered = await fetch(env, "/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: clientName, redirect_uris: [redirectUri] }) });
  const { client_id: clientId } = await registered.json();
  const challenge = createHash("sha256").update("v".repeat(43)).digest("base64url");
  const page = await (await fetch(env, `/oauth/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&code_challenge_method=S256&code_challenge=${challenge}&state=s`)).text();
  return page.match(/id:'([a-f0-9]{64})'/)[1];
}

const submit = (env, id, code) => fetch(env, "/oauth/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id, code }) });

test("clients are sorted into Claude, ChatGPT, Codex or other by where they send the owner back to", async () => {
  const { classifyClient } = await import("./mcp-oauth.ts");
  assert.equal(classifyClient({ clientName: "x", redirectUris: ["https://claude.ai/api/mcp/auth_callback"] }), "claude");
  assert.equal(classifyClient({ clientName: "x", redirectUris: ["https://chatgpt.com/connector_platform_oauth_redirect"] }), "chatgpt");
  assert.equal(classifyClient({ clientName: "Codex CLI", redirectUris: ["http://localhost:1455/callback"] }), "codex");
  assert.equal(classifyClient({ clientName: "My tool", redirectUris: ["http://localhost:1455/callback"] }), "other");
  // The name alone proves nothing: a client calling itself Claude on its own address is "other".
  assert.equal(classifyClient({ clientName: "Claude", redirectUris: ["https://evil.example/callback"] }), "other");
  // Look-alike hosts do not count.
  assert.equal(classifyClient({ clientName: "x", redirectUris: ["https://claude.ai.evil.example/cb"] }), "other");
  assert.equal(classifyClient({ clientName: "x", redirectUris: ["https://claude.ai/cb", "https://evil.example/cb"] }), "other");
});

test("a code made for one kind of app is refused by another kind and is not used up", async () => {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const claudeFlow = await startFlow(env, "https://claude.ai/api/mcp/auth_callback", "Claude");
  const otherFlow = await startFlow(env, "https://attacker.example/callback", "Claude");
  const { code } = await issueOwnerCode(env, "apple:owner", "claude");
  const wrong = await submit(env, otherFlow, code);
  assert.equal(wrong.status, 400);
  assert.match((await wrong.json()).message, /別の種類/);
  const right = await submit(env, claudeFlow, code);
  assert.equal(right.status, 200, "the code still works for the app it was made for");
  assert.match((await right.json()).redirect, /^https:\/\/claude\.ai\/api\/mcp\/auth_callback\?code=mcp_code_/);
});

test("a code works once", async () => {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const first = await startFlow(env, "https://client.example/a");
  const second = await startFlow(env, "https://client.example/b");
  const { code } = await issueOwnerCode(env, "apple:owner", "other");
  assert.equal((await submit(env, first, code)).status, 200);
  assert.equal((await submit(env, second, code)).status, 400);
});

test("the code is accepted with spaces, hyphens and lower case, as the owner types it", async () => {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const id = await startFlow(env, "https://client.example/a");
  const { code } = await issueOwnerCode(env, "apple:owner", "other");
  const typed = `${code.slice(0, 4)}-${code.slice(4, 8)} ${code.slice(8)}`.toLowerCase();
  assert.equal((await submit(env, id, typed)).status, 200);
});

test("a new code replaces the last one, and an expired code is gone", async () => {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const ttls = new Map();
  const put = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value, options) => { ttls.set(key.split(":").slice(0, 2).join(":"), options?.expirationTtl); return put(key, value, options); };
  const id = await startFlow(env, "https://client.example/a");
  const old = await issueOwnerCode(env, "apple:owner", "other");
  const fresh = await issueOwnerCode(env, "apple:owner", "other");
  assert.equal(ttls.get("mcp:owner-code"), 300, "five minutes");
  assert.equal((await submit(env, id, old.code)).status, 400);
  assert.equal((await submit(env, id, fresh.code)).status, 200);
  assert.equal(await issueOwnerCode(env, "apple:owner", "not-a-kind"), null);
});

test("a page that keeps guessing is closed after five wrong tries, even if the next one is right", async () => {
  const { issueOwnerCode } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const id = await startFlow(env, "https://client.example/a");
  const { code } = await issueOwnerCode(env, "apple:owner", "other");
  for (let i = 0; i < 5; i++) assert.equal((await submit(env, id, "AAAAAAAAAAAA")).status, 400);
  const closed = await submit(env, id, code);
  assert.equal(closed.status, 429);
  assert.equal((await submit(env, id, code)).status, 400, "the page is gone");
});

test("guesses from one address are capped across pages", async () => {
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  let last;
  for (let i = 0; i < 21; i++) {
    const id = await startFlow(env, `https://client.example/${i}`);
    last = await submit(env, id, "AAAAAAAAAAAA");
  }
  assert.equal(last.status, 429);
});

test("connecting an app tells the owner's devices, and a failed notice does not undo the connection", async () => {
  const { issueOwnerCode, listConnections } = await import("./mcp-oauth.ts");
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const errors = mock.method(console, "error", () => {});
  try {
    const id = await startFlow(env, "https://claude.ai/api/mcp/auth_callback", "Claude");
    const { code } = await issueOwnerCode(env, "apple:owner", "claude");
    assert.equal((await submit(env, id, code)).status, 200);
    const connections = await listConnections(env, "apple:owner");
    assert.equal(connections.length, 1);
    assert.equal(connections[0].kind, "claude");
  } finally { errors.mock.restore(); }
});

test("issued tokens are listed under their account, and the first listing starts the clock for deletions", async () => {
  const env = environment();
  env.RATE_COUNTER = countingCounter();
  const redirectUri = "https://client.example/a";
  const registered = await fetch(env, "/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "C", redirect_uris: [redirectUri] }) });
  const { client_id: clientId } = await registered.json();
  const challenge = createHash("sha256").update("v".repeat(43)).digest("base64url");
  const page = await (await fetch(env, `/oauth/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&code_challenge_method=S256&code_challenge=${challenge}&state=s`)).text();
  const flowId = page.match(/id:'([a-f0-9]{64})'/)[1];
  const { redirect } = await (await enterOwnerCode(env, flowId, "apple:owner")).json();
  const code = new URL(redirect).searchParams.get("code");
  assert.equal(await env.STUDIQUO_DATA.get("mcp:token-index-since"), null, "nothing issued yet");
  const token = await fetch(env, "/oauth/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code, code_verifier: "v".repeat(43) }).toString(),
  });
  const issued = await token.json();
  assert.equal(token.status, 200);
  const owner = hash("apple:owner");
  assert.notEqual(await env.STUDIQUO_DATA.get(`mcp:token-index:${owner}:access:${hash(issued.access_token)}`), null);
  assert.notEqual(await env.STUDIQUO_DATA.get(`mcp:token-index:${owner}:refresh:${hash(issued.refresh_token)}`), null);
  assert.ok(Number(await env.STUDIQUO_DATA.get("mcp:token-index-since")) > 0);
});
