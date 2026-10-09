// Recognizes that two different OAuth sign-ins (Apple and Google today) are
// the same real person when they share a *verified* email address, so
// signing in with a different provider than usual doesn't read as a second,
// unrelated account.
//
// The first verified identity linked to an email becomes that email's stable
// account owner. Every later identity is mapped to that same owner, so all
// sign-in methods mint sessions for one account and therefore share chat,
// cloud-sync, usage and connection storage.
//
// Only a *verified* email participates: an unverified one is self-asserted
// and not trustworthy enough to use as a join key between two accounts —
// verifying it is exactly the check every caller must pass through
// (Apple's `is_private_email`-free email is always verified; Google's own
// `email_verified` claim gates it explicitly).
const EMAIL_LINK_PREFIX = "email-accounts:";
const EMAIL_OWNER_PREFIX = "email-account-owner:";
export const IDENTITY_CANONICAL_PREFIX = "identity-canonical:";
const MAX_LINKED_IDENTITIES = 10;

function normalizeEmail(email) {
  if (typeof email !== "string") return null;
  const trimmed = email.trim().toLowerCase();
  return trimmed.length > 0 && trimmed.length <= 254 && trimmed.includes("@") ? trimmed : null;
}

/**
 * Adds `{ provider, sub }` to the set of identities known to share
 * `email`, if `email` is present and verified. A no-op (returning the
 * existing list, or an empty one) for an unverified or missing email.
 *
 * Idempotent: signing in again with the same provider+sub doesn't create a
 * duplicate entry.
 */
export async function linkVerifiedEmail(env, { provider, sub, email, emailVerified }) {
  const normalized = normalizeEmail(email);
  if (!normalized || !emailVerified) return { normalizedEmail: null, linkedIdentities: [] };

  // Every successful sign-in comes through here. When it is done: the link
  // list holds this identity, the owner record exists, and every linked
  // identity maps to the owner. KV round trips are slow (hundreds of
  // milliseconds, a write the slowest), so the common case -- an identity that
  // is already linked, with an owner on record -- is handled with as few
  // rounds of reads as possible and writes only what is wrong. Anything that
  // has to change the link list or the owner (a first sign-in, a new
  // identity) goes the original, sequential way instead: those decisions
  // must be made from a read taken just before the write, because two
  // sign-ins for the same address can arrive together, and they happen once
  // per identity, not on every sign-in.
  const linkKey = `${EMAIL_LINK_PREFIX}${normalized}`;
  const ownerKey = `${EMAIL_OWNER_PREFIX}${normalized}`;
  const ownMappingKey = `${IDENTITY_CANONICAL_PREFIX}${identityKey({ provider, sub })}`;
  const [storedLinks, storedOwner, ownMapping] = await Promise.all([
    env.STUDIQUO_DATA.get(linkKey, "json"),
    env.STUDIQUO_DATA.get(ownerKey),
    env.STUDIQUO_DATA.get(ownMappingKey),
  ]);
  const existing = storedLinks ?? [];
  const alreadyLinked = existing.some(identity => identity.provider === provider && identity.sub === sub);

  if (!alreadyLinked || !storedOwner) {
    return linkChangingTheIndex(env, { provider, sub, normalized, linkKey, ownerKey });
  }

  // Steady state: nothing about the list or the owner changes.
  const canonicalIdentityKey = storedOwner;
  const canonicalKeys = existing.map(identity => `${IDENTITY_CANONICAL_PREFIX}${identityKey(identity)}`);
  await repairMappings(env, canonicalKeys, canonicalIdentityKey, new Map([[ownMappingKey, ownMapping]]));
  return { normalizedEmail: normalized, linkedIdentities: existing, canonicalIdentityKey };
}

// The original algorithm, in its original order: read the list, write it if
// this identity is new, read the owner, write it if missing -- each decision
// right after its own read. Only the per-identity mappings are now written
// conditionally.
async function linkChangingTheIndex(env, { provider, sub, normalized, linkKey, ownerKey }) {
  const existing = (await env.STUDIQUO_DATA.get(linkKey, "json")) ?? [];
  const alreadyLinked = existing.some(identity => identity.provider === provider && identity.sub === sub);
  const updated = alreadyLinked ? existing : [...existing, { provider, sub }].slice(-MAX_LINKED_IDENTITIES);
  if (!alreadyLinked) await env.STUDIQUO_DATA.put(linkKey, JSON.stringify(updated));

  // Preserve the first account that claimed this verified address, including
  // for link indexes created by older deployments before owner records
  // existed. This avoids changing the user's primary data bucket depending
  // on which provider they happen to use next.
  let canonicalIdentityKey = await env.STUDIQUO_DATA.get(ownerKey);
  if (!canonicalIdentityKey) {
    canonicalIdentityKey = identityKey(updated[0]);
    await env.STUDIQUO_DATA.put(ownerKey, canonicalIdentityKey);
  }
  await repairMappings(env, updated.map(identity => `${IDENTITY_CANONICAL_PREFIX}${identityKey(identity)}`), canonicalIdentityKey, new Map());
  return { normalizedEmail: normalized, linkedIdentities: updated, canonicalIdentityKey };
}

// Makes every given identity map to the owner, reading each mapping (the ones
// already in `known` are not read again) and writing only those that are
// missing or wrong. Checking all of them, not just the signing-in identity's,
// keeps the old self-repair: a mapping that was never written, or was written
// wrongly, is fixed the next time any identity of this email signs in.
async function repairMappings(env, canonicalKeys, canonicalIdentityKey, known) {
  const unread = [...new Set(canonicalKeys.filter(key => !known.has(key)))];
  const values = await Promise.all(unread.map(key => env.STUDIQUO_DATA.get(key)));
  const mappings = new Map(known);
  unread.forEach((key, index) => mappings.set(key, values[index]));
  await Promise.all(canonicalKeys
    .filter(key => mappings.get(key) !== canonicalIdentityKey)
    .map(key => env.STUDIQUO_DATA.put(key, canonicalIdentityKey)));
}

function identityKey(identity) {
  if (identity.provider === "google") return `google:${identity.sub}`;
  if (identity.provider === "email") return `email:${identity.sub}`;
  return identity.sub; // Apple keeps its historical bare-sub session key.
}

/** Returns every `{ provider, sub }` known to share `email` (verified sign-ins only), or `[]`. */
export async function linkedIdentities(env, email) {
  const normalized = normalizeEmail(email);
  if (!normalized) return [];
  return (await env.STUDIQUO_DATA.get(`${EMAIL_LINK_PREFIX}${normalized}`, "json")) ?? [];
}
