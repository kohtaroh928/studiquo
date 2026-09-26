import assert from "node:assert/strict";
import test from "node:test";
import { register } from "node:module";
import { DatabaseSync } from "node:sqlite";

// mcp-inbox.js's MCPInbox extends the real `DurableObject` from
// "cloudflare:workers", a module that only exists inside the Workers
// runtime. Rather than hand-mirroring its SQL logic in JS (as chat.test.js
// does for chat-room.js), this shims that one import with a minimal stand-in
// so the actual class — actual SQL statements included — can run directly
// under `node --test`, backed by Node's own built-in SQLite.
register(
  "data:text/javascript," + encodeURIComponent(`
    export function resolve(specifier, context, next) {
      if (specifier === "cloudflare:workers") return { url: "cloudflare-workers-shim:", shortCircuit: true };
      return next(specifier, context);
    }
    export function load(url, context, next) {
      if (url === "cloudflare-workers-shim:") {
        return {
          format: "module",
          shortCircuit: true,
          source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }",
        };
      }
      return next(url, context);
    }
  `),
  import.meta.url
);

const { MCPInbox } = await import("./mcp-inbox.js");

// Wraps a real in-memory SQLite database in the shape mcp-inbox.js expects
// from `ctx.storage.sql`: a single `.exec(query, ...params)` that runs the
// statement and, for a SELECT, returns its rows as a spreadable array —
// same as Cloudflare's own SqlStorageCursor.
function makeSql(db) {
  return {
    exec(query, ...params) {
      if (query.trim().toUpperCase().startsWith("SELECT")) return db.prepare(query).all(...params);
      if (params.length) db.prepare(query).run(...params);
      else db.exec(query);
      return [];
    },
  };
}

function freshInbox() {
  const db = new DatabaseSync(":memory:");
  return new MCPInbox({ storage: { sql: makeSql(db) } }, {});
}

const DAY_MS = 24 * 60 * 60 * 1000;

test("enqueue creates a new item in pending status", async () => {
  const inbox = freshInbox();
  const result = await inbox.enqueue("id-1", "create_document", { title: "数学ノート" }, "claude");
  assert.deepEqual(result, { id: "id-1", status: "pending" });

  const [item] = await inbox.list();
  assert.equal(item.id, "id-1");
  assert.equal(item.status, "pending");
  assert.equal(item.source, "claude");
  assert.deepEqual(item.payload, { type: "create_document", title: "数学ノート" });
});

test("enqueue ignores a duplicate id instead of overwriting the original payload", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("dup-1", "create_document", { title: "最初の版" }, "claude");
  await inbox.enqueue("dup-1", "create_document", { title: "後から送った版" }, "claude");

  const items = await inbox.list();
  assert.equal(items.length, 1);
  assert.equal(items[0].payload.title, "最初の版");
});

test("enqueue refuses a 101st pending item with a clear error", async () => {
  const inbox = freshInbox();
  for (let i = 0; i < 100; i += 1) {
    await inbox.enqueue(`id-${i}`, "create_document", { title: `doc ${i}` }, "claude");
  }
  await assert.rejects(
    () => inbox.enqueue("id-100", "create_document", { title: "one too many" }, "claude"),
    /100 pending imports/
  );
  // The rejected call must not have been inserted.
  assert.equal((await inbox.list()).length, 100);
});

test("enqueue's own opportunistic cleanup removes imported items older than 90 days", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("old-1", "create_document", { title: "old" }, "claude");
  await inbox.acknowledge("old-1");
  // Backdate it past the 90-day retention window directly, the same way
  // chat.test.js backdates an attachment to simulate age without waiting.
  inbox.ctx.storage.sql.exec("UPDATE items SET imported_at = ? WHERE id = ?", Date.now() - 91 * DAY_MS, "old-1");

  // Cleanup only runs as a side effect of the next enqueue.
  await inbox.enqueue("new-1", "create_document", { title: "new" }, "claude");

  const remainingIds = inbox.ctx.storage.sql.exec("SELECT id FROM items").map(row => row.id);
  assert.deepEqual(remainingIds, ["new-1"]);
});

test("enqueue's cleanup leaves a recently-imported item alone", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("recent-1", "create_document", { title: "recent" }, "claude");
  await inbox.acknowledge("recent-1");

  await inbox.enqueue("new-1", "create_document", { title: "new" }, "claude");

  const remainingIds = inbox.ctx.storage.sql.exec("SELECT id FROM items").map(row => row.id).sort();
  assert.deepEqual(remainingIds, ["new-1", "recent-1"]);
});

