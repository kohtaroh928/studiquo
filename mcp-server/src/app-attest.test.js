import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import test from "node:test";
import {
  appAttestGate, appAttestMode, assessAssertion, base64ToBytes, bytesToBase64Url, challengeIsValid, decodeCBOR,
  derSignatureToRaw, handleAppAttest, issueChallenge, verifyAssertion, verifyAttestation,
} from "./app-attest.ts";

const APP_ID = "TEAMID1234.com.example.app";
const NOW = Date.UTC(2026, 9, 18, 12, 0, 0);

// --- a tiny DER / CBOR writer, to build the objects Apple would send ---------

function der(tag, ...parts) {
  const body = Buffer.concat(parts);
  const length = body.length < 128 ? Buffer.from([body.length])
    : body.length < 256 ? Buffer.from([0x81, body.length]) : Buffer.from([0x82, body.length >> 8, body.length & 255]);
  return Buffer.concat([Buffer.from([tag]), length, body]);
}
const seq = (...p) => der(0x30, ...p);
const oid = dotted => {
  const nums = dotted.split(".").map(Number);
  const bytes = [nums[0] * 40 + nums[1]];
  for (const n of nums.slice(2)) {
    const chunk = [n & 0x7f];
    for (let v = n >> 7; v > 0; v >>= 7) chunk.unshift((v & 0x7f) | 0x80);
    bytes.push(...chunk);
  }
  return der(0x06, Buffer.from(bytes));
};
const name = cn => seq(der(0x31, seq(oid("2.5.4.3"), der(0x0c, Buffer.from(cn)))));
const utc = ms => der(0x17, Buffer.from(new Date(ms).toISOString().replace(/[-:T]/g, "").slice(2, 14) + "Z"));

function certificate({ subject, issuer, key, signer, hash, extensions = [], notBefore = NOW - 86_400_000, notAfter = NOW + 86_400_000 }) {
  const algorithm = seq(oid(hash === "sha384" ? "1.2.840.10045.4.3.3" : "1.2.840.10045.4.3.2"));
  const tbs = seq(
    der(0xa0, der(0x02, Buffer.from([2]))), der(0x02, Buffer.from([1])), algorithm,
    name(issuer), seq(utc(notBefore), utc(notAfter)), name(subject), key.export({ type: "spki", format: "der" }),
    ...(extensions.length ? [der(0xa3, seq(...extensions))] : []),
  );
  return seq(tbs, algorithm, der(0x03, Buffer.concat([Buffer.from([0]), sign(hash, tbs, signer)])));
}

const cbor = {
  uint: n => (n < 24 ? Buffer.from([n]) : Buffer.from([0x18, n])),
  bytes: b => Buffer.concat([b.length < 24 ? Buffer.from([0x40 + b.length]) : b.length < 256 ? Buffer.from([0x58, b.length]) : Buffer.from([0x59, b.length >> 8, b.length & 255]), b]),
  text: t => Buffer.concat([Buffer.from([0x60 + t.length]), Buffer.from(t)]),
  array: items => Buffer.concat([Buffer.from([0x80 + items.length]), ...items]),
  map: entries => Buffer.concat([Buffer.from([0xa0 + entries.length]), ...entries.flatMap(([k, v]) => [cbor.text(k), v])]),
};

const sha = (...parts) => createHash("sha256").update(Buffer.concat(parts)).digest();
const p256 = () => generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const p384 = () => generateKeyPairSync("ec", { namedCurve: "secp384r1" });
const pointOf = publicKey => publicKey.export({ type: "spki", format: "der" }).subarray(-65);

