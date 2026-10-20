import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import test from "node:test";
import worker from "./app.ts";
import { sealSnapshot, openSnapshot } from "./snapshot-crypto.ts";
import { partialCtx, partialEnv } from "./test-env.ts";

const newKey = () => randomBytes(32).toString("base64");
const hash = value => createHash("sha256").update(value).digest("hex");
const SNAPSHOT = JSON.stringify({ version: 1, notebooks: [{ id: "n", title: "秘密のノート", pages: [{ id: "p", title: "p", recognizedText: "ひみつの内容" }] }] });

test("a sealed snapshot does not contain its plaintext and opens back to the original", async () => {
  const env = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  const sealed = await sealSnapshot(env, "snapshot:a", SNAPSHOT);
  assert.match(sealed, /^enc1\.1\./);
  assert.ok(!sealed.includes("ひみつ") && !sealed.includes("recognizedText"));
  assert.equal(await openSnapshot(env, "snapshot:a", sealed), SNAPSHOT);
});

test("the same snapshot sealed twice gives different ciphertext (fresh IV each time)", async () => {
  const env = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  assert.notEqual(await sealSnapshot(env, "snapshot:a", SNAPSHOT), await sealSnapshot(env, "snapshot:a", SNAPSHOT));
});

test("a ciphertext moved to another key name does not open", async () => {
  const env = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  const sealed = await sealSnapshot(env, "snapshot:alice", SNAPSHOT);
  await assert.rejects(openSnapshot(env, "snapshot:bob", sealed));
});

test("a tampered ciphertext is rejected", async () => {
  const env = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  const sealed = await sealSnapshot(env, "snapshot:a", SNAPSHOT);
  // Form: "enc1.<key id>.<iv>.<ciphertext>". Change a character well inside the
  // ciphertext. The very last base64 character can carry bits that decoding
  // throws away, so changing only that one sometimes left the bytes the same and
  // the test passed or failed by chance.
  const ciphertextStart = sealed.lastIndexOf(".") + 1;
  const middle = ciphertextStart + Math.floor((sealed.length - ciphertextStart) / 2);
  const tampered = sealed.slice(0, middle) + (sealed[middle] === "A" ? "B" : "A") + sealed.slice(middle + 1);
  assert.notEqual(tampered, sealed);
  await assert.rejects(openSnapshot(env, "snapshot:a", tampered));
  // And a change near the end, inside the authentication tag, is caught as well.
  const nearEnd = sealed.length - 8;
  const tagTampered = sealed.slice(0, nearEnd) + (sealed[nearEnd] === "A" ? "B" : "A") + sealed.slice(nearEnd + 1);
  await assert.rejects(openSnapshot(env, "snapshot:a", tagTampered));
});

test("the wrong key does not open a sealed snapshot", async () => {
  const sealed = await sealSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() }), "snapshot:a", SNAPSHOT);
  await assert.rejects(openSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() }), "snapshot:a", sealed));
});

test("a plaintext snapshot written before encryption existed is still readable", async () => {
  assert.equal(await openSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() }), "snapshot:a", SNAPSHOT), SNAPSHOT);
  assert.equal(await openSnapshot(partialEnv({}), "snapshot:a", SNAPSHOT), SNAPSHOT);
});

test("with no key configured the snapshot is stored as is, unless encryption is required", async () => {
  assert.equal(await sealSnapshot(partialEnv({}), "snapshot:a", SNAPSHOT), SNAPSHOT);
  await assert.rejects(sealSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_REQUIRED: "true" }), "snapshot:a", SNAPSHOT));
});

test("a record written under the previous key still opens during a key rotation", async () => {
  const oldKey = newKey();
  const sealed = await sealSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_KEY: oldKey, SNAPSHOT_ENCRYPTION_KEY_ID: "1" }), "snapshot:a", SNAPSHOT);
  const rotated = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey(), SNAPSHOT_ENCRYPTION_KEY_ID: "2", SNAPSHOT_ENCRYPTION_KEY_OLD: oldKey, SNAPSHOT_ENCRYPTION_KEY_OLD_ID: "1" });
  assert.equal(await openSnapshot(rotated, "snapshot:a", sealed), SNAPSHOT);
  assert.match(await sealSnapshot(rotated, "snapshot:a", SNAPSHOT), /^enc1\.2\./);
});

