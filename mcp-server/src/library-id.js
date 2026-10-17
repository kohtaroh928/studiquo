// The opaque id the app keeps one on-device library per account under.
//
// It is an HMAC of the account's canonical identity with a server secret, not a
// plain hash: canonical identities include `email:<address>`, so an unkeyed hash
// could be computed by anyone who knows an address, and would let a copy of the
// app's ledger be matched back to a person. The id is not a secret and is never
// used to authorize anything; the key only stops it being worked out from a
// guess.
//
// LIBRARY_ID_SECRET: base64 of at least 32 random bytes (a Worker secret). Set it
// once and never change it: a different key gives every account a different id,
// and every library on every device would no longer be found.
const encoder = new TextEncoder();
const LABEL = "studiquo-library-id-v1:";
const importedKeys = new Map();

function base64Bytes(value) {
  const normalized = String(value).trim().replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0));
}

async function key(secret) {
  const cached = importedKeys.get(secret);
  if (cached) return cached;
  const raw = base64Bytes(secret);
  if (raw.length < 32) throw new Error("LIBRARY_ID_SECRET must be at least 32 bytes, base64-encoded.");
  const imported = crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  importedKeys.set(secret, imported);
  return imported;
}

/** 64 lowercase hex characters, or null when the secret is missing or unusable. */
export async function libraryAccountId(env, canonicalIdentity) {
  if (!env?.LIBRARY_ID_SECRET) return null;
  try {
    const signature = await crypto.subtle.sign("HMAC", await key(env.LIBRARY_ID_SECRET), encoder.encode(`${LABEL}${canonicalIdentity}`));
    return Array.from(new Uint8Array(signature), byte => byte.toString(16).padStart(2, "0")).join("");
  } catch {
    return null;
  }
}
