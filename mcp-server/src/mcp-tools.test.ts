import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker from "./app.ts";
import { partialCtx, partialEnv, type LooseEnv, type Untyped } from "./test-env.ts";

// Covers app.ts's own usage of the MCP_INBOX contract — how the /mcp tool
// handlers and the /api/mcp/inbox routes route between a paired external
// account (env.MCP_INBOX) and a bare device connection (queueAction's
// STUDIQUO_DATA fallback) — rather than the Durable Object's own SQL logic,
// which mcp-inbox.test.js already exercises directly, or the OAuth
// mechanics (PKCE, token exchange, grants), which mcp-oauth.test.js already
// covers end to end.

const hash = (value: Untyped) => createHash("sha256").update(value).digest("hex");

function fakeMCPInboxBinding() {
  const accounts = new Map();
  function items(account: string) {
    if (!accounts.has(account)) accounts.set(account, new Map());
    return accounts.get(account);
  }
  const consumed = new Set();
  return {
    getByName(account: string) {
      const store = items(account);
      return {
        async enqueue(id: string, kind: string, payload: unknown[], source: string) {
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
        async status(id: string) { return store.get(id) ?? null; },
        async acknowledge(id: string) {
          const item = store.get(id);
          if (item?.status === "pending") item.status = "imported";
          return { id, status: item?.status ?? "missing" };
        },
        async consumeOnce(id: string) {
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
  return partialEnv({
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key: string, value: string) { values.set(key, value); },
      async delete(key: string) { values.delete(key); },
      async list({ prefix }: { prefix?: unknown }) { return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })) }; },
    },
    MCP_INBOX: fakeMCPInboxBinding(),
    RATE_COUNTER: { getByName() { return { async bump() { return true; } }; } },
    RATE_LIMIT_MCP_REGISTER: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_AUTHORIZE: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_TOKEN: { async limit() { return { success: true }; } },
    RATE_LIMIT_MCP_PAIR: { async limit() { return { success: true }; } },
  });
}

const noopCtx = partialCtx({ waitUntil() {} });

function freshDeviceToken(suffix: string) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(64)}`;
}

const fetchApp = (env: LooseEnv, path: string, options = {}) =>
  worker.fetch(new Request(`https://example.test${path}`, options), env, noopCtx);

async function signIn(env: LooseEnv, deviceToken: string, sub: string) {
  await env.STUDIQUO_DATA.put(`session:${hash(deviceToken)}`, JSON.stringify({ sub }));
}

// Runs the whole OAuth pairing dance (register client, authorize, approve
// from the signed-in device, exchange the code) and returns a working
// access token — the same sequence mcp-oauth.test.js's one big test
// performs inline, pulled out here so each test below can ask for exactly
// the scope it needs.
async function pairMCPClient(env: LooseEnv, deviceToken: string, { scope }: { scope?: string } = {}) {
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
  const requestId = page.match(/id:'([a-f0-9]{64})'/)?.[1];
  const issued = await fetchApp(env, "/api/mcp/pairing-code", {
    method: "POST",
    headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" },
    body: JSON.stringify({ kind: "other" }),
  });
  const { code: pairingCode } = await issued.json();
  const approve = await fetchApp(env, "/oauth/pair", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: requestId, code: pairingCode }),
  });
  const callback = new URL((await approve.json()).redirect);
  const code = callback.searchParams.get("code");
  const token = await fetchApp(env, "/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code: code!, code_verifier: verifier,
    }),
  });
  const { access_token } = await token.json();
  return access_token;
}

