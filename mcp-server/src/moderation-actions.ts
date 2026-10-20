// What an operator can do about a chat report beyond reading it (all behind
// Cloudflare Access, all logged before they act — see audit.ts):
//   POST /api/admin/chat-reports/:id/remove-message   stage 2: blank the message
//   POST /api/admin/chat-reports/:id/warn             stage 1: push a fixed warning
//   POST /api/admin/accounts/suspend    {reportID, scope?}   stage 3 (scope "chat") / 4 ("account", default)
//   POST /api/admin/accounts/unsuspend  {reportID | suspensionID, scope}
//   GET  /api/admin/accounts/suspended
//   GET  /api/admin/audit-log
// See docs/RUNBOOK.md RB-17.
import { json, readJSONLimited } from "./http.ts";
import { auditAdmin } from "./audit.ts";
import { SUSPENSION_PREFIX, CHAT_SUSPENSION_PREFIX } from "./session.ts";
import { sendPush } from "./push.ts";
import type { Env } from "./env.ts";
import { nextCursor } from "./kv.ts";

const WARNING = {
  title: "運営からのお知らせ",
  body: "あなたの投稿が利用規約に反している可能性があるため、確認しました。繰り返される場合は、機能の利用を制限することがあります。",
};
const PREFIXES: Record<string, string> = { account: SUSPENSION_PREFIX, chat: CHAT_SUSPENSION_PREFIX };

