// Email/password sign-up has no OAuth provider to vouch for the address the
// user typed in, so this module is what actually proves they can receive
// mail there: a short numeric code, emailed out and checked back. Only once
// that check passes does the email participate in oauth-links.js's
// cross-provider linking — exactly the same "only a verified email may join
// two accounts" rule Apple and Google already get from their own tokens.
import { sha256Hex } from "./auth.js";
import { linkVerifiedEmail } from "./oauth-links.js";

const CODE_PREFIX = "email-verify:";
const CODE_TTL_SECONDS = 15 * 60;
const MAX_ATTEMPTS = 5;
const RESEND_API_URL = "https://api.resend.com/emails";

function normalizeEmail(email) {
  if (typeof email !== "string") return null;
  const trimmed = email.trim().toLowerCase();
  return trimmed.length > 0 && trimmed.length <= 254 && trimmed.includes("@") ? trimmed : null;
}

function generateCode() {
  // 6 digits, zero-padded — rejects the all-zero code so a support agent
  // reading it aloud never has to say "and then four more zeros".
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  const code = String(bytes[0] % 1_000_000).padStart(6, "0");
  return code === "000000" ? generateCode() : code;
}

/**
 * Generates a fresh 6-digit code for `email`, stores its hash in KV (15
 * minute TTL, resetting any previous code and attempt count), and emails it
 * via Resend. Returns `{ sent: true }` on success.
 *
 * Throws if `email` doesn't look like an email address, or if the Resend
 * call itself fails — callers should treat either as "could not send".
 */
export async function sendVerificationCode(env, email) {
  const normalized = normalizeEmail(email);
  if (!normalized) throw new Error("Invalid email address.");

  const code = generateCode();
  const codeHash = await sha256Hex(code);
  await env.STUDIQUO_DATA.put(
    `${CODE_PREFIX}${normalized}`,
    JSON.stringify({ codeHash, expiresAt: Date.now() + CODE_TTL_SECONDS * 1000, attempts: 0 }),
    { expirationTtl: CODE_TTL_SECONDS }
  );

  const response = await fetch(RESEND_API_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: env.RESEND_FROM_EMAIL ?? "Studiquo <onboarding@resend.dev>",
      to: normalized,
      subject: "Studiquo確認コード",
      text: `確認コード: ${code}\n\nこのコードは15分間有効です。心当たりがない場合はこのメールを無視してください。`,
    }),
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Failed to send verification email: HTTP ${response.status} ${detail}`);
  }
  return { sent: true };
}

/**
 * Checks `code` against the one on file for `email`. On a match, deletes the
 * stored code (one-time use) and links the now-verified email via
 * oauth-links.js under provider "email" — `sub` is the normalized email
 * itself, since there's no OAuth subject to anchor to.
 *
 * Returns `{ verified: true }` on success. On a wrong code, records the
 * attempt and returns `{ verified: false, attemptsRemaining }`; the code is
 * invalidated outright once attempts are exhausted, requiring a fresh send.
 * Returns `{ verified: false, attemptsRemaining: 0 }` for a missing or
 * expired code too, so callers can't distinguish "never sent" from
 * "exhausted" — nothing a legitimate caller needs to tell those apart for.
 */
export async function confirmVerificationCode(env, email, code) {
  const normalized = normalizeEmail(email);
  if (!normalized || typeof code !== "string") return { verified: false, attemptsRemaining: 0 };

  const key = `${CODE_PREFIX}${normalized}`;
  const record = await env.STUDIQUO_DATA.get(key, "json");
  if (!record || record.expiresAt < Date.now()) return { verified: false, attemptsRemaining: 0 };

  const codeHash = await sha256Hex(code);
  if (codeHash !== record.codeHash) {
    const attempts = record.attempts + 1;
    if (attempts >= MAX_ATTEMPTS) {
      await env.STUDIQUO_DATA.delete(key);
      return { verified: false, attemptsRemaining: 0 };
    }
    await env.STUDIQUO_DATA.put(key, JSON.stringify({ ...record, attempts }), {
      expirationTtl: CODE_TTL_SECONDS,
    });
    return { verified: false, attemptsRemaining: MAX_ATTEMPTS - attempts };
  }

  await env.STUDIQUO_DATA.delete(key);
  await linkVerifiedEmail(env, { provider: "email", sub: normalized, email: normalized, emailVerified: true });
  return { verified: true };
}
