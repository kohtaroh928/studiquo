// @ts-nocheck 型の付け方は docs/notes/ts-migration.md の「テストの型検査」を参照。
import assert from "node:assert/strict";
import test from "node:test";
import { eraseLibraryID, getOrCreateLibraryID, libraryIdObjectName, newLibraryID } from "./library-id.ts";

function fakeContext() {
  const values = new Map();
  // blockConcurrencyWhile lets one piece of work run at a time, as a Durable
  // Object does.
  let turn = Promise.resolve();
  return {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
    blockConcurrencyWhile(work) {
      const run = turn.then(work);
      turn = run.catch(() => {});
      return run;
    },
  };
}

test("an id is 64 lowercase hex characters, and a new one is different each time", () => {
  const ids = new Set(Array.from({ length: 50 }, newLibraryID));
  assert.equal(ids.size, 50);
  for (const id of ids) assert.match(id, /^[a-f0-9]{64}$/);
});

test("the first request makes the id and every later one gets the same", async () => {
  const ctx = fakeContext();
  const first = await getOrCreateLibraryID(ctx);
  assert.equal(await getOrCreateLibraryID(ctx), first);
  assert.equal(await ctx.storage.get("libraryID"), first);
});

test("once erased, the next request makes a different id", async () => {
  const ctx = fakeContext();
  const first = await getOrCreateLibraryID(ctx);
  await eraseLibraryID(ctx);
  assert.equal(await ctx.storage.get("libraryID"), undefined);
  assert.notEqual(await getOrCreateLibraryID(ctx), first);
});

test("the object is named for the account without revealing it, and apart from the chat objects", () => {
  const name = libraryIdObjectName("a".repeat(64));
  assert.equal(name, `library-id:${"a".repeat(64)}`);
  assert.ok(!name.includes("@"));
});

test("several first requests at once all get the same id", async () => {
  const ctx = fakeContext();
  const ids = await Promise.all(Array.from({ length: 20 }, () => getOrCreateLibraryID(ctx)));
  assert.equal(new Set(ids).size, 1);
});
