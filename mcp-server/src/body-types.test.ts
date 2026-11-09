import assert from "node:assert/strict";
import { register } from "node:module";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.ts";
import { handleAppErrors } from "./app-errors.ts";
import { mintSession } from "./session.ts";
import { bodyNumber, bodyText, InvalidBodyError, invalidBodyResponse } from "./http.ts";
import { migrationFiles, partialCtx, partialEnv, readMigration, type Untyped } from "./test-env.ts";

register(
  "data:text/javascript," + encodeURIComponent(`
    export function resolve(specifier, context, next) {
      if (specifier === "cloudflare:workers") return { url: "cloudflare-workers-shim:", shortCircuit: true };
      return next(specifier, context);
    }
    export function load(url, context, next) {
      if (url === "cloudflare-workers-shim:") {
        return { format: "module", shortCircuit: true,
          source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }" };
      }
      return next(url, context);
    }
  `),
  import.meta.url
);

const poison = JSON.parse('{"toString":{}}');

test("bodyText passes text, numbers and booleans as String() did, and refuses objects and arrays", () => {
  assert.equal(bodyText("abc"), "abc");
  assert.equal(bodyText(12), "12");
  assert.equal(bodyText(true), "true");
  assert.equal(bodyText(undefined), "");
  assert.equal(bodyText(null, null), null);
  assert.throws(() => bodyText(poison), InvalidBodyError);
  assert.throws(() => bodyText([]), InvalidBodyError);
  assert.equal(invalidBodyResponse(new InvalidBodyError())?.status, 400);
  assert.equal(invalidBodyResponse(new Error("x")), null);
});

test("bodyNumber converts like Number() but never throws on an object", () => {
  assert.equal(bodyNumber(5), 5);
  assert.equal(bodyNumber("7"), 7);
  assert.equal(bodyNumber(undefined), NaN);
  assert.ok(Number.isNaN(bodyNumber(poison)));
  assert.ok(Number.isNaN(bodyNumber([1])));
  assert.throws(() => Number(poison), TypeError); // why the helper exists
});

test("document-collab and app-errors routes handle poisoned {toString:{}} fields without 500 TypeError", async () => {
  const db = new DatabaseSync(":memory:");
  for (const file of migrationFiles()) db.exec(readMigration(file));
  const kv = new Map<string, string>();
  const roomSql = new DatabaseSync(":memory:");
  const { DocumentRoom } = await import("./document-room.ts");
  const roomState = {
    blockConcurrencyWhile: async (fn: () => Promise<void>) => { await fn(); },
    storage: {
      sql: {
        exec: (query: string, ...bindings: any[]) => {
          if (/^\s*(SELECT|PRAGMA)/i.test(query)) {
            const rows = roomSql.prepare(query).all(...bindings);
            return { toArray: () => rows, one: () => rows[0] };
          }
          if (bindings.length === 0) roomSql.exec(query);
          else roomSql.prepare(query).run(...bindings);
          return { toArray: () => [], one: () => undefined };
        },
      },
    },
  };
  const roomInstance = new DocumentRoom(roomState as any, {} as any);

  const env = partialEnv({
    ADMIN_DB: {
      prepare: (sql: string) => ({
        bind: (...params: any[]) => ({
          first: async () => db.prepare(sql).get(...params) ?? null,
          all: async () => ({ results: db.prepare(sql).all(...params) }),
          run: async () => ({ success: true, meta: { changes: Number(db.prepare(sql).run(...params).changes) } }),
        }),
      }),
    },
    STUDIQUO_DATA: {
      async get(key: string, type?: string) { const v = kv.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key: string, value: string) { kv.set(key, value); },
      async delete(key: string) { kv.delete(key); },
    },
    RATE_COUNTER: { getByName: () => ({ bump: async () => true }) },
    RATE_LIMIT_APP_ERROR: { limit: async () => ({ success: true }) },
    DOCUMENT_ROOM: { getByName: () => roomInstance },
  });
  const token = (await mintSession(env, "user-poison-test"))!;
  const ctx = partialCtx({ waitUntil() {} });
  const roomID = "a".repeat(64);

  // 1. DocumentRoom init with poisoned block fields does not throw 500
  const initRes = await worker.fetch(new Request(`https://example.test/api/document/rooms/${roomID}/init`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      blocks: [null, 123, { order: poison, kind: poison, text: poison, listLevel: poison }],
    }),
  }), env, ctx);
  assert.equal(initRes.status, 200);

  // 2. DocumentRoom propose with poisoned blockOrder or text returns 400 (not 500)
  for (const badBody of [
    { blockOrder: poison, previousText: "a", newText: "b" },
    { blockOrder: 0, previousText: poison, newText: "b" },
    { blockOrder: 0, previousText: "a", newText: poison },
  ]) {
    const proposeRes = await worker.fetch(new Request(`https://example.test/api/document/rooms/${roomID}/propose`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(badBody),
    }), env, ctx);
    assert.equal(proposeRes.status, 400);
  }

  // 3. DocumentRoom review with poisoned decision returns 400 (not 500)
  const reviewRes = await worker.fetch(new Request(`https://example.test/api/document/rooms/${roomID}/changes/1/review`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ decision: poison }),
  }), env, ctx);
  assert.equal(reviewRes.status, 400);

  // 4. /api/app-errors with poisoned count and occurredAt normalizes safely without throwing
  const errReq = new Request("https://example.test/api/app-errors", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      appVersion: poison,
      errors: [{ kind: "error", signature: "sig-1", title: "title-1", count: poison, occurredAt: poison }],
    }),
  });
  const errRes = await handleAppErrors(new URL(errReq.url), errReq, env);
  assert.equal(errRes?.status, 200);
  const errJson: Untyped = await errRes!.json();
  assert.equal(errJson.accepted, 1);
});
