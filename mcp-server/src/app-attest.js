// App Attest: proof that a request comes from a genuine copy of the Studiquo app
// on a genuine Apple device, not from a script. It guards what costs money or can
// be hammered with no account: the AI proxy and the sign-in / sign-up routes.
//
// How it works (Apple: "Validating apps that connect to your server"):
//   1. The app asks for a challenge (POST /api/attest/challenge). The Worker
//      returns a signed, short-lived one; nothing is stored.
//   2. The app makes a key in the Secure Enclave and has Apple attest it, with
//      the challenge folded in. It sends the result (POST /api/attest/register).
//      The Worker checks the certificate chain up to Apple's App Attest root, the
//      nonce, the app id, and that the key id is the hash of the attested key;
//      then keeps the key's public half and a counter, per key, in a RateCounter
//      object. A key can be registered once.
//   3. From then on each protected request carries an assertion, signed by that
//      key, over "METHOD\npath\ntimestamp" (header x-studiquo-attest:
//      "<key id>.<timestamp ms>.<assertion>", all base64url). The Worker checks
//      the signature, that the timestamp is recent, and that the counter has gone
//      up (so a copied assertion cannot be sent again).
//
// APP_ATTEST_MODE (unset = "off"):
//   off      nothing is checked and the two attest routes answer 404.
//   log      every protected request that is not a read is checked and ONE log line
//            says how it fared; nothing is refused. This is how the rollout is
//            watched: "absent" means a build without App Attest is still in use.
//   enforce  a protected request without a valid assertion answers 403
//            "app_attest_required" (with a `reason`: absent, malformed, stale,
//            throttled, unknown_key, replay, invalid; "unknown_key" means the app
//            should register again). Our own storage failing answers 503. Turn on
//            only once "absent" and "replay" have died out in the log.
//            The app must make one assertion per request send (a retry needs a
//            fresh one) and make them one at a time: the counter must rise.
// APP_ATTEST_APP_ID is "<team id>.<bundle id>". APP_ATTEST_ALLOW_DEVELOP=true also
// accepts keys attested by Apple's development environment (staging only).
// The challenge is signed with TOKEN_SIGNING_KEY; without it, or without the app
// id, the mode stays off.
//
// Not covered: an assertion binds the method, the path and the time, not the
// body. It proves WHO is calling, not that the body was not altered on the way
// (TLS does that).
import { json, readJSONLimited } from "./http.ts";
import { checkRateLimit, clientKey } from "./rate-limit.ts";

const encoder = new TextEncoder();

// Apple App Attestation Root CA (valid to 2045-03-15), from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
const APPLE_ROOT_DER_BASE64 = "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD";

const CHALLENGE_LABEL = "studiquo-app-attest-challenge-v1:";
const CHALLENGE_MAX_AGE_MS = 5 * 60_000;
const ASSERTION_MAX_SKEW_MS = 5 * 60_000;
const MAX_REGISTER_BODY = 20_000;
const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";
const AAGUID_PRODUCTION = "appattest\0\0\0\0\0\0\0";
const AAGUID_DEVELOP = "appattestdevelop";
const KEY_ID_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export const ATTEST_PROTECTED_PATHS = new Set([
  "/api/auth/apple", "/api/auth/google", "/api/auth/email/send-code",
  "/api/auth/email/confirm-code", "/api/auth/local/login",
  "/api/passkeys/login/options", "/api/passkeys/login/verify",
]);

// --- encoding helpers --------------------------------------------------------

export function bytesToBase64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function base64ToBytes(value) {
  const normalized = String(value).replaceAll("-", "+").replaceAll("_", "/");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(normalized)) throw new Error("bad base64");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0));
}

async function sha256(...parts) {
  const joined = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) { joined.set(part, offset); offset += part.length; }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", joined));
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// --- CBOR (just enough for Apple's attestation and assertion objects) --------