test("a key of the wrong length is refused rather than used", async () => {
  await assert.rejects(sealSnapshot(partialEnv({ SNAPSHOT_ENCRYPTION_KEY: Buffer.alloc(16).toString("base64") }), "snapshot:a", SNAPSHOT));
});

test("an 8 MB snapshot seals and opens", async () => {
  const env = partialEnv({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  const big = JSON.stringify({ version: 1, notebooks: [], filler: "あ".repeat(2_600_000) });
  assert.equal(await openSnapshot(env, "snapshot:a", await sealSnapshot(env, "snapshot:a", big)), big);
});

// ---- Through the Worker -------------------------------------------------

const noopCtx = partialCtx({ waitUntil() {} });
const fetchApp = (env, path: string, options = {}) => worker.fetch(new Request(`https://example.test${path}`, options), env, noopCtx);

function environment(extra = {}) {
  const values = new Map();
  const ttls = new Map();
  return partialEnv({
    ttls,
    STUDIQUO_DATA: {
      async get(key, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value, options: { expirationTtl: any; }) { values.set(key, value); ttls.set(key, options?.expirationTtl); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) { return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })) }; },
    },
    raw: values,
    RATE_COUNTER: { getByName() { return { async bump() { return true; } }; } },
    ...extra,
  });
}

async function syncAs(env, token: string, sub: string) {
  await env.STUDIQUO_DATA.put(`session:${hash(token)}`, JSON.stringify({ sub }));
  return fetchApp(env, "/api/snapshot", {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: SNAPSHOT,
  });
}

async function listNotebooks(env, token: string) {
  const response = await fetchApp(env, "/mcp", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_notebooks", arguments: {} } }),
  });
  return response.json();
}

const deviceToken = `${Math.floor(Date.now() / 1000)}.${"e".repeat(64)}`;

test("a synced snapshot is stored encrypted in both copies, and MCP tools still read it", async () => {
  const env = environment({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  assert.equal((await syncAs(env, deviceToken, "student-enc")).status, 200);

  const snapshotKeys = [...env.raw.keys()].filter(key => key.startsWith("snapshot:"));
  assert.equal(snapshotKeys.length, 2);
  for (const key of snapshotKeys) {
    assert.ok(env.raw.get(key).startsWith("enc1."), key);
    assert.ok(!env.raw.get(key).includes("ひみつ"), key);
  }

  const result = await listNotebooks(env, deviceToken);
  assert.equal(result.result.isError, undefined);
  assert.match(JSON.stringify(result), /秘密のノート/);
});

test("the account-level copy expires 90 days after the last sync; the device copy still follows its session", async () => {
  const env = environment({ SNAPSHOT_ENCRYPTION_KEY: newKey() });
  await syncAs(env, deviceToken, "student-ttl");
  const accountKey = `snapshot:${hash("mcp-account:student-ttl")}`;
  assert.equal(env.ttls.get(accountKey), 90 * 24 * 60 * 60);
  const deviceTtl = env.ttls.get(`snapshot:${hash(deviceToken)}`);
  assert.ok(deviceTtl > 0 && deviceTtl <= 90 * 24 * 60 * 60);
});

test("with no key configured the sync still works and MCP tools read the plaintext snapshot", async () => {
  const env = environment();
  assert.equal((await syncAs(env, deviceToken, "student-plain")).status, 200);
  assert.match(JSON.stringify(await listNotebooks(env, deviceToken)), /秘密のノート/);
});

test("when encryption is required but no key is set, the sync fails and nothing is stored", async () => {
  const env = environment({ SNAPSHOT_ENCRYPTION_REQUIRED: "true" });
  assert.equal((await syncAs(env, deviceToken, "student-req")).status, 503);
  assert.equal([...env.raw.keys()].filter(key => key.startsWith("snapshot:")).length, 0);
});
