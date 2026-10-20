// Encrypts the synced Studiquo snapshot (notes' OCR text, flashcards, calendar
// events) before it is written to KV, and decrypts it when the MCP tools read
// it. KV encrypts its disks, but anyone with the Cloudflare dashboard or a
// leaked API token could still read the values; with this, they get
// ciphertext and would also need the Worker secret.
//
// AES-256-GCM through Web Crypto, one fresh 96-bit IV per write. The key name
// ("snapshot:<hash>") is bound in as additional authenticated data and mixed
// into the per-record key, so a ciphertext copied to another user's key fails
// to decrypt instead of showing the first user's notes to the second.
//
// Stored form: "enc1.<key id>.<iv>.<ciphertext>" (base64url). Anything else is
// a plaintext snapshot written before this existed and is still readable, so
// turning encryption on loses nothing; each record is encrypted at its next
// sync.
//
// Keys come from Worker secrets (never the repository):
//   SNAPSHOT_ENCRYPTION_KEY      base64 of 32 random bytes; writes use it
//   SNAPSHOT_ENCRYPTION_KEY_ID   its label (default "1"), stored with each record
//   SNAPSHOT_ENCRYPTION_KEY_OLD / _OLD_ID   previous key, kept readable while
//                                records written under it are replaced
// With no key configured nothing is encrypted (the rollout order is: set the
// secret, then deploy). SNAPSHOT_ENCRYPTION_REQUIRED="true" refuses to store a
// snapshot in plaintext instead of silently doing so.
import type { Env } from "./env.ts";

const PREFIX = "enc1";
const encoder = new TextEncoder();

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0));
}

// btoa(String.fromCharCode(...bytes)) overflows the call stack on a multi-MB
// array, so large buffers are converted in slices.
function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function configuredKeys(env: Env): { id: string; secret: string }[] {
  const keys: { id: string; secret: string }[] = [];
  if (env.SNAPSHOT_ENCRYPTION_KEY) keys.push({ id: String(env.SNAPSHOT_ENCRYPTION_KEY_ID || "1"), secret: env.SNAPSHOT_ENCRYPTION_KEY });
  if (env.SNAPSHOT_ENCRYPTION_KEY_OLD) keys.push({ id: String(env.SNAPSHOT_ENCRYPTION_KEY_OLD_ID || "0"), secret: env.SNAPSHOT_ENCRYPTION_KEY_OLD });
  return keys;
}

async function recordKey(secret: string, storageKey: string): Promise<CryptoKey> {
  const raw = fromBase64Url(secret.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, ""));
  if (raw.length !== 32) throw new Error("SNAPSHOT_ENCRYPTION_KEY must be 32 bytes, base64-encoded.");
  const master = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("studiquo-snapshot-v1"), info: encoder.encode(storageKey) },
    master, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
  );
}

/** The string to put in KV for `plaintext` (a JSON snapshot) stored at `storageKey`. */
export async function sealSnapshot(env: Env, storageKey: string, plaintext: string): Promise<string> {
  const [current] = configuredKeys(env);
  if (!current) {
    if (env.SNAPSHOT_ENCRYPTION_REQUIRED === "true") throw new Error("Snapshot encryption is required but no key is configured.");
    return plaintext;
  }
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await recordKey(current.secret, storageKey);
  const cipher = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(storageKey) }, key, encoder.encode(plaintext),
  ));
  return `${PREFIX}.${current.id}.${toBase64Url(iv)}.${bytesToBase64Url(cipher)}`;
}

/** The snapshot text for what KV returned for `storageKey`; null when nothing was stored. */
export async function openSnapshot(env: Env, storageKey: string, stored: unknown): Promise<string | null> {
  if (typeof stored !== "string" || stored.length === 0) return null;
  if (!stored.startsWith(`${PREFIX}.`)) return stored;
  const [, keyId, iv, cipher] = stored.split(".");
  const match = configuredKeys(env).find(key => key.id === keyId);
  if (!match || !iv || !cipher) throw new Error("This snapshot cannot be decrypted with the configured key.");
  const key = await recordKey(match.secret, storageKey);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromBase64Url(iv), additionalData: encoder.encode(storageKey) }, key, fromBase64Url(cipher),
  );
  return new TextDecoder().decode(plain);
}
