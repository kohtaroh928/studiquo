// Writes to the append-only revocation_log in D1 (migrations/0034_revocation_log.sql).
// It exists so a restore of KV from an old backup can re-apply what was revoked after
// that backup. Best effort on purpose: a failed write is logged and never blocks the
// deletion, password reset or moderation action it records.
import type { Env } from "./env.ts";

export type RevocationKind = "account-deleted" | "account-reregistered" | "session-cutoff" | "suspension-set" | "suspension-cleared" | "connections-revoked";

export async function recordRevocation(env: Env, kind: RevocationKind, subject: string, value = "") {
  if (!env.ADMIN_DB) return false;
  try {
    await env.ADMIN_DB.prepare("INSERT INTO revocation_log (at, kind, subject, value) VALUES (?, ?, ?, ?)")
      .bind(Date.now(), kind, subject, value).run();
    return true;
  } catch {
    console.error(JSON.stringify({ event: "revocation_log_failed", kind }));
    return false;
  }
}
