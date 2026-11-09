// Turns rows of the D1 revocation_log (mcp-server/migrations/0034_revocation_log.sql)
// into the KV changes that put those revocations back after KV was restored from a
// backup older than they are. Pure: no network, no secrets.
export interface LogRow { id?: number; at: number; kind: string; subject: string; value?: string }
export interface Plan {
  put: { name: string; value: string; expiration?: number }[];
  remove: string[];
  /** Every key under these prefixes is to be deleted (connected-app grants). */
  removePrefix: string[];
  /** Hashes held closed: they cannot sign in or use a session until an operator purges them. */
  heldAccounts: string[];
}

const SESSION_CUTOFF_TTL_SECONDS = (90 + 1) * 24 * 60 * 60; // token.ts VALIDITY_SECONDS + 1 day

/**
 * `backupAt` (ms): rows at or before it are skipped. Rows are applied in order, so the last word on an account or a suspension wins
 * (a deletion followed by a re-registration is not re-applied).
 *
 * An account deleted after the backup comes back with its old password. It is put
 * in the "deleting" state, which refuses sign-in and sessions (fail closed), and listed in
 * heldAccounts: the record of WHAT to erase is not in the log (only a hash), so an
 * operator must purge these accounts; they are not erased here.
 */
export function planReapply(rows: readonly LogRow[], now = Date.now(), backupAt = 0): Plan {
  // Only what happened after the backup was taken: earlier events are already in it, and
  // replaying them could undo things done since (a new account, a newer cut-off).
  const ordered = [...rows].filter(row => row.at > backupAt).sort((a, b) => (a.at - b.at) || ((a.id ?? 0) - (b.id ?? 0)));
  const held = new Set<string>();
  const cutoffs = new Map<string, number>();
  const suspended = new Map<string, boolean>();
  const connections = new Set<string>();
  for (const row of ordered) {
    if (row.kind === "account-deleted") held.add(row.subject);
    else if (row.kind === "account-reregistered") held.delete(row.subject);
    else if (row.kind === "session-cutoff") {
      const value = Number(row.value);
      if (Number.isFinite(value) && value > 0) cutoffs.set(row.subject, Math.max(cutoffs.get(row.subject) ?? 0, value));
    } else if (row.kind === "suspension-set") suspended.set(row.subject, true);
    else if (row.kind === "suspension-cleared") suspended.set(row.subject, false);
    else if (row.kind === "connections-revoked") connections.add(row.subject);
  }
  const plan: Plan = { put: [], remove: [], removePrefix: [], heldAccounts: [...held].sort() };
  for (const hash of plan.heldAccounts) {
    plan.put.push({ name: `account-deletion:${hash}`, value: JSON.stringify({ status: "deleting", of: hash, reapplied: true }) });
  }
  for (const [hash, value] of cutoffs) {
    const expiration = Math.floor(value / 1000) + SESSION_CUTOFF_TTL_SECONDS;
    if (expiration * 1000 > now) plan.put.push({ name: `session-valid-from:${hash}`, value: String(value), expiration });
  }
  for (const [key, on] of suspended) {
    if (on) plan.put.push({ name: key, value: JSON.stringify({ at: now, reapplied: true }) });
    else plan.remove.push(key);
  }
  for (const hash of connections) plan.removePrefix.push(`mcp:grant:${hash}:`);
  return plan;
}
