// Operator announcements: written in the internal admin page, stored in D1,
// and read by the app's お知らせ inbox. Two audiences, two gates:
//
//   /admin/announcements (the page)  — behind Cloudflare Access at the edge.
//   /api/admin/announcements*        — verified HERE: the Access JWT (header or
//     CF_Authorization cookie) must validate against ACCESS_AUD /
//     ACCESS_TEAM_DOMAIN, and with those unset every request is refused.
//   GET /api/announcements — public and read-only. It carries nothing
//     personal, and a maintenance notice should be readable even when the
//     person can't sign in. Rate-limited per IP.
//
// Adding a language: add one entry to SUPPORTED_LANGUAGES. Nothing else —
// storage, the admin form and the app's fallback logic are all driven by
// language codes, not by a fixed pair.
import { accessAllowed } from "./access.js";
import { checkRateLimit, clientKey } from "./rate-limit.js";
import { json, readJSONLimited, securityHeaders } from "./http.js";
import { deviceStorageKey, loadDevices } from "./devices.js";
import { sendPush } from "./push.js";

export const SUPPORTED_LANGUAGES = [
  { code: "ja", label: "日本語" },
  { code: "en", label: "English" },
];
// Every announcement must carry this language, so the lookup always has
// something to fall back to.
export const REQUIRED_LANGUAGE = "ja";
// Tried (in order) after the requested language and its base language.
export const FALLBACK_LANGUAGES = ["en", REQUIRED_LANGUAGE];

export const KINDS = ["update", "maintenance", "important", "news"];
export const STATUSES = ["draft", "published", "archived"];
// Kinds that may be pushed. "news" is promotional, which App Review only
// allows for people who opted in — those stay in the in-app inbox.
export const PUSHABLE_KINDS = ["update", "maintenance", "important"];
// Users per batch: each user costs one KV read plus one APNs call per device,
// and a Worker invocation has a bounded number of subrequests.
const DEFAULT_PUSH_BATCH_USERS = 20;
const PUSH_BODY_PREVIEW = 140;
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

const MAX_TITLE = 100;
const MAX_BODY = 4_000;
const MAX_LINK = 500;
const MAX_ADMIN_BODY = 60_000;
const PUBLIC_LIMIT = 50;
const LANG_PATTERN = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/;
const VERSION_PATTERN = /^\d{1,4}(\.\d{1,4}){0,2}$/;

/** "1.10" vs "1.9" → compares numerically per component; missing parts are 0. */
export function compareVersions(a, b) {
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  return 0;
}

/**
 * Picks which translation to show: the exact language, then its base
 * language (zh-Hans → zh), then FALLBACK_LANGUAGES, then anything at all.
 * `translations` is { [lang]: { title, body } }; returns { lang, title, body }.
 */
export function resolveTranslation(translations, requested) {
  const codes = Object.keys(translations);
  const candidates = [];
  if (requested && LANG_PATTERN.test(requested)) {
    const lower = requested.toLowerCase();
    const exact = codes.find(code => code.toLowerCase() === lower);
    if (exact) candidates.push(exact);
    const base = lower.split("-")[0];
    const baseMatch = codes.find(code => code.toLowerCase() === base);
    if (baseMatch) candidates.push(baseMatch);
  }
  candidates.push(...FALLBACK_LANGUAGES, ...codes);
  const lang = candidates.find(code => translations[code]);
  return lang ? { lang, ...translations[lang] } : null;
}

function cleanString(value, max) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= max ? trimmed : null;
}

function optionalVersion(value) {
  if (value === undefined || value === null || value === "") return { ok: true, value: null };
  return typeof value === "string" && VERSION_PATTERN.test(value.trim())
    ? { ok: true, value: value.trim() }
    : { ok: false };
}

function optionalTimestamp(value) {
  if (value === undefined || value === null) return { ok: true, value: null };
  return Number.isSafeInteger(value) && value > 0 ? { ok: true, value } : { ok: false };
}

function optionalLink(value) {
  if (value === undefined || value === null || value === "") return { ok: true, value: null };
  if (typeof value !== "string" || value.length > MAX_LINK) return { ok: false };
  try {
    return new URL(value).protocol === "https:" ? { ok: true, value } : { ok: false };
  } catch {
    return { ok: false };
  }
}