const NOTE_MAX = 2_000;
const requireJSON = (request: Request) => (request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json");

// Adds to the report's note without losing what the operator already wrote.
async function resolveReport(env: Env, id: string, line: string) {
  const row = await env.ADMIN_DB.prepare("SELECT admin_note FROM chat_reports WHERE id = ?").bind(id).first();
  const note = [row?.admin_note, line].filter(Boolean).join(" / ").slice(0, NOTE_MAX);
  await env.ADMIN_DB.prepare("UPDATE chat_reports SET status = 'resolved', admin_note = ?, updated_at = ? WHERE id = ?")
    .bind(note, Date.now(), id).run();
}

// The account behind a report's reported chat user, or why it can't be found.
async function reportedAccount(env: Env, reportID: unknown) {
  const report = await env.ADMIN_DB.prepare("SELECT reported_key FROM chat_reports WHERE id = ?").bind(reportID).first<{ reported_key: string }>();
  if (!report) return { response: json({ error: "Not found." }, 404) };
  const identityHash = await env.STUDIQUO_DATA.get(`chat-identity-of:${report.reported_key}`);
  if (!identityHash) {
    // Deleted accounts (a marker key) have nothing to suspend. Others are
    // recorded when they next open the app.
    const gone = report.reported_key.startsWith("deleted:");
    return { response: json({ error: gone ? "That account has been deleted." : "That account can't be identified yet; try again after they next open the app." }, gone ? 410 : 409) };
  }
  return { identityHash };
}

export async function handleModerationActions(url: URL, request: Request, env: Env) {
  const removeMatch = /^\/api\/admin\/chat-reports\/([0-9a-f-]{36})\/remove-message$/.exec(url.pathname);
  const warnMatch = /^\/api\/admin\/chat-reports\/([0-9a-f-]{36})\/warn$/.exec(url.pathname);
  const isAccounts = url.pathname.startsWith("/api/admin/accounts/");
  if (!removeMatch && !warnMatch && !isAccounts && url.pathname !== "/api/admin/audit-log") return null;
  if (!env.ADMIN_DB) return json({ error: "Unavailable." }, 503);

  if (url.pathname === "/api/admin/audit-log" && request.method === "GET") {
    await auditAdmin(env, request, "audit_log.view");
    const rows = await env.ADMIN_DB.prepare("SELECT id, at, actor, action, target, detail FROM admin_audit_log ORDER BY id DESC LIMIT 200").all();
    return json({ entries: rows.results ?? [] });
  }

  if (url.pathname === "/api/admin/accounts/suspended" && request.method === "GET") {
    await auditAdmin(env, request, "account.list_suspended");
    const suspended: Record<string, unknown>[] = [];
    for (const [scope, prefix] of Object.entries(PREFIXES)) {
      const names: string[] = [];
      let cursor: string | undefined;
      do {
        const page = await env.STUDIQUO_DATA.list({ prefix, cursor });
        names.push(...page.keys.map(key => key.name));
        cursor = nextCursor(page);
      } while (cursor);
      for (const name of names) {
        suspended.push({ scope, suspensionID: name.slice(prefix.length), ...(await env.STUDIQUO_DATA.get<Record<string, unknown>>(name, "json")) });
      }
    }
    return json({ suspended });
  }

  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);
  if (!requireJSON(request)) return json({ error: "Content-Type must be application/json." }, 415);

  if (removeMatch) {
    const report = await env.ADMIN_DB.prepare("SELECT room_id, message_id FROM chat_reports WHERE id = ?").bind(removeMatch[1]).first<{ room_id: string; message_id: number }>();
    if (!report) return json({ error: "Not found." }, 404);
    await auditAdmin(env, request, "chat_report.remove_message", removeMatch[1]);
    const result = await env.CHAT_ROOM.getByName(report.room_id).moderatorRemoveMessage(report.message_id);
    if (result.status === "not_found") return json({ error: "The message no longer exists." }, 404);
    await resolveReport(env, removeMatch[1], "メッセージを削除");
    return json({ status: result.status });
  }

  if (warnMatch) {
    const report = await env.ADMIN_DB.prepare("SELECT reported_key FROM chat_reports WHERE id = ?").bind(warnMatch[1]).first<{ reported_key: string }>();
    if (!report) return json({ error: "Not found." }, 404);
    if (report.reported_key.startsWith("deleted:")) return json({ error: "That account has been deleted." }, 410);
    await auditAdmin(env, request, "chat_report.warn", warnMatch[1]);
    const results = await sendPush(env, report.reported_key, WARNING);
    const delivered = results.filter(result => result?.delivered).length;
    await resolveReport(env, warnMatch[1], delivered > 0 ? "注意を送信" : "注意を送ったが届いた端末なし");
    return json({ warned: true, devices: results.length, delivered });
  }

  const body = await readJSONLimited(request, 1_000);
  if (url.pathname === "/api/admin/accounts/suspend") {
    const reportID = String(body?.reportID ?? "");
    if (!/^[0-9a-f-]{36}$/.test(reportID)) return json({ error: "reportID is required." }, 400);
    const scope = body?.scope === undefined ? "account" : body.scope;
    if (!Object.hasOwn(PREFIXES, scope)) return json({ error: "scope must be account or chat." }, 400);
    const found = await reportedAccount(env, reportID);
    if (found.response) return found.response;
    await auditAdmin(env, request, `account.suspend_${scope}`, found.identityHash.slice(0, 16), `report ${reportID}`);
    await env.STUDIQUO_DATA.put(`${PREFIXES[scope]}${found.identityHash}`, JSON.stringify({
      at: Date.now(), reportID, // who did it is in the audit log, not here
    }));
    await resolveReport(env, reportID, scope === "chat" ? "チャットを停止" : "アカウントを停止");
    return json({ suspended: true, scope, suspensionID: found.identityHash });
  }

  if (url.pathname === "/api/admin/accounts/unsuspend") {
    let id = String(body?.suspensionID ?? "");
    if (!id && /^[0-9a-f-]{36}$/.test(String(body?.reportID ?? ""))) {
      const found = await reportedAccount(env, body.reportID);
      if (found.response) return found.response;
      id = found.identityHash;
    }
    if (!/^[0-9a-f]{64}$/.test(id)) return json({ error: "suspensionID or reportID is required." }, 400);
    // Required, so lifting a chat stop can't quietly lift an account stop too.
    if (!Object.hasOwn(PREFIXES, body?.scope)) return json({ error: "scope must be account or chat." }, 400);
    const scopes = [body.scope];
    await auditAdmin(env, request, "account.unsuspend", id.slice(0, 16), scopes.join(","));
    for (const scope of scopes) await env.STUDIQUO_DATA.delete(`${PREFIXES[scope]}${id}`);
    return json({ suspended: false });
  }

  return json({ error: "Not found." }, 404);
}
