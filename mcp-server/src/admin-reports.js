// Dashboard-side API for the two inboxes: reports people wrote by hand
// ("問題を報告", table issue_reports) and errors the app sent by itself
// (table app_errors, filled by app-errors.js). Like the rest of /api/admin/*
// these routes carry no bearer-token check of their own — Cloudflare Access
// gates them at the edge (see admin.js's header comment).
//
// Because they are reachable with the admin's browser cookie alone, every
// write requires a JSON content type: a cross-site HTML form can't send one
// without a CORS preflight, which this API never answers.
import { json, readJSONLimited } from "./http.js";
import { PERSONAL_RETENTION_MS, ERROR_RETENTION_MS } from "./privacy-retention.js";

const STATUSES = new Set(["open", "in_progress", "resolved"]);
const MAX_NOTE_LENGTH = 2_000;
const LIST_LIMIT = 200;

function statusFilter(url) {
  const status = url.searchParams.get("status") ?? "open";
  return status === "all" ? null : STATUSES.has(status) ? status : "open";
}

function requireJSON(request) {
  return (request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json");
}

async function readUpdate(request) {
  if (!requireJSON(request)) return { response: json({ error: "Content-Type must be application/json." }, 415) };
  const body = await readJSONLimited(request, 10_000);
  if (!body || typeof body !== "object") return { response: json({ error: "Invalid request." }, 400) };
  const update = {};
  if (body.status !== undefined) {
    if (!STATUSES.has(body.status)) return { response: json({ error: "Invalid status." }, 400) };
    update.status = body.status;
  }
  if (body.note !== undefined) {
    if (typeof body.note !== "string") return { response: json({ error: "Invalid note." }, 400) };
    update.note = body.note.slice(0, MAX_NOTE_LENGTH);
  }
  if (update.status === undefined && update.note === undefined) return { response: json({ error: "Nothing to update." }, 400) };
  return { update };
}

function issueReportJSON(row, origin) {
  return {
    id: row.id,
    description: row.description,
    appVersion: row.app_version,
    osVersion: row.os_version,
    deviceModel: row.device_model,
    language: row.language,
    hasScreenshot: row.has_screenshot === 1,
    screenshotURL: row.has_screenshot === 1 ? `${origin}/api/issue-reports/${row.id}/screenshot` : null,
    status: row.status,
    note: row.admin_note,
    createdAt: row.created_at,
  };
}

function appErrorJSON(row) {
  return {
    fingerprint: row.fingerprint,
    kind: row.kind,
    title: row.title,
    detail: row.detail,
    firstSeenAt: row.first_seen_at,
    lastSeenAt: row.last_seen_at,
    occurrences: row.occurrences,
    affectedUsers: row.affected_users,
    lastAppVersion: row.last_app_version,
    lastOSVersion: row.last_os_version,
    lastDeviceModel: row.last_device_model,
    status: row.status,
    note: row.admin_note,
  };
}

// One-off: copies the reports that were only ever in KV (everything filed
// before the dashboard had an inbox) into D1. Safe to run again — a report
// that is already there, handled or not, is left exactly as it is.
async function importLegacyReports(env) {
  let imported = 0;
  let skipped = 0;
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix: "issue-report:", cursor });
    for (const { name } of page.keys) {
      if (name.startsWith("issue-report-screenshot:")) continue;
      const report = await env.STUDIQUO_DATA.get(name, "json");
      if (!report?.id || typeof report.description !== "string") { skipped += 1; continue; }
      const createdAt = Number(report.createdAt) || Date.now();
      if (createdAt <= Date.now() - PERSONAL_RETENTION_MS) { skipped += 1; continue; }
      const result = await env.ADMIN_DB.prepare(
        `INSERT OR IGNORE INTO issue_reports
           (id, reporter_key, account_key, description, app_version, os_version, device_model, language, has_screenshot, status, admin_note, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', '', ?, ?)`
      ).bind(
        report.id, String(report.reporterKey ?? ""), report.accountKey ?? null, report.description, String(report.appVersion ?? ""),
        String(report.osVersion ?? ""), String(report.deviceModel ?? ""), String(report.language ?? ""),
        report.hasScreenshot ? 1 : 0, createdAt, createdAt
      ).run();
      if ((result.meta?.changes ?? result.meta?.rows_written ?? 0) > 0) imported += 1; else skipped += 1;
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return { imported, skipped };
}

