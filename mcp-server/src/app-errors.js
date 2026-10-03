// Receives the app's own error reports — crashes, hangs and a few known
// non-fatal failures — and folds them into one dashboard row per distinct
// problem. Authenticated like any other app call (a real studiquo bearer
// token); the dashboard side lives in admin-reports.js.
//
// What a report may contain is deliberately narrow: an error kind, a short
// title, a stable signature (what makes two reports "the same problem") and
// a trimmed technical detail such as exception type and call-site symbols.
// The app never puts note, chat or account content in there, and this file
// bounds every field so a misbehaving client can't turn the dashboard into
// a dumping ground.
import { isRevoked } from "./revocation.js";
import { isExpired } from "./token.js";
import { checkRateLimit } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited } from "./http.js";
import { realSession } from "./session.js";
import { postSlackBlocks } from "./slack.js";

const MAX_BODY = 200_000;
const MAX_ERRORS_PER_REQUEST = 20;
const MAX_SLACK_POSTS_PER_REQUEST = 5;
const MAX_COUNT = 1_000;
const KINDS = new Set(["crash", "hang", "cpu", "disk", "error"]);
const KIND_LABELS = { crash: "クラッシュ", hang: "フリーズ", cpu: "CPU過負荷", disk: "ディスク書き込み過多", error: "エラー" };

function truncate(value, max) {
  return typeof value === "string" ? value.slice(0, max) : "";
}

// "1.4.0 (23)" -> [1, 4, 0, 23]. Missing parts compare as 0.
export function versionParts(version) {
  return (String(version ?? "").match(/\d+/g) ?? []).map(Number);
}

export function compareVersions(a, b) {
  const left = versionParts(a);
  const right = versionParts(b);
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    const difference = (left[i] ?? 0) - (right[i] ?? 0);
    if (difference !== 0) return difference < 0 ? -1 : 1;
  }
  return 0;
}

function describeContext(error) {
  return [
    error.appVersion && `v${error.appVersion}`,
    error.osVersion && `iOS ${error.osVersion}`,
    error.deviceModel,
  ].filter(Boolean).join(" ・ ");
}

async function notify(env, origin, outcome, row, error) {
  const label = KIND_LABELS[row.kind] ?? "エラー";
  const headline = outcome === "new" ? `🆕 新しい${label}` : `🔁 ${label}が再発`;
  await postSlackBlocks(env, [
    { type: "header", text: { type: "plain_text", text: headline, emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: row.title } },
    { type: "context", elements: [{ type: "mrkdwn", text: describeContext(error) || "端末情報なし" }] },
    { type: "context", elements: [{ type: "mrkdwn", text: `<${origin}/admin#errors|ダッシュボードで開く>` }] },
  ]);
}

// Folds one occurrence (or one device's batch of `count` of them) into the
// problem's row. Returns "new" | "reopened" | null so the caller knows
// whether it is worth a Slack message: only a first sighting and a
// regression are — a problem that is already known and open, or that only
// old builds still hit, stays quiet.
async function recordOccurrence(env, fingerprint, error, userKey, now) {
  const existing = await env.ADMIN_DB.prepare(
    `SELECT status, resolved_after_version, last_seen_at, last_app_version FROM app_errors WHERE fingerprint = ?`
  ).bind(fingerprint).first();

  if (!existing) {
    await env.ADMIN_DB.prepare(
      `INSERT INTO app_errors
         (fingerprint, kind, title, detail, first_seen_at, last_seen_at, occurrences,
          last_app_version, last_os_version, last_device_model, status, admin_note, resolved_after_version, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', '', '', ?)`
    ).bind(
      fingerprint, error.kind, error.title, error.detail, error.occurredAt, error.occurredAt, error.count,
      error.appVersion, error.osVersion, error.deviceModel, now
    ).run();
    await recordAffectedUser(env, fingerprint, userKey);
    return "new";
  }

  const reopens = existing.status === "resolved" && (
    !existing.resolved_after_version || compareVersions(error.appVersion, existing.resolved_after_version) > 0
  );
  // A delayed report (a crash from before an update, delivered after it)
  // must not make the row's "latest build" go backwards.
  const isNewest = error.occurredAt >= existing.last_seen_at;
  await env.ADMIN_DB.prepare(
    `UPDATE app_errors SET
       occurrences = occurrences + ?,
       last_seen_at = MAX(last_seen_at, ?),
       last_app_version = CASE WHEN ? THEN ? ELSE last_app_version END,
       last_os_version = CASE WHEN ? THEN ? ELSE last_os_version END,
       last_device_model = CASE WHEN ? THEN ? ELSE last_device_model END,
       status = CASE WHEN ? THEN 'open' ELSE status END,
       updated_at = ?
     WHERE fingerprint = ?`
  ).bind(
    error.count, error.occurredAt,
    isNewest ? 1 : 0, error.appVersion,
    isNewest ? 1 : 0, error.osVersion,
    isNewest ? 1 : 0, error.deviceModel,
    reopens ? 1 : 0, now, fingerprint
  ).run();
  await recordAffectedUser(env, fingerprint, userKey);
  return reopens ? "reopened" : null;
}