async function callTool(env: LooseEnv, accessToken: string, name: string, args: unknown) {
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

// ---- The read tools, the calendar tool, and the device action queue ----

const SNAPSHOT = {
  version: 1,
  exportedAt: "2026-01-01T00:00:00Z",
  notebooks: [
    { id: "n1", title: "数学ノート", tags: ["理系"], pages: [{ id: "p1", title: "微分", recognizedText: "合成関数の微分" }, { id: "p2", title: "積分", recognizedText: "置換積分" }] },
    { id: "n2", title: "English Notes", pages: [{ id: "p3", title: "Grammar", recognizedText: "Present PERFECT tense" }] },
  ],
  flashcardDecks: [{ id: "d1", title: "英単語", cards: [{ question: "apple", answer: "りんご" }, { question: "pear", answer: "なし" }] }],
  calendarEvents: [{ title: "期末試験", startDate: "2026-02-01T00:00:00Z" }, { title: "補講", startDate: "2026-02-02T00:00:00Z" }, { title: "提出", startDate: "2026-02-03T00:00:00Z" }],
  folders: [{ path: "数学" }, { path: "数学/微積" }],
};

async function pairedWithSnapshot(suffix: string, scope?: string, snapshot: Untyped = SNAPSHOT) {
  const env = environment();
  const deviceToken = freshDeviceToken(suffix);
  await signIn(env, deviceToken, `student-${suffix}`);
  const synced = await fetchApp(env, "/api/snapshot", {
    method: "PUT", headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(snapshot),
  });
  assert.equal(synced.status, 200);
  const accessToken = await pairMCPClient(env, deviceToken, { scope });
  return { env, deviceToken, accessToken };
}

const toolValue = (reply: Untyped) => reply.result.structuredContent.result;

test("search_notes finds a match in a notebook title, a page title or the page's text, ignoring case, and honours the limit", async () => {
  const { env, accessToken } = await pairedWithSnapshot("e");
  const search = async (query: string, limit?: number) => toolValue(await callTool(env, accessToken, "search_notes", { query, ...(limit ? { limit } : {}) }));
  assert.deepEqual((await search("数学")).map((hit: Untyped) => hit.pageId), ["p1", "p2"], "a notebook title matches all its pages");
  assert.deepEqual((await search("積分")).map((hit: Untyped) => hit.pageId), ["p2"], "the page title and its text both say 積分, only that page");
  assert.deepEqual((await search("合成関数")).map((hit: Untyped) => hit.pageId), ["p1"], "text alone is enough");
  assert.deepEqual((await search("present perfect")).map((hit: Untyped) => hit.pageId), ["p3"], "a lower-case query finds upper-case text");
  assert.deepEqual((await search("PRESENT Perfect")).map((hit: Untyped) => hit.pageId), ["p3"], "and an upper-case query finds it too");
  assert.deepEqual((await search("grammar")).map((hit: Untyped) => hit.pageId), ["p3"]);
  assert.deepEqual(await search("存在しない言葉"), []);
  assert.equal((await search("数学", 1)).length, 1);
  const hit = (await search("置換"))[0];
  assert.deepEqual(hit, { notebookId: "n1", notebookTitle: "数学ノート", pageId: "p2", pageTitle: "積分", recognizedText: "置換積分" });
});

test("list_flashcard_decks gives counts by default and the cards only when asked", async () => {
  const { env, accessToken } = await pairedWithSnapshot("f");
  assert.deepEqual(toolValue(await callTool(env, accessToken, "list_flashcard_decks", {})), [{ id: "d1", title: "英単語", cardCount: 2 }]);
  const full = toolValue(await callTool(env, accessToken, "list_flashcard_decks", { includeCards: true }));
  assert.equal(full[0].cards.length, 2);
  assert.equal(full[0].cards[0].answer, "りんご");
});

test("list_calendar_events and list_folders return what was synced, and an empty list when nothing was", async () => {
  const { env, accessToken } = await pairedWithSnapshot("g");
  assert.deepEqual(toolValue(await callTool(env, accessToken, "list_calendar_events", { limit: 2 })).map((event: Untyped) => event.title), ["期末試験", "補講"]);
  assert.equal(toolValue(await callTool(env, accessToken, "list_calendar_events", {})).length, 3);
  assert.deepEqual(toolValue(await callTool(env, accessToken, "list_folders", {})).map((folder: Untyped) => folder.path), ["数学", "数学/微積"]);

  const bare = await pairedWithSnapshot("h", undefined, { version: 1, exportedAt: "2026-01-01T00:00:00Z", notebooks: [] });
  assert.deepEqual(toolValue(await callTool(bare.env, bare.accessToken, "list_calendar_events", {})), []);
  assert.deepEqual(toolValue(await callTool(bare.env, bare.accessToken, "list_folders", {})), []);
});

test("every read tool refuses a connection that was only given write access", async () => {
  const { env, accessToken } = await pairedWithSnapshot("i", "studiquo.write");
  for (const [name, args] of [["search_notes", { query: "数学" }], ["list_flashcard_decks", {}], ["list_calendar_events", {}], ["list_folders", {}], ["list_notebooks", {}]] as const) {
    const reply = await callTool(env, accessToken, name, args);
    assert.equal(reply.result.isError, true, name);
    assert.match(reply.result.content[0].text, /cannot read materials/, name);
    assert.equal(reply.result.content[0].text.includes("数学"), false, `${name} leaked nothing`);
  }
});

test("add_calendar_event queues the event for the paired account, and refuses a read-only connection or a bad date", async () => {
  const { env, deviceToken, accessToken } = await pairedWithSnapshot("j");
  const event = { title: "中間試験", startDate: "2026-05-01T09:00:00Z", endDate: "2026-05-01T10:00:00Z", kind: "test", notes: "範囲: 1〜3章" };
  const queued = toolValue(await callTool(env, accessToken, "add_calendar_event", event));
  assert.equal(queued.status, "pending");
  const inbox = await (await fetchApp(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } })).json();
  assert.equal(inbox.length, 1);
  assert.deepEqual([inbox[0].kind, inbox[0].payload.title, inbox[0].payload.kind, inbox[0].payload.notes], ["add_calendar_event", "中間試験", "test", "範囲: 1〜3章"]);

  const bad = await callTool(env, accessToken, "add_calendar_event", { ...event, startDate: "next friday" });
  assert.ok(bad.result?.isError || bad.error, "an invalid date is an error, not a queued event");
  assert.equal((await (await fetchApp(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } })).json()).length, 1);

  const readOnly = await pairedWithSnapshot("k", "studiquo.read");
  const refused = await callTool(readOnly.env, readOnly.accessToken, "add_calendar_event", event);
  assert.equal(refused.result.isError, true);
  assert.match(refused.result.content[0].text, /read-only/);
});