export async function handleAdminReports(url, request, env) {
  if (!url.pathname.startsWith("/api/admin/issue-reports") && !url.pathname.startsWith("/api/admin/app-errors")) return null;
  if (!env.ADMIN_DB) return json({ error: "Unavailable." }, 503);

  if (url.pathname === "/api/admin/issue-reports" && request.method === "GET") {
    const status = statusFilter(url);
    const cutoff = Date.now() - PERSONAL_RETENTION_MS;
    const rows = await env.ADMIN_DB.prepare(
      `SELECT * FROM issue_reports WHERE created_at > ? ${status ? "AND status = ?" : ""} ORDER BY created_at DESC LIMIT ${LIST_LIMIT}`
    ).bind(cutoff, ...(status ? [status] : [])).all();
    return json({ reports: (rows.results ?? []).map(row => issueReportJSON(row, url.origin)) });
  }

  if (url.pathname === "/api/admin/issue-reports/import-legacy" && request.method === "POST") {
    if (!requireJSON(request)) return json({ error: "Content-Type must be application/json." }, 415);
    return json(await importLegacyReports(env));
  }

  const reportMatch = /^\/api\/admin\/issue-reports\/([0-9a-f-]{36})$/.exec(url.pathname);
  if (reportMatch && request.method === "POST") {
    const { update, response } = await readUpdate(request);
    if (response) return response;
    const existing = await env.ADMIN_DB.prepare(`SELECT id FROM issue_reports WHERE id = ?`).bind(reportMatch[1]).first();
    if (!existing) return json({ error: "Not found." }, 404);
    await env.ADMIN_DB.prepare(
      `UPDATE issue_reports SET status = COALESCE(?, status), admin_note = COALESCE(?, admin_note), updated_at = ? WHERE id = ?`
    ).bind(update.status ?? null, update.note ?? null, Date.now(), reportMatch[1]).run();
    return json({ updated: true });
  }

  if (url.pathname === "/api/admin/app-errors" && request.method === "GET") {
    const status = statusFilter(url);
    const cutoff = Date.now() - ERROR_RETENTION_MS;
    const order = url.searchParams.get("sort") === "count" ? "occurrences DESC, last_seen_at DESC" : "last_seen_at DESC";
    const rows = await env.ADMIN_DB.prepare(
      `SELECT e.*, (SELECT COUNT(*) FROM app_error_users u WHERE u.fingerprint = e.fingerprint AND u.last_seen_at > ?) AS affected_users
       FROM app_errors e WHERE e.last_seen_at > ? ${status ? "AND e.status = ?" : ""} ORDER BY ${order} LIMIT ${LIST_LIMIT}`
    ).bind(Date.now() - PERSONAL_RETENTION_MS, cutoff, ...(status ? [status] : [])).all();
    return json({ errors: (rows.results ?? []).map(appErrorJSON) });
  }

  const errorMatch = /^\/api\/admin\/app-errors\/([0-9a-f]{64})$/.exec(url.pathname);
  if (errorMatch && request.method === "POST") {
    const { update, response } = await readUpdate(request);
    if (response) return response;
    const existing = await env.ADMIN_DB.prepare(`SELECT last_app_version FROM app_errors WHERE fingerprint = ?`).bind(errorMatch[1]).first();
    if (!existing) return json({ error: "Not found." }, 404);
    // Remember how new the newest affected build was when this was closed,
    // so only a still-newer build counts as a regression (see app-errors.js).
    const resolvedAfter = update.status === "resolved" ? existing.last_app_version : null;
    await env.ADMIN_DB.prepare(
      `UPDATE app_errors SET
         status = COALESCE(?, status),
         admin_note = COALESCE(?, admin_note),
         resolved_after_version = COALESCE(?, resolved_after_version),
         updated_at = ?
       WHERE fingerprint = ?`
    ).bind(update.status ?? null, update.note ?? null, resolvedAfter, Date.now(), errorMatch[1]).run();
    return json({ updated: true });
  }

  return null;
}