function makeWorld({ appId = APP_ID, aaguid = "appattest\0\0\0\0\0\0\0", counter = 0, notAfter } = {}) {
  const root = p384();
  const intermediate = p384();
  const device = p256();
  const rootCert = certificate({ subject: "Fake Root", issuer: "Fake Root", key: root.publicKey, signer: root.privateKey, hash: "sha384" });
  const intermediateCert = certificate({ subject: "Fake Intermediate", issuer: "Fake Root", key: intermediate.publicKey, signer: root.privateKey, hash: "sha384" });
  const keyHash = sha(pointOf(device.publicKey));
  const attest = challenge => {
    const authData = Buffer.concat([
      sha(Buffer.from(appId)), Buffer.from([0x40]), Buffer.from([0, 0, 0, counter]), Buffer.from(aaguid),
      Buffer.from([0, 32]), keyHash, Buffer.from([0xa1, 0x01, 0x02]),
    ]);
    const nonce = sha(authData, sha(Buffer.from(challenge)));
    const leafCert = certificate({
      subject: "Fake Leaf", issuer: "Fake Intermediate", key: device.publicKey, signer: intermediate.privateKey, hash: "sha256", notAfter,
      extensions: [seq(oid("1.2.840.113635.100.8.2"), der(0x04, seq(der(0xa1, der(0x04, nonce)))))],
    });
    return cbor.map([
      ["fmt", cbor.text("apple-appattest")],
      ["attStmt", cbor.map([["x5c", cbor.array([cbor.bytes(leafCert), cbor.bytes(intermediateCert)])], ["receipt", cbor.bytes(Buffer.from("r"))]])],
      ["authData", cbor.bytes(authData)],
    ]);
  };
  const assert_ = (clientData, assertionCounter, appIdForAssertion = appId, signingKey = device.privateKey) => {
    const authenticatorData = Buffer.concat([sha(Buffer.from(appIdForAssertion)), Buffer.from([0]), Buffer.from([0, 0, 0, assertionCounter])]);
    const signature = sign("sha256", sha(authenticatorData, sha(Buffer.from(clientData))), signingKey);
    return cbor.map([["signature", cbor.bytes(signature)], ["authenticatorData", cbor.bytes(authenticatorData)]]);
  };
  return { rootDer: rootCert, keyId: bytesToBase64Url(keyHash), keyIdStd: keyHash.toString("base64"), publicKey: bytesToBase64Url(pointOf(device.publicKey)), attest, assertion: assert_, device };
}

// RateCounter's App Attest methods, in memory.
function fakeEnv(extra = {}) {
  const records = new Map();
  const objects = new Map();
  return {
    TOKEN_SIGNING_KEY: randomBytes(32).toString("base64"),
    APP_ATTEST_APP_ID: APP_ID,
    APP_ATTEST_MODE: "log",
    RATE_COUNTER: {
      getByName(name) {
        if (!objects.has(name)) {
          objects.set(name, {
            async attestRegister(record) { if (records.has(name)) return false; records.set(name, record); return true; },
            async attestKey() { return records.get(name) ?? null; },
            async attestAdvance(counter) {
              const record = records.get(name);
              if (!record || counter <= record.counter) return false;
              records.set(name, { ...record, counter });
              return true;
            },
          });
        }
        return objects.get(name);
      },
    },
    ...extra,
  };
}

async function failure(promise) {
  try { await promise; } catch (error) { return error.message; }
  return null;
}

// --- tests ----------------------------------------------------------------------

test("CBOR decodes maps, arrays, bytes, text and integers, and rejects trailing bytes", () => {
  const value = decodeCBOR(cbor.map([["a", cbor.uint(5)], ["b", cbor.array([cbor.text("x"), cbor.bytes(Buffer.from([1, 2]))])]]));
  assert.equal(value.a, 5);
  assert.equal(value.b[0], "x");
  assert.deepEqual([...value.b[1]], [1, 2]);
  assert.throws(() => decodeCBOR(Buffer.concat([cbor.uint(1), Buffer.from([0])])));
  assert.throws(() => decodeCBOR(Buffer.from([0xa1, 0x01, 0x01])), /non-text key/);
});

test("a genuine attestation is accepted and yields the key", async () => {
  const world = makeWorld();
  const result = await verifyAttestation({ attestation: world.attest("chal"), challenge: "chal", keyId: world.keyIdStd, appId: APP_ID, now: NOW, rootDer: world.rootDer });
  assert.equal(result.keyId, world.keyId);
  assert.equal(result.publicKey, world.publicKey);
});

test("an attestation is refused for each thing that is wrong with it", async () => {
  const world = makeWorld();
  const base = { attestation: world.attest("chal"), challenge: "chal", keyId: world.keyIdStd, appId: APP_ID, now: NOW, rootDer: world.rootDer };
  assert.equal(await failure(verifyAttestation({ ...base, challenge: "other" })), "nonce");
  assert.equal(await failure(verifyAttestation({ ...base, appId: "TEAMID1234.com.example.other" })), "app id");
  assert.equal(await failure(verifyAttestation({ ...base, keyId: bytesToBase64Url(randomBytes(32)) })), "key id");
  assert.equal(await failure(verifyAttestation({ ...base, rootDer: makeWorld().rootDer })), "chain");
  assert.equal(await failure(verifyAttestation({ ...base, now: NOW + 3 * 86_400_000 })), "chain");
  assert.equal(await failure(verifyAttestation({ ...base, attestation: Buffer.from([0xa0]) })), "format");
  assert.ok(await failure(verifyAttestation({ ...base, attestation: randomBytes(40) })));
  const used = makeWorld({ counter: 1 });
  assert.equal(await failure(verifyAttestation({ ...base, attestation: used.attest("chal"), keyId: used.keyIdStd, rootDer: used.rootDer })), "counter");
});