// Validates an admin create/update body. Returns { error } or { value }.
function parseAnnouncement(body, now) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "Invalid request." };
  if (!KINDS.includes(body.kind)) return { error: "Invalid kind." };
  if (!STATUSES.includes(body.status)) return { error: "Invalid status." };

  const link = optionalLink(body.link);
  const minVersion = optionalVersion(body.minAppVersion);
  const maxVersion = optionalVersion(body.maxAppVersion);
  const publishAt = optionalTimestamp(body.publishAt);
  const expiresAt = optionalTimestamp(body.expiresAt);
  if (!link.ok) return { error: "link must be an https URL." };
  if (!minVersion.ok || !maxVersion.ok) return { error: "Invalid app version." };
  if (minVersion.value && maxVersion.value && compareVersions(minVersion.value, maxVersion.value) > 0) {
    return { error: "minAppVersion is greater than maxAppVersion." };
  }
  if (!publishAt.ok || !expiresAt.ok) return { error: "Invalid timestamp." };

  if (!body.translations || typeof body.translations !== "object" || Array.isArray(body.translations)) {
    return { error: "translations is required." };
  }
  const translations = {};
  for (const [lang, entry] of Object.entries(body.translations)) {
    if (!LANG_PATTERN.test(lang)) return { error: `Invalid language code: ${lang}` };
    const rawTitle = typeof entry?.title === "string" ? entry.title.trim() : "";
    const rawBody = typeof entry?.body === "string" ? entry.body.trim() : "";
    // An entirely empty language is just "not translated yet" — drop it.
    // A half-filled one is a mistake the admin should hear about.
    if (!rawTitle && !rawBody) continue;
    const title = cleanString(rawTitle, MAX_TITLE);
    const text = cleanString(rawBody, MAX_BODY);
    if (!title || !text) return { error: `Title and body are both required for ${lang}.` };
    translations[lang] = { title, body: text };
  }
  if (!translations[REQUIRED_LANGUAGE]) return { error: `A ${REQUIRED_LANGUAGE} translation is required.` };

  const status = body.status;
  const resolvedPublishAt = status === "published" ? (publishAt.value ?? now) : publishAt.value;
  if (resolvedPublishAt && expiresAt.value && expiresAt.value <= resolvedPublishAt) {
    return { error: "expiresAt must be after publishAt." };
  }
  return {
    value: {
      kind: body.kind,
      status,
      link: link.value,
      minAppVersion: minVersion.value,
      maxAppVersion: maxVersion.value,
      publishAt: resolvedPublishAt,
      expiresAt: expiresAt.value,
      translations,
    },
  };
}

async function writeTranslations(env, id, translations) {
  await env.ADMIN_DB.prepare(`DELETE FROM announcement_translations WHERE announcement_id = ?`).bind(id).run();
  for (const [lang, { title, body }] of Object.entries(translations)) {
    await env.ADMIN_DB.prepare(
      `INSERT INTO announcement_translations (announcement_id, lang, title, body) VALUES (?, ?, ?, ?)`
    ).bind(id, lang, title, body).run();
  }
}

async function loadTranslationMap(env, ids) {
  const byId = new Map(ids.map(id => [id, {}]));
  if (ids.length === 0) return byId;
  const placeholders = ids.map(() => "?").join(",");
  const rows = await env.ADMIN_DB.prepare(
    `SELECT announcement_id, lang, title, body FROM announcement_translations WHERE announcement_id IN (${placeholders})`
  ).bind(...ids).all();
  for (const row of rows.results ?? []) {
    byId.get(row.announcement_id)[row.lang] = { title: row.title, body: row.body };
  }
  return byId;
}

function adminShape(row, translations) {
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    link: row.link,
    minAppVersion: row.min_app_version,
    maxAppVersion: row.max_app_version,
    publishAt: row.publish_at,
    expiresAt: row.expires_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    pushable: PUSHABLE_KINDS.includes(row.kind),
    pushState: row.push_state ?? null,
    pushUsers: row.push_users ?? 0,
    pushDelivered: row.push_delivered ?? 0,
    pushFailed: row.push_failed ?? 0,
    pushSentAt: row.push_sent_at ?? null,
    translations,
  };
}

