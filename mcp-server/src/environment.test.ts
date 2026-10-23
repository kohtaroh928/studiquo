import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

test("every rate limit in wrangler.jsonc has its own namespace_id within an environment", () => {
  const config = readFileSync(join(import.meta.dirname, "..", "wrangler.jsonc"), "utf8");
  const [production, staging] = config.split(/"staging"\s*:\s*\{/);
  for (const part of [production, staging]) {
    const ids = [...part.matchAll(/"namespace_id"\s*:\s*"(\d+)"/g)].map(match => match[1]);
    assert.ok(ids.length > 20);
    assert.equal(new Set(ids).size, ids.length, "a shared id would share one counter between two limits");
  }
});
