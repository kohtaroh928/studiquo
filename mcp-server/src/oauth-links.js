// Recognizes that two different OAuth sign-ins (Apple and Google today) are
// the same real person when they share a *verified* email address, so
// signing in with a different provider than usual doesn't read as a second,
// unrelated account.
//
// Deliberately narrow in scope: this only maintains an index of which
// provider identities share a verified email. It does not change how either
// provider's own account:* record is keyed, or how cloud-sync tokens map to
// storage — those already mint an independent, per-sign-in token/bucket and
// are out of scope here. This index exists so features built on "is this
// the same person" (support, entitlements, de-duplicating a friends list)
// have a real answer instead of none at all.
//
// Only a *verified* email participates: an unverified one is self-asserted
// and not trustworthy enough to use as a join key between two accounts —
// verifying it is exactly the check every caller must pass through
// (Apple's `is_private_email`-free email is always verified; Google's own
// `email_verified` claim gates it explicitly).
const EMAIL_LINK_PREFIX = "email-accounts:";
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
  if (alreadyLinked) return { normalizedEmail: normalized, linkedIdentities: existing };

  const updated = [...existing, { provider, sub }].slice(-MAX_LINKED_IDENTITIES);
  await env.STUDIQUO_DATA.put(linkKey, JSON.stringify(updated));
  return { normalizedEmail: normalized, linkedIdentities: updated };
}

/** Returns every `{ provider, sub }` known to share `email` (verified sign-ins only), or `[]`. */
export async function linkedIdentities(env, email) {
  const normalized = normalizeEmail(email);
  if (!normalized) return [];
  return (await env.STUDIQUO_DATA.get(`${EMAIL_LINK_PREFIX}${normalized}`, "json")) ?? [];
}