export function decodeCBOR(bytes) {
  let offset = 0;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const take = length => {
    if (length < 0 || offset + length > bytes.length) throw new Error("cbor: truncated");
    const slice = bytes.subarray(offset, offset + length);
    offset += length;
    return slice;
  };
  const argument = info => {
    if (info < 24) return info;
    if (info === 24) return take(1)[0];
    if (info === 25) { take(2); return view.getUint16(offset - 2); }
    if (info === 26) { take(4); return view.getUint32(offset - 4); }
    throw new Error("cbor: unsupported length");
  };
  const read = depth => {
    if (depth > 8) throw new Error("cbor: too deep");
    const initial = take(1)[0];
    const major = initial >> 5;
    const info = initial & 31;
    switch (major) {
      case 0: return argument(info);
      case 1: return -1 - argument(info);
      case 2: return take(argument(info)).slice();
      case 3: return new TextDecoder("utf-8", { fatal: true }).decode(take(argument(info)));
      case 4: {
        const count = argument(info);
        if (count > bytes.length) throw new Error("cbor: bad count");
        return Array.from({ length: count }, () => read(depth + 1));
      }
      case 5: {
        const count = argument(info);
        if (count > bytes.length) throw new Error("cbor: bad count");
        const map = {};
        for (let i = 0; i < count; i++) {
          const key = read(depth + 1);
          if (typeof key !== "string") throw new Error("cbor: non-text key");
          map[key] = read(depth + 1);
        }
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new Error("cbor: unsupported simple value");
      default: throw new Error("cbor: unsupported type");
    }
  };
  const value = read(0);
  if (offset !== bytes.length) throw new Error("cbor: trailing bytes");
  return value;
}

// --- DER / X.509 (just enough to check Apple's chain) ------------------------

// A node is { tag, start, end, raw } over the one buffer it was read from.
function readTLV(bytes, offset) {
  if (offset + 2 > bytes.length) throw new Error("der: truncated");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count < 1 || count > 3 || start + count > bytes.length) throw new Error("der: bad length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[start + i];
    start += count;
  }
  const end = start + length;
  if (end > bytes.length) throw new Error("der: truncated");
  return { tag, start, end, raw: bytes.subarray(offset, end), content: bytes.subarray(start, end) };
}

function childrenOf(bytes, node) {
  const out = [];
  let offset = node.start;
  while (offset < node.end) {
    const child = readTLV(bytes, offset);
    out.push(child);
    offset = child.end;
  }
  if (offset !== node.end) throw new Error("der: bad nesting");
  return out;
}

function oidString(content) {
  const parts = [];
  let value = 0;
  for (const byte of content) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) { parts.push(value); value = 0; }
  }
  const first = parts.shift();
  return [Math.min(Math.floor(first / 40), 2), first - 40 * Math.min(Math.floor(first / 40), 2), ...parts].join(".");
}

function parseTime(node) {
  const text = new TextDecoder().decode(node.content);
  const match = node.tag === 0x17
    ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
    : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
  if (!match || (node.tag !== 0x17 && node.tag !== 0x18)) throw new Error("der: bad time");
  let year = Number(match[1]);
  if (node.tag === 0x17) year += year >= 50 ? 1900 : 2000;
  return Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
}

const SIGNATURE_ALGORITHMS = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
};
const CURVES = { "1.2.840.10045.3.1.7": { name: "P-256", size: 32 }, "1.3.132.0.34": { name: "P-384", size: 48 } };

export function parseCertificate(der) {
  const cert = readTLV(der, 0);
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new Error("x509: bad certificate");
  const [tbs, algorithm, signature] = childrenOf(der, cert);
  if (tbs?.tag !== 0x30 || algorithm?.tag !== 0x30 || signature?.tag !== 0x03) throw new Error("x509: bad certificate");
  const fields = childrenOf(der, tbs);
  let index = fields[0].tag === 0xa0 ? 1 : 0;
  const issuer = fields[index + 2];
  const validity = childrenOf(der, fields[index + 3]);
  const subject = fields[index + 4];
  const spki = fields[index + 5];
  if (!issuer || !validity[1] || !subject || !spki || spki.tag !== 0x30) throw new Error("x509: bad certificate");
  const algorithmOid = oidString(childrenOf(der, algorithm)[0].content);
  const spkiParts = childrenOf(der, spki);
  const curveOid = oidString(childrenOf(der, spkiParts[0])[1].content);
  const keyBits = spkiParts[1].content;
  const extensions = {};
  const extensionList = fields.find(field => field.tag === 0xa3);
  if (extensionList) {
    for (const extension of childrenOf(der, childrenOf(der, extensionList)[0])) {
      const parts = childrenOf(der, extension);
      extensions[oidString(parts[0].content)] = parts[parts.length - 1].content;
    }
  }
  return {
    der,
    tbs: tbs.raw,
    issuer: issuer.raw,
    subject: subject.raw,
    notBefore: parseTime(validity[0]),
    notAfter: parseTime(validity[1]),
    signatureAlgorithm: SIGNATURE_ALGORITHMS[algorithmOid],
    signature: signature.content.subarray(1),
    spki: spki.raw,
    curve: CURVES[curveOid],
    point: keyBits.subarray(1),
    extensions,
  };
}