test("list returns only pending items, oldest first, and never an imported one", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("a", "create_document", {}, "claude");
  await inbox.enqueue("b", "create_document", {}, "claude");
  await inbox.enqueue("c", "create_document", {}, "claude");
  await inbox.acknowledge("b");
  // Force a deterministic creation order independent of real-clock ties.
  inbox.ctx.storage.sql.exec("UPDATE items SET created_at = 1 WHERE id = ?", "c");
  inbox.ctx.storage.sql.exec("UPDATE items SET created_at = 2 WHERE id = ?", "a");

  const items = await inbox.list();
  assert.deepEqual(items.map(item => item.id), ["c", "a"]);
  assert.ok(items.every(item => item.status === "pending"));
});

test("list never returns more than 100 items even if more rows exist", async () => {
  const inbox = freshInbox();
  // Inserted directly, bypassing enqueue's own 100-pending cap, so this
  // exercises list()'s own LIMIT as a second line of defense.
  for (let i = 0; i < 105; i += 1) {
    inbox.ctx.storage.sql.exec(
      "INSERT INTO items (id, kind, payload, source, created_at) VALUES (?, 'create_document', '{}', 'claude', ?)",
      `bulk-${i}`, i
    );
  }
  assert.equal((await inbox.list()).length, 100);
});

test("acknowledge moves a pending item to imported and records when", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("ack-1", "create_document", {}, "claude");

  const before = Date.now();
  const result = await inbox.acknowledge("ack-1");
  assert.deepEqual(result, { id: "ack-1", status: "imported" });

  const [row] = inbox.ctx.storage.sql.exec("SELECT status, imported_at FROM items WHERE id = ?", "ack-1");
  assert.equal(row.status, "imported");
  assert.ok(row.imported_at >= before);
});

test("acknowledge on an id that doesn't exist reports status missing", async () => {
  const inbox = freshInbox();
  const result = await inbox.acknowledge("never-enqueued");
  assert.deepEqual(result, { id: "never-enqueued", status: "missing" });
});

test("acknowledge is a no-op the second time — an already-imported item's imported_at does not change", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("ack-2", "create_document", {}, "claude");
  await inbox.acknowledge("ack-2");
  const [firstRow] = inbox.ctx.storage.sql.exec("SELECT imported_at FROM items WHERE id = ?", "ack-2");

  await new Promise(resolve => setTimeout(resolve, 5));
  const second = await inbox.acknowledge("ack-2");
  assert.equal(second.status, "imported");

  const [secondRow] = inbox.ctx.storage.sql.exec("SELECT imported_at FROM items WHERE id = ?", "ack-2");
  assert.equal(secondRow.imported_at, firstRow.imported_at);
});

test("status returns null for an id that was never enqueued", async () => {
  const inbox = freshInbox();
  assert.equal(await inbox.status("nope"), null);
});

test("status reflects the current row for an id that exists", async () => {
  const inbox = freshInbox();
  await inbox.enqueue("st-1", "create_document", {}, "claude");
  const pending = await inbox.status("st-1");
  assert.equal(pending.status, "pending");
  assert.equal(pending.imported_at, null);

  await inbox.acknowledge("st-1");
  const imported = await inbox.status("st-1");
  assert.equal(imported.status, "imported");
  assert.ok(imported.imported_at);
});

test("consumeOnce returns true the first time and false on replay", async () => {
  const inbox = freshInbox();
  assert.equal(await inbox.consumeOnce("code-1"), true);
  assert.equal(await inbox.consumeOnce("code-1"), false);
  // A different id is unaffected by another id's consumption.
  assert.equal(await inbox.consumeOnce("code-2"), true);
});

test("consumeOnce's own cleanup lets an id be consumed again once its record is older than 90 days", async () => {
  const inbox = freshInbox();
  await inbox.consumeOnce("old-code");
  inbox.ctx.storage.sql.exec("UPDATE consumed_tokens SET used_at = ? WHERE id = ?", Date.now() - 91 * DAY_MS, "old-code");

  // Cleanup only runs as a side effect of the next consumeOnce call.
  await inbox.consumeOnce("unrelated-code");

  assert.equal(await inbox.consumeOnce("old-code"), true);
});