test("development-environment keys are accepted only when allowed", async () => {
  const world = makeWorld({ aaguid: "appattestdevelop" });
  const base = { attestation: world.attest("chal"), challenge: "chal", keyId: world.keyIdStd, appId: APP_ID, now: NOW, rootDer: world.rootDer };
  assert.equal(await failure(verifyAttestation(base)), "environment");
  assert.equal(await failure(verifyAttestation({ ...base, allowDevelop: true })), null);
});

test("an assertion verifies once and not again with the same counter", async () => {
  const world = makeWorld();
  const clientData = "POST\n/api/ai/chat\n123456789012";
  const assertion = world.assertion(clientData, 1);
  const args = { assertion, clientData, publicKey: world.publicKey, storedCounter: 0, appId: APP_ID };
  assert.equal(await verifyAssertion(args), 1);
  assert.equal(await failure(verifyAssertion({ ...args, storedCounter: 1 })), "replay");
  assert.equal(await failure(verifyAssertion({ ...args, clientData: "POST\n/api/ai/grade\n123456789012" })), "signature");
  assert.equal(await failure(verifyAssertion({ ...args, assertion: world.assertion(clientData, 1, "TEAMID1234.com.example.other") })), "app id");
  assert.equal(await failure(verifyAssertion({ ...args, assertion: world.assertion(clientData, 1, APP_ID, p256().privateKey) })), "signature");
});

test("DER signatures convert to fixed-size r||s, padding short values", () => {
  const raw = derSignatureToRaw(Buffer.from([0x30, 0x06, 0x02, 0x01, 0x05, 0x02, 0x01, 0x07]), 4);
  assert.deepEqual([...raw], [0, 0, 0, 5, 0, 0, 0, 7]);
});

test("a challenge is valid for five minutes, once signed by this Worker", async () => {
  const env = fakeEnv();
  const challenge = await issueChallenge(env, NOW);
  assert.equal(await challengeIsValid(env, challenge, NOW + 60_000), true);
  assert.equal(await challengeIsValid(env, challenge, NOW + 6 * 60_000), false);
  assert.equal(await challengeIsValid(env, challenge.slice(0, -1) + (challenge.endsWith("A") ? "B" : "A"), NOW), false);
  assert.equal(await challengeIsValid(fakeEnv(), challenge, NOW), false);
  assert.equal(await challengeIsValid(env, "nope", NOW), false);
});

test("the mode is off unless fully configured", () => {
  assert.equal(appAttestMode(fakeEnv()), "log");
  assert.equal(appAttestMode(fakeEnv({ APP_ATTEST_MODE: "enforce" })), "enforce");
  assert.equal(appAttestMode(fakeEnv({ APP_ATTEST_MODE: "off" })), "off");
  assert.equal(appAttestMode(fakeEnv({ APP_ATTEST_MODE: "yes" })), "off");
  assert.equal(appAttestMode(fakeEnv({ APP_ATTEST_APP_ID: "" })), "off");
  assert.equal(appAttestMode(fakeEnv({ TOKEN_SIGNING_KEY: undefined })), "off");
});

