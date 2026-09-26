// Internal admin dashboard: ingests RevenueCat's subscription webhooks into
// D1, receives usage pings the app doesn't send yet, and serves the
// aggregate numbers the dashboard page reads. Every route here is reachable
// with no bearer-token check of its own — see ADMIN_SETUP.md for why:
// Cloudflare Access gates /admin and /api/admin/* at the edge (Google-login
// restricted to the site owner), and the RevenueCat webhook is authenticated
// by its own shared secret instead, the same "authenticated a different way
// than the rest of the API" shape as issue-reports.js's unauthenticated
// screenshot GET.
import { checkRateLimit, clientKey } from "./rate-limit.js";
import { json, readJSONLimited } from "./http.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { isExpired } from "./token.js";
import { isRevoked } from "./revocation.js";
import { realSession } from "./session.js";

// CANCELLATION isn't here on purpose: it only means "won't auto-renew", not
// "access ended" — the subscriber stays active until the EXPIRATION event
// that follows at the end of their current period.
const ACTIVATING_EVENT_TYPES = new Set(["INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE", "NON_RENEWING_PURCHASE"]);
const DEACTIVATING_EVENT_TYPES = new Set(["EXPIRATION", "REFUND"]);
const REVENUE_EVENT_TYPES = ["INITIAL_PURCHASE", "RENEWAL", "NON_RENEWING_PURCHASE"];
const DAY_MS = 24 * 60 * 60 * 1000;

// Product id → billing period in months, so a single transaction's price
// can be normalized into a monthly-equivalent run rate (MRR). Empty until
// real App Store Connect products exist — fill in once they do, e.g.
// { "studiquo_pro_monthly": 1, "studiquo_pro_annual": 12 }. A product
// that's active but missing from this map is treated as monthly (months=1)
// rather than dropped, so MRR never silently under-counts a real subscriber.
export const PRODUCT_BILLING_MONTHS = {};

function startOfMonthMs(date = new Date()) {
  return new Date(date.getFullYear(), date.getMonth(), 1).getTime();
}

async function countKVPrefix(env, prefix) {
  let count = 0;
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix, cursor });
    count += page.keys.length;
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return count;
}

async function countIssueReports(env) {
  let count = 0;
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix: "issue-report:", cursor });
    // Every screenshot lives under "issue-report-screenshot:<id>", which
    // also starts with "issue-report" — exclude those, they're not reports.
    count += page.keys.filter(k => !k.name.startsWith("issue-report-screenshot:")).length;
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return count;
}

// Counts real people, not sign-in identities: an Apple account and a Google
// account that share the same verified email are the same person and must
// only be counted once (see oauth-links.js). Reads every account:* record
// to find its email, if any, and groups by that. O(number of accounts) KV
// reads — fine at today's scale; move user records into D1 if this ever
// gets slow enough to matter.
async function countDistinctUsers(env) {
  const groups = new Set();
  let cursor;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix: "account:", cursor });
    const records = await Promise.all(page.keys.map(k => env.STUDIQUO_DATA.get(k.name, "json")));
    records.forEach((record, i) => {
      const email = typeof record?.email === "string" ? record.email.trim().toLowerCase() : null;
      const isPrivateRelay = record?.emailIsPrivateRelay === true;
      groups.add(email && !isPrivateRelay ? `email:${email}` : `identity:${page.keys[i].name}`);
    });
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return groups.size;
}

async function upsertSubscriber(env, appUserId, status, productId, expiresAt) {
  await env.ADMIN_DB.prepare(
    `INSERT INTO subscribers (app_user_id, status, product_id, expires_at, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(app_user_id) DO UPDATE SET
       status = excluded.status, product_id = excluded.product_id,
       expires_at = excluded.expires_at, updated_at = excluded.updated_at`
  ).bind(appUserId, status, productId, expiresAt, Date.now()).run();
}

