import test from "node:test";
import assert from "node:assert/strict";
import { nextCursor } from "./kv.ts";
import type { Untyped } from "./test-env.ts";

// A list page as Workers KV returns it. Only the fields nextCursor reads matter.
const page = (fields: Record<string, unknown>) => ({ keys: [], ...fields }) as unknown as KVNamespaceListResult<unknown>;

test("a finished listing has no next cursor", () => {
  assert.equal(nextCursor(page({ list_complete: true })), undefined);
});

test("an unfinished listing hands back its cursor", () => {
  assert.equal(nextCursor(page({ list_complete: false, cursor: "next-page" })), "next-page");
});

test("a finished listing is finished even if a cursor is still attached", () => {
  assert.equal(nextCursor(page({ list_complete: true, cursor: "stale" })), undefined);
});

test("an unfinished page without a cursor ends the listing instead of looping", () => {
  assert.equal(nextCursor(page({ list_complete: false })), undefined);
});
