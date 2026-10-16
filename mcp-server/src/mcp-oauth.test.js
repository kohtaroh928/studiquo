import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker from "./app.js";

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
    RATE_LIMIT_MCP_REGISTER: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_AUTHORIZE: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_TOKEN: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_PAIR: { async limit() { return { success: true }; } },
  };
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
  const pairingCode = page.match(/<code>([A-Z2-9]{12})<\/code>/)?.[1];
  const requestId = page.match(/\/oauth\/status\?id=([a-f0-9]{64})/)?.[1];
  assert.ok(pairingCode);
  assert.ok(requestId);
  const preview = await fetch(env, `/api/mcp/pair?code=${pairingCode}`, { headers: { authorization: `Bearer ${deviceToken}` } });
  assert.equal((await preview.json()).clientName, "Claude");
  const approve = await fetch(env, "/api/mcp/pair", { method: "POST", headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ code: pairingCode }) });
  assert.equal((await approve.json()).approved, true);
  const status = await fetch(env, `/oauth/status?id=${requestId}`);
  const callback = new URL((await status.json()).redirect);
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
  const { approvePairing, revokeConnection } = await import("./mcp-oauth.js");
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
    await env.STUDIQUO_DATA.put(`mcp:auth:${id}`, JSON.stringify({ status: "pending", clientId, clientName: "App", redirectUri, codeChallenge: "c".repeat(43), scope: "studiquo.read" }));
    await env.STUDIQUO_DATA.put(`mcp:pair:${code}`, id);
    assert.equal(await approvePairing(env, code, sub), true);
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