// An ECDSA signature in DER ("SEQUENCE { INTEGER r, INTEGER s }") as the fixed-size
// r||s that WebCrypto wants.
export function derSignatureToRaw(der, size) {
  const sequence = readTLV(der, 0);
  const [r, s] = childrenOf(der, sequence);
  if (sequence.tag !== 0x30 || r?.tag !== 0x02 || s?.tag !== 0x02) throw new Error("bad signature");
  const fit = integer => {
    let value = integer.content;
    while (value.length > size && value[0] === 0) value = value.subarray(1);
    if (value.length > size) throw new Error("bad signature");
    const out = new Uint8Array(size);
    out.set(value, size - value.length);
    return out;
  };
  const raw = new Uint8Array(size * 2);
  raw.set(fit(r), 0);
  raw.set(fit(s), size);
  return raw;
}

async function certificateSignedBy(cert, issuer) {
  if (!cert.signatureAlgorithm || !issuer.curve) return false;
  const key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: issuer.curve.name }, false, ["verify"]);
  const signature = derSignatureToRaw(cert.signature, issuer.curve.size);
  return crypto.subtle.verify({ name: "ECDSA", hash: cert.signatureAlgorithm }, key, signature, cert.tbs);
}

async function verifyChain(leaf, intermediate, root, now) {
  for (const cert of [leaf, intermediate, root]) {
    if (now < cert.notBefore || now > cert.notAfter) return false;
  }
  if (!bytesEqual(leaf.issuer, intermediate.subject) || !bytesEqual(intermediate.issuer, root.subject)) return false;
  return (await certificateSignedBy(leaf, intermediate)) && (await certificateSignedBy(intermediate, root));
}

// --- attestation and assertion -----------------------------------------------

function parseAuthData(authData) {
  if (authData.length < 37) throw new Error("authData too short");
  return {
    rpIdHash: authData.subarray(0, 32),
    counter: new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0),
  };
}

/**
 * Checks an attestation object. Returns { keyId, publicKey } (the key id as
 * base64url, the key as the 65-byte uncompressed point, base64url), or throws
 * with the step that failed. `rootDer` is only overridden by tests.
 */
export async function verifyAttestation({ attestation, challenge, keyId, appId, allowDevelop = false, now = Date.now(), rootDer }) {
  const object = decodeCBOR(attestation);
  if (object.fmt !== "apple-appattest") throw new Error("format");
  const x5c = object.attStmt?.x5c;
  const authData = object.authData;
  if (!Array.isArray(x5c) || x5c.length !== 2 || !(authData instanceof Uint8Array)) throw new Error("shape");
  const leaf = parseCertificate(x5c[0]);
  const intermediate = parseCertificate(x5c[1]);
  const root = parseCertificate(rootDer ?? base64ToBytes(APPLE_ROOT_DER_BASE64));
  if (!(await verifyChain(leaf, intermediate, root, now))) throw new Error("chain");

  const clientDataHash = await sha256(encoder.encode(challenge));
  const nonce = await sha256(authData, clientDataHash);
  const extension = leaf.extensions[NONCE_EXTENSION_OID];
  if (!extension) throw new Error("nonce");
  const wrapper = readTLV(extension, 0);
  const tagged = childrenOf(extension, wrapper)[0];
  const octets = childrenOf(extension, tagged)[0];
  if (wrapper.tag !== 0x30 || tagged?.tag !== 0xa1 || octets?.tag !== 0x04 || !bytesEqual(octets.content, nonce)) throw new Error("nonce");

  const point = leaf.point;
  if (leaf.curve?.name !== "P-256" || point.length !== 65 || point[0] !== 4) throw new Error("key");
  const keyHash = await sha256(point);
  if (!bytesEqual(keyHash, base64ToBytes(keyId))) throw new Error("key id");

  const { rpIdHash, counter } = parseAuthData(authData);
  if (!bytesEqual(rpIdHash, await sha256(encoder.encode(appId)))) throw new Error("app id");
  if (counter !== 0) throw new Error("counter");
  if (authData.length < 55) throw new Error("authData too short");
  const aaguid = new TextDecoder().decode(authData.subarray(37, 53));
  if (aaguid !== AAGUID_PRODUCTION && !(allowDevelop && aaguid === AAGUID_DEVELOP)) throw new Error("environment");
  const credentialLength = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0);
  if (!bytesEqual(authData.subarray(55, 55 + credentialLength), keyHash)) throw new Error("credential id");

  return { keyId: bytesToBase64Url(keyHash), publicKey: bytesToBase64Url(point) };
}