// ---- Push ---------------------------------------------------------------

function previewBody(text) {
  const chars = Array.from(text);
  return chars.length <= PUSH_BODY_PREVIEW ? text : `${chars.slice(0, PUSH_BODY_PREVIEW).join("")}…`;
}

/**
 * Pushes `translations` to `devices`, each device in its own language
 * (devices that never reported one get the fallback chain). One sendPush per
 * resolved language. Returns { delivered, failed }.
 */
async function pushToDevices(env, userKey, announcement, translations, devices, options, titlePrefix = "") {
  const groups = new Map();
  for (const device of devices) {
    const text = resolveTranslation(translations, device.language);
    if (!text) continue;
    if (!groups.has(text.lang)) groups.set(text.lang, { text, devices: [] });
    groups.get(text.lang).devices.push(device);
  }
  let delivered = 0;
  let failed = 0;
  for (const { text, devices: group } of groups.values()) {
    const results = await sendPush(env, userKey, {
      category: "announcement",
      threadID: "announcement",
      title: `${titlePrefix}${text.title}`,
      body: previewBody(text.body),
      data: { route: "announcement", announcementID: announcement.id },
    }, { devices: group, fetchImpl: options.fetchImpl });
    delivered += results.filter(result => result.delivered).length;
    failed += results.filter(result => !result.delivered).length;
  }
  return { delivered, failed };
}

function pushResponse(row) {
  return {
    state: row.push_state,
    users: row.push_users,
    delivered: row.push_delivered,
    failed: row.push_failed,
    done: row.push_state === "sent",
  };
}

// POST /api/admin/announcements/:id/push — sends ONE batch and reports
// progress; the admin page keeps calling until `done`. Safe to repeat or to
// resume after a closed tab: the batch counter's compare-and-set means a
// batch is only ever claimed by one request.
async function pushBatch(env, id, options, now) {
  let row = await env.ADMIN_DB.prepare(`SELECT * FROM announcements WHERE id = ?`).bind(id).first();
  if (!row) return json({ error: "Not found." }, 404);
  if (!PUSHABLE_KINDS.includes(row.kind)) return json({ error: "This kind is not pushed." }, 400);
  if (row.status !== "published" || !row.publish_at || row.publish_at > now || (row.expires_at && row.expires_at <= now)) {
    return json({ error: "Only a live published announcement can be pushed." }, 400);
  }
  if (row.push_state === "sent") return json({ error: "Already pushed.", ...pushResponse(row) }, 409);

  if (row.push_state === null) {
    const started = await env.ADMIN_DB.prepare(
      `UPDATE announcements SET push_state = 'sending', push_started_at = ? WHERE id = ? AND push_state IS NULL`
    ).bind(now, id).run();
    if (!started.meta?.changes) return json({ error: "Another push just started." }, 409);
    row = { ...row, push_state: "sending" };
  }

  const batchSize = Number(env.ANNOUNCEMENT_PUSH_BATCH) > 0 ? Number(env.ANNOUNCEMENT_PUSH_BATCH) : DEFAULT_PUSH_BATCH_USERS;
  const page = await env.STUDIQUO_DATA.list({
    prefix: deviceStorageKey(""), cursor: row.push_cursor || undefined, limit: batchSize,
  });
  const complete = page.list_complete;
  const claimed = await env.ADMIN_DB.prepare(
    `UPDATE announcements SET push_cursor = ?, push_batches = push_batches + 1
     WHERE id = ? AND push_state = 'sending' AND push_batches = ?`
  ).bind(complete ? "" : page.cursor, id, row.push_batches).run();
  if (!claimed.meta?.changes) return json({ error: "Another batch is in progress. Try again." }, 409);

  const translations = (await loadTranslationMap(env, [id])).get(id);
  let delivered = 0;
  let failed = 0;
  let users = 0;
  const prefixLength = deviceStorageKey("").length;
  for (const key of page.keys) {
    const userKey = key.name.slice(prefixLength);
    const devices = await loadDevices(env, userKey);
    if (devices.length === 0) continue;
    users += 1;
    const result = await pushToDevices(env, userKey, row, translations, devices, options);
    delivered += result.delivered;
    failed += result.failed;
  }

  await env.ADMIN_DB.prepare(
    `UPDATE announcements SET push_users = push_users + ?, push_delivered = push_delivered + ?, push_failed = push_failed + ?,
       push_state = ?, push_sent_at = ? WHERE id = ?`
  ).bind(users, delivered, failed, complete ? "sent" : "sending", complete ? now : null, id).run();
  row = await env.ADMIN_DB.prepare(`SELECT * FROM announcements WHERE id = ?`).bind(id).first();
  return json(pushResponse(row));
}