async function recordAffectedUser(env, fingerprint, userKey) {
  await env.ADMIN_DB.prepare(`INSERT OR IGNORE INTO app_error_users (fingerprint, user_key) VALUES (?, ?)`)
    .bind(fingerprint, userKey).run();
}

function normalize(raw, defaults, now) {
  if (!raw || typeof raw !== "object") return null;
  const signature = truncate(raw.signature, 500).trim();
  const title = truncate(raw.title, 200).trim();
  if (!signature || !title) return null;
  const kind = KINDS.has(raw.kind) ? raw.kind : "error";
  const count = Math.min(MAX_COUNT, Math.max(1, Math.floor(Number(raw.count)) || 1));
  // The device's clock can be wrong; never accept a time in the future.
  const occurredAt = Math.min(now, Number.isFinite(Number(raw.occurredAt)) && Number(raw.occurredAt) > 0 ? Number(raw.occurredAt) : now);
  return {
    kind,
    signature,
    title,
    detail: truncate(raw.detail, 6_000),
    count,
    occurredAt,
    appVersion: truncate(raw.appVersion, 40) || defaults.appVersion,
    osVersion: truncate(raw.osVersion, 40) || defaults.osVersion,
    deviceModel: truncate(raw.deviceModel, 60) || defaults.deviceModel,
  };
}

export async function handleAppErrors(url, request, env) {
  if (url.pathname !== "/api/app-errors" || request.method !== "POST") return null;

  const token = bearerToken(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  const session = await realSession(env, token);
  if (!session) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const tokenKey = await sha256Hex(token);
  if (await isRevoked(env, tokenKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

  const allowed = await checkRateLimit(env.RATE_LIMIT_APP_ERROR, tokenKey);
  if (!allowed) return json({ error: "Too many requests." }, 429);

  const body = await readJSONLimited(request, MAX_BODY);
  if (!body || !Array.isArray(body.errors)) return json({ error: "Invalid request." }, 400);
  if (!env.ADMIN_DB) return json({ error: "Unavailable." }, 503);

  const now = Date.now();
  const defaults = {
    appVersion: truncate(body.appVersion, 40),
    osVersion: truncate(body.osVersion, 40),
    deviceModel: truncate(body.deviceModel, 60),
  };
  const errors = body.errors.slice(0, MAX_ERRORS_PER_REQUEST).map(raw => normalize(raw, defaults, now)).filter(Boolean);
  // Same account hash as usage_events, so deleting the account removes it too.
  const userKey = await sha256Hex(`usage-account:${session.sub}`);

  let accepted = 0;
  let slackPosts = 0;
  for (const error of errors) {
    const fingerprint = await sha256Hex(`${error.kind}\n${error.signature}`);
    const outcome = await recordOccurrence(env, fingerprint, error, userKey, now);
    accepted += 1;
    if (outcome && slackPosts < MAX_SLACK_POSTS_PER_REQUEST) {
      slackPosts += 1;
      await notify(env, url.origin, outcome, { kind: error.kind, title: error.title }, error);
    }
  }
  return json({ received: true, accepted });
}