/**
 * Checks an assertion against a registered key. Returns the assertion's counter,
 * which the caller must then advance in the key's object (a counter that did not
 * go up is a copy). Throws with the step that failed.
 */
export async function verifyAssertion({ assertion, clientData, publicKey, storedCounter, appId }) {
  const object = decodeCBOR(assertion);
  const { signature, authenticatorData } = object;
  if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array)) throw new Error("shape");
  const { rpIdHash, counter } = parseAuthData(authenticatorData);
  if (!bytesEqual(rpIdHash, await sha256(encoder.encode(appId)))) throw new Error("app id");
  if (counter <= storedCounter) throw new Error("replay");
  const nonce = await sha256(authenticatorData, await sha256(encoder.encode(clientData)));
  const key = await crypto.subtle.importKey("raw", base64ToBytes(publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, derSignatureToRaw(signature, 32), nonce))) throw new Error("signature");
  return counter;
}

// --- challenge -----------------------------------------------------------------

async function challengeKey(env) {
  const raw = base64ToBytes(String(env.TOKEN_SIGNING_KEY ?? "").trim());
  if (raw.length < 32) throw new Error("TOKEN_SIGNING_KEY must be at least 32 bytes");
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

async function challengeSignature(env, body) {
  return bytesToBase64Url(new Uint8Array(await crypto.subtle.sign("HMAC", await challengeKey(env), encoder.encode(CHALLENGE_LABEL + body))));
}

export async function issueChallenge(env, now = Date.now()) {
  const random = bytesToBase64Url(crypto.getRandomValues(new Uint8Array(16)));
  const body = `${now}.${random}`;
  return `${body}.${await challengeSignature(env, body)}`;
}

export async function challengeIsValid(env, challenge, now = Date.now()) {
  const match = /^(\d{12,14})\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/.exec(String(challenge ?? ""));
  if (!match) return false;
  const age = now - Number(match[1]);
  if (age < -60_000 || age > CHALLENGE_MAX_AGE_MS) return false;
  const expected = await challengeSignature(env, `${match[1]}.${match[2]}`);
  return bytesEqual(encoder.encode(expected), encoder.encode(match[3]));
}

// --- configuration ---------------------------------------------------------------

export function appAttestMode(env) {
  const mode = env.APP_ATTEST_MODE;
  if (mode !== "log" && mode !== "enforce") return "off";
  if (!env.APP_ATTEST_APP_ID || !env.TOKEN_SIGNING_KEY || !env.RATE_COUNTER) return "off";
  try {
    if (base64ToBytes(String(env.TOKEN_SIGNING_KEY).trim()).length < 32) return "off";
  } catch {
    return "off";
  }
  return mode;
}

function keyObject(env, keyId) {
  return env.RATE_COUNTER.getByName(`attest-key:${keyId}`);
}

// --- routes ------------------------------------------------------------------------

async function limited(binding, request) {
  return binding ? !(await checkRateLimit(binding, clientKey(request))) : false;
}

/** POST /api/attest/challenge and POST /api/attest/register. null for any other route. */
export async function handleAppAttest(url, request, env, { now = Date.now(), rootDer } = {}) {
  if (request.method !== "POST") return null;
  if (url.pathname !== "/api/attest/challenge" && url.pathname !== "/api/attest/register") return null;
  const mode = appAttestMode(env);
  if (mode === "off") return json({ error: "Not found." }, 404);

  if (url.pathname === "/api/attest/challenge") {
    if (await limited(env.RATE_LIMIT_ATTEST_CHALLENGE, request)) return json({ error: "Too many attempts." }, 429);
    return json({ challenge: await issueChallenge(env, now) });
  }

  if (await limited(env.RATE_LIMIT_ATTEST_REGISTER, request)) return json({ error: "Too many attempts." }, 429);
  const body = await readJSONLimited(request, MAX_REGISTER_BODY);
  const keyId = typeof body?.keyId === "string" ? body.keyId.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "") : "";
  if (!KEY_ID_PATTERN.test(keyId) || typeof body?.attestation !== "string" || typeof body?.challenge !== "string") {
    return json({ error: "Invalid request." }, 400);
  }
  if (!(await challengeIsValid(env, body.challenge, now))) return json({ error: "The challenge is invalid or expired.", code: "attest_challenge_invalid" }, 400);

  let verified;
  try {
    verified = await verifyAttestation({
      attestation: base64ToBytes(body.attestation),
      challenge: body.challenge,
      keyId,
      appId: env.APP_ATTEST_APP_ID,
      allowDevelop: env.APP_ATTEST_ALLOW_DEVELOP === "true",
      now,
      rootDer,
    });
  } catch (error) {
    console.log(JSON.stringify({ message: "app attest register", result: "rejected", step: error instanceof Error ? error.message : "error" }));
    return json({ error: "The attestation was not accepted.", code: "attest_rejected" }, 400);
  }
  const stored = await keyObject(env, verified.keyId).attestRegister({ publicKey: verified.publicKey, counter: 0, createdAt: now });
  if (!stored) return json({ error: "This key is already registered.", code: "attest_key_exists" }, 409);
  console.log(JSON.stringify({ message: "app attest register", result: "registered" }));
  return json({ registered: true }, 201);
}

