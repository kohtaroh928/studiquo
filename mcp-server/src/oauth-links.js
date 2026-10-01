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

  const linkKey = `${EMAIL_LINK_PREFIX}${normalized}`;
  const existing = (await env.STUDIQUO_DATA.get(linkKey, "json")) ?? [];
  const alreadyLinked = existing.some(identity => identity.provider === provider && identity.sub === sub);
  const updated = alreadyLinked ? existing : [...existing, { provider, sub }].slice(-MAX_LINKED_IDENTITIES);
  if (!alreadyLinked) await env.STUDIQUO_DATA.put(linkKey, JSON.stringify(updated));

  // Preserve the first account that claimed this verified address, including
  // for link indexes created by older deployments before owner records
  // existed. This avoids changing the user's primary data bucket depending
  // on which provider they happen to use next.
  const ownerKey = `${EMAIL_OWNER_PREFIX}${normalized}`;
  let canonicalIdentityKey = await env.STUDIQUO_DATA.get(ownerKey);
  if (!canonicalIdentityKey) {
    canonicalIdentityKey = identityKey(updated[0]);
    await env.STUDIQUO_DATA.put(ownerKey, canonicalIdentityKey);
  }
  await Promise.all(updated.map(identity =>
    env.STUDIQUO_DATA.put(`${IDENTITY_CANONICAL_PREFIX}${identityKey(identity)}`, canonicalIdentityKey)
  ));
  return { normalizedEmail: normalized, linkedIdentities: updated, canonicalIdentityKey };
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
