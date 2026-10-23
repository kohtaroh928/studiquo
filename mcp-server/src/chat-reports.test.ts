// fileChatReport on its own, with a stand-in room and database, for the paths the
// chat routes can only reach through a race (the reporter leaving the room between
// the membership check and the snapshot) or by an unexpected failure.
import assert from "node:assert/strict";
import test from "node:test";
import { fileChatReport } from "./chat-reports.ts";
import { partialCtx, partialEnv, type Untyped } from "./test-env.ts";

const ROOM = "a".repeat(64);
const url = new URL("https://example.test/api/chat/rooms/x/messages/1/report");
const args = { roomID: ROOM, messageID: 1, reporterKey: "reporter", reason: "いやがらせ" };

function setup({ snapshot, changes = 1, fail }: { snapshot?: unknown; changes?: number; fail?: Error } = {}) {
  const inserts: Untyped[][] = [];
  const asked: { roomID: string; reporterKey: string; messageID: number }[] = [];
  const env = partialEnv({
    inserts, asked,
    CHAT_ROOM: {
      getByName(roomID: string) {
        return {
          async reportSnapshot(reporterKey: string, messageID: number) {
            asked.push({ roomID, reporterKey, messageID });
            if (fail) throw fail;
            return snapshot;
          },
        };
      },
    },
    ADMIN_DB: {
      prepare() {
        return { bind: (...params: Untyped[]) => ({ async run() { inserts.push(params); return { meta: { changes } }; } }) };
      },
    },
  });
  return env;
}

const snapshot = { reportedKey: "sender", messages: [{ id: 1, text: "SECRET", reported: true }] };
const ctx = partialCtx({ waitUntil() {} });

test("a reporter the room no longer lists is refused with 403 and nothing is stored", async () => {
  const env = setup({ fail: new Error("Forbidden") });
  const response = await fileChatReport(env, ctx, url, args);
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: "Forbidden" });
  assert.deepEqual(env.inserts, []);
});

test("any other failure of the room is not turned into an answer, so it can't look like a filed report", async () => {
  const env = setup({ fail: new Error("storage unavailable") });
  await assert.rejects(() => fileChatReport(env, ctx, url, args), /storage unavailable/);
  assert.deepEqual(env.inserts, []);
});

test("a message that isn't there is a 404, and your own message can't be reported", async () => {
  const missing = setup({ snapshot: null });
  assert.equal((await fileChatReport(missing, ctx, url, args)).status, 404);
  assert.deepEqual(missing.inserts, []);

  const own = setup({ snapshot: { ...snapshot, reportedKey: "reporter" } });
  const response = await fileChatReport(own, ctx, url, args);
  assert.equal(response.status, 400);
  assert.deepEqual(own.inserts, []);
});

test("the room is asked as the reporter, for that message, and the report keeps the copy, the reporter and the sender", async () => {
  const env = setup({ snapshot });
  const response = await fileChatReport(env, ctx, url, args);
  assert.deepEqual(await response.json(), { status: "reported" });
  assert.deepEqual(env.asked, [{ roomID: ROOM, reporterKey: "reporter", messageID: 1 }]);
  assert.equal(env.inserts.length, 1);
  const [id, room, message, reporter, reported, reason, copy] = env.inserts[0];
  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.deepEqual([room, message, reporter, reported, reason], [ROOM, 1, "reporter", "sender", "いやがらせ"]);
  assert.deepEqual(JSON.parse(copy), snapshot.messages);
});

test("reporting a message that was already reported answers the same and tells Slack nothing", async () => {
  const sent: Untyped[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => { sent.push(init); return new Response("ok"); };
  try {
    const env = setup({ snapshot, changes: 0 });
    env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.example.test/x";
    const response = await fileChatReport(env, ctx, url, args);
    assert.deepEqual(await response.json(), { status: "reported" });
    assert.deepEqual(sent, []);
  } finally { globalThis.fetch = realFetch; }
});

test("a new report tells Slack its id and a link, never the message text or the reason; a Slack failure doesn't fail the report", async () => {
  const sent: string[] = [];
  const realFetch = globalThis.fetch;
  const realError = console.error;
  console.error = () => {};
  try {
    globalThis.fetch = async (_url, init) => { sent.push(String(init?.body)); return new Response("ok"); };
    const env = setup({ snapshot });
    env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.example.test/x";
    // No waitUntil: the notification is awaited before answering.
    assert.equal((await fileChatReport(env, partialCtx({}), url, args)).status, 200);
    assert.equal(sent.length, 1);
    const id = env.inserts[0][0];
    assert.ok(sent[0].includes(id));
    assert.ok(sent[0].includes(`https://example.test/api/admin/chat-reports/${id}`));
    assert.ok(!sent[0].includes("SECRET") && !sent[0].includes("いやがらせ"));

    globalThis.fetch = async () => { throw new Error("slack down"); };
    const again = setup({ snapshot });
    again.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.example.test/x";
    assert.equal((await fileChatReport(again, partialCtx({}), url, args)).status, 200);
    assert.equal(again.inserts.length, 1, "the report is stored whatever Slack does");
  } finally { globalThis.fetch = realFetch; console.error = realError; }
});

test("with no Slack address set, a report is stored and nothing is sent", async () => {
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; return new Response("ok"); };
  try {
    const env = setup({ snapshot });
    assert.equal((await fileChatReport(env, ctx, url, args)).status, 200);
    assert.equal(calls, 0);
    assert.equal(env.inserts.length, 1);
  } finally { globalThis.fetch = realFetch; }
});
