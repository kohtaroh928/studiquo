import { sha256Hex } from "./auth.js";

const DAY = 86_400_000;
export const PERSONAL_RETENTION_MS = 90 * DAY;
export const ERROR_RETENTION_MS = 180 * DAY;
export const RETENTION_BATCH_SIZE = 100;

export async function eraseReport(env, id) {
  await env.STUDIQUO_DATA.delete(`issue-report:${id}`);
  await env.STUDIQUO_DATA.delete(`issue-report-screenshot:${id}`);
  await env.ADMIN_DB.prepare("DELETE FROM issue_reports WHERE id = ?").bind(id).run();
}

// Separate durable outbox: a failed remote deletion must survive local erasure.
export async function queueRevenueCatDeletion(env, identity, now = Date.now()) {
  const hash = await sha256Hex(identity);
  // The job holds the identity in the clear (the provider's DELETE needs it),
  // so it expires with the personal-data retention period instead of staying
  // forever when the provider can never be reached (no secret configured).
  await env.STUDIQUO_DATA.put(`privacy-rc-delete:${hash}`, JSON.stringify({ identity, requestedAt: now }), {
    expirationTtl: PERSONAL_RETENTION_MS / 1000,
  });
}

export async function retryRevenueCatDeletion(env, key, job, fetcher = fetch) {
  if (!env.REVENUECAT_SECRET_API_KEY) return false;
  const response = await fetcher(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(job.identity)}`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${env.REVENUECAT_SECRET_API_KEY}` },
    signal: AbortSignal.timeout(10_000),
  });
  // An absent customer is already erased. Never log API responses/identities.
  if (!response.ok && response.status !== 404) {
    await response.body?.cancel();
    return false;
  }
  await response.body?.cancel();
  await env.STUDIQUO_DATA.delete(key);
  return true;
}

async function processJobs(env, prefix, callback, limit = 10) {
  const cursorKey = `privacy-cursor:${prefix}`;
  const cursor = await env.STUDIQUO_DATA.get(cursorKey) || undefined;
  const page = await env.STUDIQUO_DATA.list({ prefix, limit, cursor });
  for (const key of page.keys) {
    const job = await env.STUDIQUO_DATA.get(key.name, "json");
    if (!job) continue;
    try { await callback(key.name, job); }
    catch { console.error(JSON.stringify({ message: "privacy deletion retry failed", kind: prefix })); }
  }
  if (page.list_complete) await env.STUDIQUO_DATA.delete(cursorKey);
  else await env.STUDIQUO_DATA.put(cursorKey, page.cursor);
}

/**
 * Carries through deletions a person has already asked for: an account whose
 * cleanup was cut short, and the provider (RevenueCat) DELETEs still queued.
 * Unlike the automatic expiry below, this is not behind
 * PRIVACY_RETENTION_ENABLED — an accepted deletion must finish (and an account
 * stuck mid-deletion must become usable again) whatever that flag says.
 * `limit` bounds how many jobs of each kind one run takes on: finishing an
 * account walks a lot of KV, so a run that is not the full retention job keeps
 * it small.
 */
export async function processPendingDeletions(env, fetcher = fetch, { limit = 10 } = {}) {
  // Import lazily to avoid a module cycle with deleteAccount's shared helpers.
  const { deleteAccount } = await import("./account-deletion.js");
  await processJobs(env, "privacy-account-delete:", async (_key, job) => deleteAccount(env, job.canonicalSub), limit);
  // Without the provider secret every attempt fails, so skip the pass: it
  // would only spend subrequests and keep cycling the same jobs. Say so when
  // jobs are waiting, so queued erasures don't pile up unnoticed.
  if (env.REVENUECAT_SECRET_API_KEY) {
    await processJobs(env, "privacy-rc-delete:", (key, job) => retryRevenueCatDeletion(env, key, job, fetcher), limit);
  } else {
    const waiting = await env.STUDIQUO_DATA.list({ prefix: "privacy-rc-delete:", limit: 1 });
    if (waiting.keys?.length) console.warn(JSON.stringify({ message: "provider deletions are queued but REVENUECAT_SECRET_API_KEY is not configured" }));
  }
}

/**
 * What the hourly schedule runs. With the flag on, the full retention job
 * (which includes the pending deletions). With it off, only the pending
 * deletions, a few at a time: the automatic expiry stays off, but a deletion
 * somebody asked for is never left unfinished.
 */
export async function runScheduledPrivacyWork(env, scheduledTime, fetcher = fetch) {
  if (env.PRIVACY_RETENTION_ENABLED === "true") return runPrivacyRetention(env, scheduledTime, fetcher);
  await processPendingDeletions(env, fetcher, { limit: 2 });
  return { enabled: false };
}

export async function runPrivacyRetention(env, now = Date.now(), fetcher = fetch) {
  if (env.PRIVACY_RETENTION_ENABLED !== "true") return { enabled: false };
  if (!env.ADMIN_DB) throw new Error("Privacy retention requires ADMIN_DB");
  await processPendingDeletions(env, fetcher);

  const personalCutoff = now - PERSONAL_RETENTION_MS;
  const reports = await env.ADMIN_DB.prepare(
    "SELECT id FROM issue_reports WHERE created_at <= ? ORDER BY created_at LIMIT ?"
  ).bind(personalCutoff, RETENTION_BATCH_SIZE).all();
  for (const report of reports.results) await eraseReport(env, report.id);
  // Each invocation bounds work. Backlogs are drained by subsequent runs.
  for (const [table, timeColumn, cutoff] of [
    ["revenuecat_events", "occurred_at", personalCutoff],
    ["app_error_users", "last_seen_at", personalCutoff],
  ]) {
    await env.ADMIN_DB.prepare(`DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE ${timeColumn} <= ? ORDER BY ${timeColumn} LIMIT ?)`)
      .bind(cutoff, RETENTION_BATCH_SIZE).run();
  }
  const errors = await env.ADMIN_DB.prepare(
    "SELECT fingerprint FROM app_errors WHERE last_seen_at <= ? ORDER BY last_seen_at LIMIT ?"
  ).bind(now - ERROR_RETENTION_MS, RETENTION_BATCH_SIZE).all();
  for (const error of errors.results) {
    await env.ADMIN_DB.prepare("DELETE FROM app_error_users WHERE fingerprint = ?").bind(error.fingerprint).run();
    await env.ADMIN_DB.prepare("DELETE FROM app_errors WHERE fingerprint = ?").bind(error.fingerprint).run();
  }
  const overdue = await env.ADMIN_DB.prepare(
    `SELECT (EXISTS(SELECT 1 FROM issue_reports WHERE created_at <= ?)
      OR EXISTS(SELECT 1 FROM revenuecat_events WHERE occurred_at <= ?)
      OR EXISTS(SELECT 1 FROM app_error_users WHERE last_seen_at <= ?)
      OR EXISTS(SELECT 1 FROM app_errors WHERE last_seen_at <= ?)) AS pending`
  ).bind(personalCutoff, personalCutoff, personalCutoff, now - ERROR_RETENTION_MS).first();
  if (overdue?.pending) console.warn(JSON.stringify({ message: "privacy retention backlog requires attention" }));
  return { enabled: true, reportsDeleted: reports.results.length, errorsDeleted: errors.results.length };
}