function post(path, body, headers = {}) {
  return new Request(`https://example.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
}

async function register(env, world, overrides = {}) {
  const challenge = (await (await handleAppAttest(new URL("https://example.test/api/attest/challenge"), post("/api/attest/challenge"), env, { now: NOW })).json()).challenge;
  const body = { keyId: world.keyIdStd, attestation: world.attest(challenge).toString("base64"), challenge, ...overrides };
  return handleAppAttest(new URL("https://example.test/api/attest/register"), post("/api/attest/register", body), env, { now: NOW, rootDer: world.rootDer });
}

test("the attest routes answer 404 when the mode is off and ignore other routes", async () => {
  const env = fakeEnv({ APP_ATTEST_MODE: "off" });
  assert.equal((await handleAppAttest(new URL("https://example.test/api/attest/challenge"), post("/api/attest/challenge"), env)).status, 404);
  assert.equal(await handleAppAttest(new URL("https://example.test/api/other"), post("/api/other"), env), null);
  assert.equal(await handleAppAttest(new URL("https://example.test/api/attest/challenge"), new Request("https://example.test/api/attest/challenge"), env), null);
});

test("registering a key works once, then the key is refused as already registered", async () => {
  const env = fakeEnv();
  const world = makeWorld();
  assert.equal((await register(env, world)).status, 201);
  const again = await register(env, world);
  assert.equal(again.status, 409);
  assert.equal((await again.json()).code, "attest_key_exists");
});

test("registration refuses a bad challenge, a malformed body, and an attestation that does not verify", async () => {
  const env = fakeEnv();
  const world = makeWorld();
  const route = (body, rootDer) => handleAppAttest(new URL("https://example.test/api/attest/register"), post("/api/attest/register", body), env, { now: NOW, rootDer });
  assert.equal((await route({ keyId: world.keyIdStd, attestation: "AAAA", challenge: "bad" }, world.rootDer)).status, 400);
  assert.equal((await route({ keyId: "x" }, world.rootDer)).status, 400);
  const challenge = await issueChallenge(env, NOW);
  const untrusted = await route({ keyId: world.keyIdStd, attestation: world.attest(challenge).toString("base64"), challenge }, makeWorld().rootDer);
  assert.equal(untrusted.status, 400);
  assert.equal((await untrusted.json()).code, "attest_rejected");
});

test("the rate limit on the attest routes answers 429", async () => {
  const env = fakeEnv({ RATE_LIMIT_ATTEST_CHALLENGE: { limit: async () => ({ success: false }) } });
  assert.equal((await handleAppAttest(new URL("https://example.test/api/attest/challenge"), post("/api/attest/challenge"), env)).status, 429);
});

async function signedRequest(world, env, path, counter, { method = "POST", timestamp = NOW } = {}) {
  const header = `${world.keyId}.${timestamp}.${bytesToBase64Url(world.assertion(`${method}\n${path}\n${timestamp}`, counter))}`;
  return new Request(`https://example.test${path}`, { method, headers: { "x-studiquo-attest": header } });
}

test("a registered key's assertions are accepted, once each", async () => {
  const env = fakeEnv();
  const world = makeWorld();
  await register(env, world);
  const first = await signedRequest(world, env, "/api/ai/chat", 1);
  assert.equal(await assessAssertion(first, env, new URL(first.url), NOW), "ok");
  assert.equal(await assessAssertion(first, env, new URL(first.url), NOW), "replay");
  const second = await signedRequest(world, env, "/api/ai/chat", 2);
  assert.equal(await assessAssertion(second, env, new URL(second.url), NOW), "ok");
  const jumped = await signedRequest(world, env, "/api/auth/local/login", 9);
  assert.equal(await assessAssertion(jumped, env, new URL(jumped.url), NOW), "ok");
});

test("assertions are judged absent, malformed, stale, unknown or invalid", async () => {
  const env = fakeEnv();
  const world = makeWorld();
  await register(env, world);
  const judge = async request => assessAssertion(request, env, new URL(request.url), NOW);
  assert.equal(await judge(new Request("https://example.test/api/ai/chat", { method: "POST" })), "absent");
  assert.equal(await judge(new Request("https://example.test/api/ai/chat", { method: "POST", headers: { "x-studiquo-attest": "junk" } })), "malformed");
  assert.equal(await judge(await signedRequest(world, env, "/api/ai/chat", 1, { timestamp: NOW - 10 * 60_000 })), "stale");
  assert.equal(await judge(await signedRequest(makeWorld(), env, "/api/ai/chat", 1)), "unknown_key");
  // Signed for another path than the one requested.
  const other = await signedRequest(world, env, "/api/ai/grade", 1);
  const moved = new Request("https://example.test/api/ai/chat", { method: "POST", headers: other.headers });
  assert.equal(await judge(moved), "invalid");
});

test("log mode never refuses and writes one line saying how the request fared", async () => {
  const env = fakeEnv();
  const lines = [];
  const original = console.log;
  console.log = line => lines.push(line);
  try {
    const request = new Request("https://example.test/api/ai/chat", { method: "POST" });
    assert.equal(await appAttestGate(request, env, new URL(request.url), NOW), null);
  } finally { console.log = original; }
  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), { message: "app attest", mode: "log", result: "absent", route: "ai" });
});

test("enforce mode refuses every protected request without a valid assertion", async () => {
  const env = fakeEnv({ APP_ATTEST_MODE: "enforce" });
  const world = makeWorld();
  await register(env, world);
  const original = console.log;
  console.log = () => {};
  try {
    for (const path of ["/api/ai/chat", "/api/ai/review", "/api/auth/apple", "/api/auth/google", "/api/auth/email/send-code", "/api/auth/email/confirm-code", "/api/auth/local/login"]) {
      const bare = new Request(`https://example.test${path}`, { method: "POST" });
      const refused = await appAttestGate(bare, env, new URL(bare.url), NOW);
      assert.equal(refused.status, 403, path);
      assert.equal((await refused.json()).code, "app_attest_required");
    }
    const good = await signedRequest(world, env, "/api/ai/chat", 1);
    assert.equal(await appAttestGate(good, env, new URL(good.url), NOW), null);
    assert.equal((await appAttestGate(good, env, new URL(good.url), NOW)).status, 403);
  } finally { console.log = original; }
});