// POST /api/admin/announcements/:id/push-test {friendCode} — pushes to one
// person's devices only (the operator's own, via the friend code shown in the
// app's profile). Works on drafts and never touches the real push state.
async function pushTest(env, id, request, options) {
  const body = await readJSONLimited(request, 1_000);
  const code = String(body?.friendCode ?? "").trim().toUpperCase();
  if (!FRIEND_CODE_PATTERN.test(code)) return json({ error: "Invalid friend code." }, 400);
  const row = await env.ADMIN_DB.prepare(`SELECT * FROM announcements WHERE id = ?`).bind(id).first();
  if (!row) return json({ error: "Not found." }, 404);
  const userKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
  if (!userKey) return json({ error: "No user has that friend code." }, 404);
  const devices = await loadDevices(env, userKey);
  if (devices.length === 0) return json({ error: "That user has no push-enabled device." }, 404);
  const translations = (await loadTranslationMap(env, [id])).get(id);
  const result = await pushToDevices(env, userKey, row, translations, devices, options, "[テスト] ");
  return json({ devices: devices.length, ...result });
}

async function handleAdminAnnouncements(url, request, env, options) {
  const match = url.pathname.match(/^\/api\/admin\/announcements(?:\/([A-Za-z0-9-]{1,64}))?(?:\/(push|push-test))?$/);
  if (!match) return null;
  if (!(await accessAllowed(request, env))) return json({ error: "Forbidden." }, 403);
  const id = match[1];
  const now = Date.now();

  if (id && match[2]) {
    if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);
    return match[2] === "push" ? pushBatch(env, id, options, now) : pushTest(env, id, request, options);
  }

  if (!id && request.method === "GET") {
    const rows = await env.ADMIN_DB.prepare(
      `SELECT * FROM announcements ORDER BY COALESCE(publish_at, created_at) DESC LIMIT 200`
    ).all();
    const results = rows.results ?? [];
    const translations = await loadTranslationMap(env, results.map(row => row.id));
    return json({
      languages: SUPPORTED_LANGUAGES,
      requiredLanguage: REQUIRED_LANGUAGE,
      kinds: KINDS,
      announcements: results.map(row => adminShape(row, translations.get(row.id))),
    });
  }

  if (!id && request.method === "POST") {
    const parsed = parseAnnouncement(await readJSONLimited(request, MAX_ADMIN_BODY), now);
    if (parsed.error) return json({ error: parsed.error }, 400);
    const a = parsed.value;
    const newID = crypto.randomUUID();
    await env.ADMIN_DB.prepare(
      `INSERT INTO announcements (id, kind, status, link, min_app_version, max_app_version, publish_at, expires_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(newID, a.kind, a.status, a.link, a.minAppVersion, a.maxAppVersion, a.publishAt, a.expiresAt, now, now).run();
    await writeTranslations(env, newID, a.translations);
    return json({ id: newID }, 201);
  }

  if (id && request.method === "PUT") {
    const existing = await env.ADMIN_DB.prepare(`SELECT id FROM announcements WHERE id = ?`).bind(id).first();
    if (!existing) return json({ error: "Not found." }, 404);
    const parsed = parseAnnouncement(await readJSONLimited(request, MAX_ADMIN_BODY), now);
    if (parsed.error) return json({ error: parsed.error }, 400);
    const a = parsed.value;
    await env.ADMIN_DB.prepare(
      `UPDATE announcements SET kind = ?, status = ?, link = ?, min_app_version = ?, max_app_version = ?,
         publish_at = ?, expires_at = ?, updated_at = ? WHERE id = ?`
    ).bind(a.kind, a.status, a.link, a.minAppVersion, a.maxAppVersion, a.publishAt, a.expiresAt, now, id).run();
    await writeTranslations(env, id, a.translations);
    return json({ id });
  }

  if (id && request.method === "DELETE") {
    await env.ADMIN_DB.prepare(`DELETE FROM announcement_translations WHERE announcement_id = ?`).bind(id).run();
    await env.ADMIN_DB.prepare(`DELETE FROM announcements WHERE id = ?`).bind(id).run();
    return json({ deleted: true });
  }

  return json({ error: "Method not allowed." }, 405);
}

// GET /api/announcements?lang=<bcp47>&appVersion=<x.y.z>: what the app's
// inbox shows. Only published, already-live, not-expired items whose version
// range includes the caller; each comes back in the best available language.
async function handlePublicAnnouncements(url, request, env) {
  if (url.pathname !== "/api/announcements" || request.method !== "GET") return null;
  const allowed = await checkRateLimit(env.RATE_LIMIT_ANNOUNCEMENTS, clientKey(request));
  if (!allowed) return json({ error: "Too many requests." }, 429);

  const requestedLang = url.searchParams.get("lang") ?? "";
  const appVersion = url.searchParams.get("appVersion");
  const callerVersion = appVersion && VERSION_PATTERN.test(appVersion) ? appVersion : null;
  const now = Date.now();

  const rows = await env.ADMIN_DB.prepare(
    `SELECT * FROM announcements
     WHERE status = 'published' AND publish_at <= ? AND (expires_at IS NULL OR expires_at > ?)
     ORDER BY publish_at DESC LIMIT ?`
  ).bind(now, now, PUBLIC_LIMIT).all();
  const results = (rows.results ?? []).filter(row =>
    callerVersion === null ||
    ((!row.min_app_version || compareVersions(callerVersion, row.min_app_version) >= 0) &&
     (!row.max_app_version || compareVersions(callerVersion, row.max_app_version) <= 0))
  );
  const translations = await loadTranslationMap(env, results.map(row => row.id));

  const announcements = results.flatMap(row => {
    const text = resolveTranslation(translations.get(row.id), requestedLang);
    return text ? [{
      id: row.id,
      kind: row.kind,
      title: text.title,
      body: text.body,
      lang: text.lang,
      link: row.link,
      publishedAt: row.publish_at,
    }] : [];
  });
  return Response.json({ announcements }, {
    headers: securityHeaders({ "cache-control": "public, max-age=60" }),
  });
}

// `options.fetchImpl` swaps the APNs transport (tests only).
export async function handleAnnouncements(url, request, env, options = {}) {
  return (await handlePublicAnnouncements(url, request, env)) ?? (await handleAdminAnnouncements(url, request, env, options));
}

// ---- Admin page -----------------------------------------------------------

const ADMIN_PAGE_HTML = `<!doctype html>
<html lang="ja">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>studiquo お知らせ管理</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.3rem; } h2 { font-size: 1rem; color: #888; margin: 2rem 0 .5rem; }
  .box { border: 1px solid color-mix(in srgb, currentColor 15%, transparent); border-radius: 10px; padding: 1rem; margin-bottom: 1rem; }
  label { display: block; font-size: .85rem; color: #888; margin: .6rem 0 .2rem; }
  input, select, textarea, button { font: inherit; padding: .4rem .6rem; border-radius: 6px; border: 1px solid color-mix(in srgb, currentColor 30%, transparent); background: transparent; color: inherit; }
  input[type=text], input[type=url], textarea { width: 100%; box-sizing: border-box; }
  textarea { min-height: 6rem; }
  .row { display: flex; gap: 1rem; flex-wrap: wrap; } .row > div { flex: 1; min-width: 160px; }
  .lang { border-top: 1px dashed color-mix(in srgb, currentColor 25%, transparent); margin-top: .8rem; padding-top: .2rem; }
  .req { color: #c33; font-size: .75rem; }
  .item { display: flex; justify-content: space-between; gap: 1rem; align-items: center; padding: .5rem 0; border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent); }
  .tag { font-size: .75rem; border-radius: 999px; padding: .1rem .5rem; background: color-mix(in srgb, currentColor 12%, transparent); }
  #error { color: #c33; min-height: 1.4em; }
  button.primary { background: #2f6fed; color: #fff; border-color: #2f6fed; } button.danger { color: #c33; }
</style>
<h1>お知らせ管理</h1>
<p><a href="/admin">← ダッシュボード</a></p>
<div class="box">
  <strong id="formTitle">新規作成</strong>
  <div class="row">
    <div><label>種別</label><select id="kind"></select></div>
    <div><label>状態</label><select id="status">
      <option value="draft">下書き</option><option value="published">公開</option><option value="archived">終了</option></select></div>
  </div>
  <div class="row">
    <div><label>公開日時(空欄=今すぐ)</label><input type="datetime-local" id="publishAt"></div>
    <div><label>掲載期限(任意)</label><input type="datetime-local" id="expiresAt"></div>
  </div>
  <div class="row">
    <div><label>対象バージョン 下限(任意・例 1.2)</label><input type="text" id="minAppVersion"></div>
    <div><label>対象バージョン 上限(任意)</label><input type="text" id="maxAppVersion"></div>
  </div>
  <label>リンク(任意・https のみ)</label><input type="url" id="link" placeholder="https://apps.apple.com/...">
  <div id="langs"></div>
  <p id="error"></p>
  <button class="primary" id="save">保存</button> <button id="reset">新規に戻す</button>
</div>
<h2>一覧</h2>
<div id="list" class="box"></div>
<script>
let meta = { languages: [], requiredLanguage: 'ja', kinds: [] };
let items = [];
let editingID = null;
const $ = id => document.getElementById(id);
const KIND_LABELS = { update: 'アップデート', maintenance: 'メンテナンス', important: '重要', news: 'お知らせ' };
const STATUS_LABELS = { draft: '下書き', published: '公開', archived: '終了' };
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const toLocal = ms => { if (!ms) return ''; const d = new Date(ms - new Date(ms).getTimezoneOffset() * 60000); return d.toISOString().slice(0, 16); };
const fromLocal = v => v ? new Date(v).getTime() : null;

function buildForm() {
  $('kind').innerHTML = meta.kinds.map(k => '<option value="' + k + '">' + (KIND_LABELS[k] || k) + '</option>').join('');
  $('langs').innerHTML = meta.languages.map(l =>
    '<div class="lang"><strong>' + esc(l.label) + ' (' + esc(l.code) + ')</strong>' +
    (l.code === meta.requiredLanguage ? ' <span class="req">必須</span>' : ' <span class="req" style="color:#888">未入力なら他言語を表示</span>') +
    '<label>タイトル</label><input type="text" maxlength="100" id="title-' + l.code + '">' +
    '<label>本文</label><textarea maxlength="4000" id="body-' + l.code + '"></textarea></div>').join('');
}

function fillForm(a) {
  editingID = a ? a.id : null;
  $('formTitle').textContent = a ? '編集' : '新規作成';
  $('kind').value = a ? a.kind : meta.kinds[0];
  $('status').value = a ? a.status : 'draft';
  $('publishAt').value = a ? toLocal(a.publishAt) : '';
  $('expiresAt').value = a ? toLocal(a.expiresAt) : '';
  $('minAppVersion').value = a?.minAppVersion ?? '';
  $('maxAppVersion').value = a?.maxAppVersion ?? '';
  $('link').value = a?.link ?? '';
  for (const l of meta.languages) {
    $('title-' + l.code).value = a?.translations[l.code]?.title ?? '';
    $('body-' + l.code).value = a?.translations[l.code]?.body ?? '';
  }
  $('error').textContent = '';
}

function pushCell(a) {
  if (!a.pushable) return '<small>プッシュ対象外の種別</small>';
  if (a.pushState === 'sent') return '<small>送信済み(' + a.pushDelivered + '件成功 / ' + a.pushFailed + '件失敗)</small>';
  if (a.status !== 'published') return '<small>公開するとプッシュ可</small>';
  return '<button data-push="' + a.id + '">' + (a.pushState === 'sending' ? 'プッシュを再開' : 'プッシュ送信') + '</button>';
}

function render() {
  $('list').innerHTML = items.length ? items.map(a => {
    const t = a.translations[meta.requiredLanguage] || Object.values(a.translations)[0] || {};
    return '<div class="item"><div><span class="tag">' + (KIND_LABELS[a.kind] || a.kind) + '</span> <span class="tag">' + STATUS_LABELS[a.status] +
      '</span> ' + esc(t.title) + '<br><small>' + Object.keys(a.translations).join(' / ') + (a.publishAt ? ' ・ ' + new Date(a.publishAt).toLocaleString() : '') +
      '</small><br>' + pushCell(a) + (a.pushable ? ' <button data-test="' + a.id + '">テスト送信</button>' : '') + ' <small id="progress-' + a.id + '"></small>' +
      '</div><div><button data-edit="' + a.id + '">編集</button> <button class="danger" data-del="' + a.id + '">削除</button></div></div>';
  }).join('') : '<small>まだありません。</small>';
}

async function runPush(id) {
  const progress = $('progress-' + id);
  for (;;) {
    const r = await fetch('/api/admin/announcements/' + id + '/push', { method: 'POST' });
    const data = await r.json().catch(() => ({}));
    if (!r.ok && r.status !== 409) { progress.textContent = data.error || '送信に失敗しました。'; return; }
    if (r.status === 409 && !data.done) { progress.textContent = data.error || '他の送信が進行中です。'; return; }
    progress.textContent = '送信中… ' + data.users + '人 / 成功 ' + data.delivered + ' / 失敗 ' + data.failed;
    if (data.done) break;
  }
  await load();
}

async function load() {
  const r = await fetch('/api/admin/announcements');
  if (!r.ok) throw new Error();
  const data = await r.json();
  meta = data; items = data.announcements;
  if (!$('kind').options.length) { buildForm(); fillForm(null); }
  render();
}

$('save').onclick = async () => {
  const translations = {};
  for (const l of meta.languages) translations[l.code] = { title: $('title-' + l.code).value, body: $('body-' + l.code).value };
  const payload = {
    kind: $('kind').value, status: $('status').value, link: $('link').value.trim() || null,
    minAppVersion: $('minAppVersion').value.trim() || null, maxAppVersion: $('maxAppVersion').value.trim() || null,
    publishAt: fromLocal($('publishAt').value), expiresAt: fromLocal($('expiresAt').value), translations
  };
  if (payload.status === 'published' && !confirm('公開すると、アプリのお知らせ一覧にすぐ表示されます。公開しますか?')) return;
  const r = await fetch('/api/admin/announcements' + (editingID ? '/' + editingID : ''), {
    method: editingID ? 'PUT' : 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload)
  });
  if (!r.ok) { $('error').textContent = (await r.json().catch(() => ({}))).error || '保存に失敗しました。'; return; }
  fillForm(null); await load();
};
$('reset').onclick = () => fillForm(null);
$('list').onclick = async e => {
  const edit = e.target.dataset.edit, del = e.target.dataset.del, push = e.target.dataset.push, test = e.target.dataset.test;
  if (push && confirm('全ユーザーの端末にプッシュ通知を送ります(通知をオフにしている人を除く)。取り消せません。送信しますか?')) {
    e.target.disabled = true; await runPush(push);
  }
  if (test) {
    const code = prompt('テスト送信先のフレンドコード(アプリのプロフィールに表示されます)');
    if (code) {
      const r = await fetch('/api/admin/announcements/' + test + '/push-test', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ friendCode: code })
      });
      const data = await r.json().catch(() => ({}));
      $('progress-' + test).textContent = r.ok ? 'テスト送信: 成功 ' + data.delivered + ' / 失敗 ' + data.failed : (data.error || '失敗しました。');
    }
  }
  if (edit) { fillForm(items.find(a => a.id === edit)); scrollTo(0, 0); }
  if (del && confirm('削除しますか?(元に戻せません)')) {
    await fetch('/api/admin/announcements/' + del, { method: 'DELETE' }); await load();
  }
};
load().catch(() => { $('error').textContent = '読み込みに失敗しました。'; });
</script>
</html>`;

export function handleAnnouncementsPage(url) {
  if (url.pathname !== "/admin/announcements") return null;
  return new Response(ADMIN_PAGE_HTML, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}