export async function handleAdminWebhook(url, request, env) {
  if (url.pathname !== "/api/admin/revenuecat-webhook" || request.method !== "POST") return null;

  const allowed = await checkRateLimit(env.RATE_LIMIT_ADMIN_WEBHOOK, clientKey(request));
  if (!allowed) return json({ error: "Too many requests." }, 429);

  const authorization = request.headers.get("authorization") ?? "";
  if (!env.REVENUECAT_WEBHOOK_SECRET || authorization !== env.REVENUECAT_WEBHOOK_SECRET) {
    return json({ error: "Unauthorized." }, 401);
  }

  const body = await readJSONLimited(request, 100_000);
  const event = body?.event;
  if (!event || typeof event.id !== "string" || typeof event.app_user_id !== "string" || typeof event.type !== "string") {
    return json({ error: "Invalid request." }, 400);
  }

  const occurredAt = Number(event.event_timestamp_ms) || Date.now();
  const price = typeof event.price_in_purchased_currency === "number" ? event.price_in_purchased_currency : null;

  await env.ADMIN_DB.prepare(
    `INSERT OR IGNORE INTO revenuecat_events
       (event_id, app_user_id, event_type, period_type, product_id, price_in_purchased_currency, currency, environment, occurred_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    event.id, event.app_user_id, event.type, event.period_type ?? null, event.product_id ?? null,
    price, event.currency ?? null, event.environment ?? "PRODUCTION", occurredAt
  ).run();

  const expiresAt = Number(event.expiration_at_ms) || null;
  if (ACTIVATING_EVENT_TYPES.has(event.type)) {
    await upsertSubscriber(env, event.app_user_id, "active", event.product_id ?? null, expiresAt);
  } else if (event.type === "BILLING_ISSUE") {
    await upsertSubscriber(env, event.app_user_id, "billing_issue", event.product_id ?? null, expiresAt);
  } else if (DEACTIVATING_EVENT_TYPES.has(event.type)) {
    await upsertSubscriber(env, event.app_user_id, "expired", event.product_id ?? null, expiresAt);
  }
  // TRANSFER, TEST, SUBSCRIPTION_PAUSED and anything else are recorded in
  // the log above but don't change subscribers — a transferred entitlement
  // needs both the old and new app_user_id handled together, which the app
  // doesn't have to reconcile until it actually happens.

  return json({ received: true });
}

// POST /api/usage-events: a single "this account used the app" ping. Not
// called by the app yet — the client-side instrumentation is a separate,
// later task — but the receiving end and its table exist now so that work
// is just "call this endpoint" when it happens. Authenticated the normal
// way (a real studiquo bearer token), unlike the two routes above.
export async function handleUsageEvent(url, request, env) {
  if (url.pathname !== "/api/usage-events" || request.method !== "POST") return null;

  const token = bearerToken(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  const session = await realSession(env, token);
  if (!session) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const tokenKey = await sha256Hex(token);
  if (await isRevoked(env, tokenKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

  const allowed = await checkRateLimit(env.RATE_LIMIT_USAGE_EVENT, tokenKey);
  if (!allowed) return json({ error: "Too many requests." }, 429);

  // Keyed off the account (session.sub), not the token itself — a token
  // rotates on every re-login and expires after 90 days (see
  // MCPCloudCredentials.validityPeriod), but DAU/MAU and retention need the
  // same person to keep being the same row across that. Same shape as
  // chat.js's own "chat-account:" / mcp-oauth.js's "mcp-account:" keys,
  // just its own namespace so the three never collide.
  const userKey = await sha256Hex(`usage-account:${session.sub}`);
  const now = Date.now();
  await env.ADMIN_DB.prepare(`INSERT INTO usage_events (id, user_key, occurred_at) VALUES (?, ?, ?)`)
    .bind(crypto.randomUUID(), userKey, now).run();
  await env.ADMIN_DB.prepare(`INSERT INTO users_first_seen (user_key, first_seen_at) VALUES (?, ?) ON CONFLICT(user_key) DO NOTHING`)
    .bind(userKey, now).run();

  return json({ recorded: true });
}

async function countRecentUniqueUsers(env, sinceMs) {
  const row = await env.ADMIN_DB.prepare(`SELECT COUNT(DISTINCT user_key) AS count FROM usage_events WHERE occurred_at >= ?`)
    .bind(sinceMs).first();
  return row?.count ?? 0;
}

// Day-N retention: of everyone first seen at least N days ago, what
// fraction had a usage ping in the 24-hour window that is exactly N days
// after they were first seen. Returns null (not 0) when there's no cohort
// old enough yet to measure, so the dashboard can show "not enough data"
// instead of a misleading 0%.
async function retentionRate(env, dayOffset) {
  const now = Date.now();
  const row = await env.ADMIN_DB.prepare(
    `SELECT COUNT(DISTINCT u.user_key) AS cohortSize,
            COUNT(DISTINCT e.user_key) AS retained
     FROM users_first_seen u
     LEFT JOIN usage_events e
       ON e.user_key = u.user_key
       AND e.occurred_at >= u.first_seen_at + ?
       AND e.occurred_at < u.first_seen_at + ?
     WHERE u.first_seen_at <= ?`
  ).bind(dayOffset * DAY_MS, (dayOffset + 1) * DAY_MS, now - (dayOffset + 1) * DAY_MS).first();
  return row?.cohortSize ? row.retained / row.cohortSize : null;
}

export async function handleAdminStats(url, request, env) {
  if (url.pathname !== "/api/admin/stats" || request.method !== "GET") return null;
  // No auth check here on purpose — see this file's header comment.

  const monthStart = startOfMonthMs();
  const revenuePlaceholders = REVENUE_EVENT_TYPES.map(() => "?").join(",");

  const [
    userCount,
    issueReportCount,
    mcpConnectionCount,
    activeRow,
    billingIssueRow,
    monthRevenueRow,
    monthRefundRow,
    trialStartersRow,
    trialConvertedRow,
    latestPurchasePerActive,
    monthlyTrend,
    dau,
    mau,
    d1Retention,
    d7Retention,
    d30Retention,
  ] = await Promise.all([
    countDistinctUsers(env),
    countIssueReports(env),
    countKVPrefix(env, "mcp:grant:"),
    env.ADMIN_DB.prepare(`SELECT COUNT(*) AS count FROM subscribers WHERE status = 'active'`).first(),
    env.ADMIN_DB.prepare(`SELECT COUNT(*) AS count FROM subscribers WHERE status = 'billing_issue'`).first(),
    env.ADMIN_DB.prepare(
      `SELECT SUM(price_in_purchased_currency) AS total FROM revenuecat_events
       WHERE environment = 'PRODUCTION' AND occurred_at >= ? AND event_type IN (${revenuePlaceholders})`
    ).bind(monthStart, ...REVENUE_EVENT_TYPES).first(),
    env.ADMIN_DB.prepare(
      `SELECT COUNT(*) AS count, SUM(price_in_purchased_currency) AS total FROM revenuecat_events
       WHERE environment = 'PRODUCTION' AND occurred_at >= ? AND event_type = 'REFUND'`
    ).bind(monthStart).first(),
    env.ADMIN_DB.prepare(`SELECT COUNT(DISTINCT app_user_id) AS count FROM revenuecat_events WHERE period_type = 'TRIAL'`).first(),
    env.ADMIN_DB.prepare(
      `SELECT COUNT(DISTINCT app_user_id) AS count FROM revenuecat_events
       WHERE period_type = 'NORMAL' AND app_user_id IN (
         SELECT DISTINCT app_user_id FROM revenuecat_events WHERE period_type = 'TRIAL'
       )`
    ).first(),
    env.ADMIN_DB.prepare(
      `SELECT e.app_user_id AS app_user_id, e.price_in_purchased_currency AS price, e.product_id AS product_id
       FROM subscribers s
       JOIN revenuecat_events e ON e.app_user_id = s.app_user_id
       WHERE s.status = 'active' AND e.event_type IN (${revenuePlaceholders})
         AND e.occurred_at = (
           SELECT MAX(occurred_at) FROM revenuecat_events e2
           WHERE e2.app_user_id = s.app_user_id AND e2.event_type IN (${revenuePlaceholders})
         )`
    ).bind(...REVENUE_EVENT_TYPES, ...REVENUE_EVENT_TYPES).all(),
    env.ADMIN_DB.prepare(
      `SELECT strftime('%Y-%m', occurred_at / 1000, 'unixepoch') AS month,
              SUM(CASE WHEN event_type IN (${revenuePlaceholders}) THEN price_in_purchased_currency ELSE 0 END) AS revenue,
              SUM(CASE WHEN event_type = 'INITIAL_PURCHASE' THEN 1 ELSE 0 END) AS newSubscribers,
              SUM(CASE WHEN event_type = 'EXPIRATION' THEN 1 ELSE 0 END) AS churnedSubscribers
       FROM revenuecat_events
       WHERE environment = 'PRODUCTION'
       GROUP BY month
       ORDER BY month DESC
       LIMIT 12`
    ).bind(...REVENUE_EVENT_TYPES).all(),
    countRecentUniqueUsers(env, Date.now() - DAY_MS),
    countRecentUniqueUsers(env, Date.now() - 30 * DAY_MS),
    retentionRate(env, 1),
    retentionRate(env, 7),
    retentionRate(env, 30),
  ]);

  const mrr = (latestPurchasePerActive.results ?? []).reduce((sum, row) => {
    const months = PRODUCT_BILLING_MONTHS[row.product_id] ?? 1;
    return sum + (row.price ?? 0) / months;
  }, 0);

  const trialStarters = trialStartersRow?.count ?? 0;
  const trialConverted = trialConvertedRow?.count ?? 0;

  return json({
    userCount,
    issueReportCount,
    mcpConnectionCount,
    activeSubscribers: activeRow?.count ?? 0,
    billingIssueCount: billingIssueRow?.count ?? 0,
    mrr,
    monthToDate: {
      revenue: monthRevenueRow?.total ?? 0,
      refundCount: monthRefundRow?.count ?? 0,
      refundTotal: monthRefundRow?.total ?? 0,
    },
    trialConversion: {
      starters: trialStarters,
      converted: trialConverted,
      rate: trialStarters ? trialConverted / trialStarters : null,
    },
    // DAU/MAU and retention stay at 0/null until the app sends usage
    // pings via POST /api/usage-events — see this file's header comment.
    dau,
    mau,
    retention: { d1: d1Retention, d7: d7Retention, d30: d30Retention },
    monthlyTrend: (monthlyTrend.results ?? []).slice().reverse(),
  });
}

// GET /admin: the dashboard page itself — a static, dependency-free HTML
// page that fetches /api/admin/stats and renders it. Gated by Cloudflare
// Access the same way /api/admin/stats is (see this file's header comment),
// so there's no bearer-token check here either.
const DASHBOARD_HTML = `<!doctype html>
<html lang="ja">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>studiquo 管理ダッシュボード</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.3rem; }
  h2 { font-size: 1rem; color: #888; margin: 2rem 0 0.5rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 1rem; }
  .card { border: 1px solid color-mix(in srgb, currentColor 15%, transparent); border-radius: 10px; padding: 1rem; }
  .card .value { font-size: 1.6rem; font-weight: 600; }
  .card .label { color: #888; font-size: 0.85rem; }
  #chart { width: 100%; height: 180px; }
  #error { color: #c33; display: none; }
</style>
<h1>studiquo 管理ダッシュボード</h1>
<p id="error">読み込みに失敗しました。再読み込みしてください。</p>
<div id="root"></div>
<script>
function card(label, value) {
  return '<div class="card"><div class="value">' + value + '</div><div class="label">' + label + '</div></div>';
}
function yen(n) { return '¥' + Math.round(n ?? 0).toLocaleString('ja-JP'); }
function pct(n) { return n == null ? '—' : (n * 100).toFixed(1) + '%'; }

function drawChart(rows) {
  const width = 900, height = 180, pad = 24;
  if (!rows.length) return '';
  const max = Math.max(1, ...rows.map(r => r.revenue ?? 0));
  const barWidth = (width - pad * 2) / rows.length;
  const bars = rows.map((r, i) => {
    const h = ((r.revenue ?? 0) / max) * (height - pad * 2);
    const x = pad + i * barWidth;
    const y = height - pad - h;
    return '<rect x="' + (x + 4) + '" y="' + y + '" width="' + (barWidth - 8) + '" height="' + h + '" rx="3" fill="currentColor" opacity="0.6"></rect>' +
           '<text x="' + (x + barWidth / 2) + '" y="' + (height - 6) + '" text-anchor="middle" font-size="10" fill="currentColor">' + r.month.slice(5) + '</text>';
  }).join('');
  return '<svg id="chart" viewBox="0 0 ' + width + ' ' + height + '">' + bars + '</svg>';
}

fetch('/api/admin/stats').then(r => {
  if (!r.ok) throw new Error('bad response');
  return r.json();
}).then(stats => {
  document.getElementById('root').innerHTML =
    '<div class="grid">' +
      card('ユーザー数', stats.userCount) +
      card('アクティブサブスク', stats.activeSubscribers) +
      card('未対応エラー報告', stats.issueReportCount) +
      card('MCP連携数', stats.mcpConnectionCount) +
    '</div>' +
    '<h2>売上(RevenueCat)</h2>' +
    '<div class="grid">' +
      card('今月の売上', yen(stats.monthToDate.revenue)) +
      card('MRR(月次換算)', yen(stats.mrr)) +
      card('支払い保留中', stats.billingIssueCount) +
      card('今月の返金', stats.monthToDate.refundCount + '件 / ' + yen(stats.monthToDate.refundTotal)) +
      card('トライアル転換率', pct(stats.trialConversion.rate)) +
    '</div>' +
    '<h2>利用状況</h2>' +
    '<div class="grid">' +
      card('DAU', stats.dau) +
      card('MAU', stats.mau) +
      card('D1リテンション', pct(stats.retention.d1)) +
      card('D7リテンション', pct(stats.retention.d7)) +
      card('D30リテンション', pct(stats.retention.d30)) +
    '</div>' +
    '<h2>月別売上の推移</h2>' +
    drawChart(stats.monthlyTrend);
}).catch(() => {
  document.getElementById('error').style.display = 'block';
});
</script>
</html>`;

export function handleAdminPage(url) {
  if (url.pathname !== "/admin" && url.pathname !== "/admin/") return null;
  return new Response(DASHBOARD_HTML, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}