/**
 * Judges the assertion on a protected request. One of: ok, absent, malformed,
 * stale, unknown_key, replay, invalid, error. Never throws.
 */
export async function assessAssertion(request, env, url, now = Date.now()) {
  const header = request.headers.get("x-studiquo-attest");
  if (!header) return "absent";
  const match = /^([A-Za-z0-9_-]{43})\.(\d{12,14})\.([A-Za-z0-9_-]{20,2000})$/.exec(header);
  if (!match) return "malformed";
  // Only the canonical spelling of a key id names a key (its last character has
  // spare bits, so other spellings decode to the same bytes).
  try {
    if (bytesToBase64Url(base64ToBytes(match[1])) !== match[1]) return "malformed";
  } catch {
    return "malformed";
  }
  if (Math.abs(now - Number(match[2])) > ASSERTION_MAX_SKEW_MS) return "stale";
  // Anyone can send a well-formed header, and each one reaches a Durable Object
  // before the signature is checked: bound that per address.
  if (await limited(env.RATE_LIMIT_ATTEST_ASSERT, request)) return "throttled";
  try {
    const key = keyObject(env, match[1]);
    const record = await key.attestKey();
    if (!record) return "unknown_key";
    let counter;
    try {
      counter = await verifyAssertion({
        assertion: base64ToBytes(match[3]),
        clientData: `${request.method}\n${url.pathname}\n${match[2]}`,
        publicKey: record.publicKey,
        storedCounter: record.counter,
        appId: env.APP_ATTEST_APP_ID,
      });
    } catch (error) {
      return error instanceof Error && error.message === "replay" ? "replay" : "invalid";
    }
    // Two requests carrying the same counter can both pass the check above;
    // only one can move the counter forward.
    return (await key.attestAdvance(counter)) ? "ok" : "replay";
  } catch {
    return "error";
  }
}

/**
 * The gate for the protected routes: null to carry on, or a 403. In "log" mode it
 * only writes the log line.
 */
export async function appAttestGate(request, env, url, now = Date.now()) {
  const mode = appAttestMode(env);
  if (mode === "off") return null;
  if (request.method === "GET" || request.method === "HEAD" || request.method === "OPTIONS") return null;
  const protectedRoute = url.pathname.startsWith("/api/ai/") || ATTEST_PROTECTED_PATHS.has(url.pathname);
  if (!protectedRoute) return null;
  const result = await assessAssertion(request, env, url, now);
  console.log(JSON.stringify({ message: "app attest", mode, result, route: url.pathname.startsWith("/api/ai/") ? "ai" : url.pathname }));
  if (mode === "enforce" && result === "error") {
    // Our own storage failed: not the caller's fault, and worth retrying.
    return json({ error: "ただいま混み合っています。しばらくしてからもう一度お試しください。", code: "app_attest_unavailable" }, 503);
  }
  if (mode === "enforce" && result !== "ok") {
    return json({ reason: result, error: "このアプリの正規版からのリクエストであることを確認できませんでした。アプリを最新版に更新してください。", code: "app_attest_required" }, 403);
  }
  return null;
}