test("reads, other routes and an off mode are never checked", async () => {
  const original = console.log;
  console.log = () => {};
  try {
    const enforce = fakeEnv({ APP_ATTEST_MODE: "enforce" });
    for (const [method, path] of [["GET", "/api/ai/usage"], ["POST", "/api/snapshot"], ["POST", "/api/session/refresh"], ["POST", "/api/attest/register"]]) {
      const request = new Request(`https://example.test${path}`, { method });
      assert.equal(await appAttestGate(request, enforce, new URL(request.url), NOW), null, `${method} ${path}`);
    }
    const off = fakeEnv({ APP_ATTEST_MODE: "off" });
    const request = new Request("https://example.test/api/ai/chat", { method: "POST" });
    assert.equal(await appAttestGate(request, off, new URL(request.url), NOW), null);
  } finally { console.log = original; }
});

test("base64 helpers round-trip and reject garbage", () => {
  const bytes = randomBytes(33);
  assert.deepEqual([...base64ToBytes(bytesToBase64Url(bytes))], [...bytes]);
  assert.deepEqual([...base64ToBytes(Buffer.from(bytes).toString("base64"))], [...bytes]);
  assert.throws(() => base64ToBytes("not base64!"));
});

test("the embedded Apple root parses and is self-signed, valid to 2045", async () => {
  const pem = (await import("node:fs")).readFileSync(new URL("./app-attest.ts", import.meta.url), "utf8");
  const base64 = /APPLE_ROOT_DER_BASE64 = "([^"]+)"/.exec(pem)[1];
  assert.equal(createHash("sha256").update(Buffer.from(base64, "base64")).digest("hex").toUpperCase(),
    "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932");
  const { parseCertificate } = await import("./app-attest.ts");
  const root = parseCertificate(base64ToBytes(base64));
  assert.equal(root.curve.name, "P-384");
  assert.equal(root.notAfter, Date.UTC(2045, 2, 15));
  assert.deepEqual([...root.issuer], [...root.subject]);
});

test("a throttled address, a non-canonical key id and a broken signing key are handled", async () => {
  const world = makeWorld();
  const env = fakeEnv({ RATE_LIMIT_ATTEST_ASSERT: { limit: async () => ({ success: false }) } });
  await register(env, world);
  const request = await signedRequest(world, env, "/api/ai/chat", 1);
  assert.equal(await assessAssertion(request, env, new URL(request.url), NOW), "throttled");

  const open = fakeEnv();
  await register(open, world);
  const header = (await signedRequest(world, open, "/api/ai/chat", 1)).headers.get("x-studiquo-attest");
  const last = world.keyId.at(-1);
  const alias = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const twin = alias[(alias.indexOf(last) + 1) % 64];
  const forged = new Request("https://example.test/api/ai/chat", { method: "POST", headers: { "x-studiquo-attest": header.replace(world.keyId, world.keyId.slice(0, -1) + twin) } });
  assert.equal(await assessAssertion(forged, open, new URL(forged.url), NOW), "malformed");

  assert.equal(appAttestMode(fakeEnv({ TOKEN_SIGNING_KEY: "c2hvcnQ=" })), "off");
  assert.equal(appAttestMode(fakeEnv({ TOKEN_SIGNING_KEY: "!!!" })), "off");
});

test("enforce answers 503 when storage fails, and says why a request was refused", async () => {
  const original = console.log;
  console.log = () => {};
  try {
    const broken = fakeEnv({ APP_ATTEST_MODE: "enforce" });
    const world = makeWorld();
    await register(broken, world);
    const good = await signedRequest(world, broken, "/api/ai/chat", 1);
    broken.RATE_COUNTER.getByName = () => ({ attestKey: async () => { throw new Error("down"); } });
    const unavailable = await appAttestGate(good, broken, new URL(good.url), NOW);
    assert.equal(unavailable.status, 503);
    const bare = new Request("https://example.test/api/passkeys/login/verify", { method: "POST" });
    const refused = await appAttestGate(bare, fakeEnv({ APP_ATTEST_MODE: "enforce" }), new URL(bare.url), NOW);
    assert.equal(refused.status, 403);
    assert.equal((await refused.json()).reason, "absent");
  } finally { console.log = original; }
});