// A device-only connection works from the snapshot its own device synced.
async function deviceWithSnapshot(env: LooseEnv, suffix: string) {
  const deviceToken = freshDeviceToken(suffix);
  await signIn(env, deviceToken, `student-${suffix}`);
  await fetchApp(env, "/api/snapshot", {
    method: "PUT", headers: { authorization: `Bearer ${deviceToken}`, "content-type": "application/json" },
    body: JSON.stringify({ version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" }),
  });
  return deviceToken;
}

test("a device-only connection queues a calendar event locally, without the paired inbox", async () => {
  const env = environment();
  const deviceToken = await deviceWithSnapshot(env, "l");
  const result = await callTool(env, deviceToken, "add_calendar_event", {
    title: "レポート提出", startDate: "2026-06-01T00:00:00Z", endDate: "2026-06-01T01:00:00Z",
  });
  assert.deepEqual(toolValue(result), { queued: true, title: "レポート提出" });
  const queued = await env.STUDIQUO_DATA.get(`actions:${hash(deviceToken)}`, "json");
  assert.deepEqual([queued.length, queued[0].type, queued[0].kind], [1, "add_calendar_event", "other"], "the kind defaults to other");
});

test("create_flashcards for a folder that doesn't exist is a tool error and queues nothing", async () => {
  const { env, deviceToken, accessToken } = await pairedWithSnapshot("m");
  const cards = [{ question: "q", answer: "a" }];
  const missing = await callTool(env, accessToken, "create_flashcards", { deckTitle: "x", folderPath: "存在しない", cards });
  assert.equal(missing.result.isError, true);
  assert.match(missing.result.content[0].text, /folder does not exist/);
  const ok = await callTool(env, accessToken, "create_flashcards", { deckTitle: "x", folderPath: "数学/微積", cards });
  assert.equal(toolValue(ok).status, "pending");
  assert.equal((await (await fetchApp(env, "/api/mcp/inbox", { headers: { authorization: `Bearer ${deviceToken}` } })).json()).length, 1, "only the valid one was queued");
});

test("DELETE /api/actions clears the device's queued actions, and only that device's", async () => {
  const env = environment();
  const mine = await deviceWithSnapshot(env, "n");
  const other = await deviceWithSnapshot(env, "o");
  for (const token of [mine, other]) {
    await callTool(env, token, "create_flashcards", { deckTitle: "d", cards: [{ question: "q", answer: "a" }] });
  }
  assert.equal((await env.STUDIQUO_DATA.get(`actions:${hash(mine)}`, "json")).length, 1);
  const cleared = await fetchApp(env, "/api/actions", { method: "DELETE", headers: { authorization: `Bearer ${mine}` } });
  assert.deepEqual(await cleared.json(), { cleared: true });
  assert.equal(await env.STUDIQUO_DATA.get(`actions:${hash(mine)}`), null);
  assert.equal((await env.STUDIQUO_DATA.get(`actions:${hash(other)}`, "json")).length, 1, "another device's queue is untouched");
  const without = await fetchApp(env, "/api/actions", { method: "DELETE" });
  assert.ok([401, 403].includes(without.status), `answered ${without.status} without a token`);
});
