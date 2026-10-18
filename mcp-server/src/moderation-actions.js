// What an operator can do about a chat report beyond reading it (all behind
// Cloudflare Access, all logged before they act — see audit.js):
//   POST /api/admin/chat-reports/:id/remove-message   stage 2: blank the message
//   POST /api/admin/accounts/suspend    {reportID}    stage 4: suspend the reported account
//   POST /api/admin/accounts/unsuspend  {reportID | suspensionID}
//   GET  /api/admin/accounts/suspended
// See docs/RUNBOOK.md RB-17.
import { json, readJSONLimited } from "./http.js";
import { auditAdmin } from "./audit.js";
import { SUSPENSION_PREFIX } from "./session.js";

const NOTE_MAX = 2_000;
const requireJSON = request => (request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json");

// Adds to the report's note without losing what the operator already wrote.
async function resolveReport(env, id, line) {
  const row = await env.ADMIN_DB.prepare("SELECT admin_note FROM chat_reports WHERE id = ?").bind(id).first();
  const note = [row?.admin_note, line].filter(Boolean).join(" / ").slice(0, NOTE_MAX);
  await env.ADMIN_DB.prepare("UPDATE chat_reports SET status = 'resolved', admin_note = ?, updated_at = ? WHERE id = ?")
    .bind(note, Date.now(), id).run();
}

// The account behind a report's reported chat user, or why it can't be found.
async function reportedAccount(env, reportID) {
  const report = await env.ADMIN_DB.prepare("SELECT reported_key FROM chat_reports WHERE id = ?").bind(reportID).first();
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

export async function handleModerationActions(url, request, env) {
  const removeMatch = /^\/api\/admin\/chat-reports\/([0-9a-f-]{36})\/remove-message$/.exec(url.pathname);
  const isAccounts = url.pathname.startsWith("/api/admin/accounts/");
  if (!removeMatch && !isAccounts) return null;
  if (!env.ADMIN_DB) return json({ error: "Unavailable." }, 503);

  if (url.pathname === "/api/admin/accounts/suspended" && request.method === "GET") {
    await auditAdmin(env, request, "account.list_suspended");
    const names = [];
    let cursor;
    do {
      const page = await env.STUDIQUO_DATA.list({ prefix: SUSPENSION_PREFIX, cursor });
      names.push(...page.keys.map(key => key.name));
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    const suspended = await Promise.all(names.map(async name => ({
      suspensionID: name.slice(SUSPENSION_PREFIX.length),
      ...(await env.STUDIQUO_DATA.get(name, "json")),
    })));
    return json({ suspended });
  }

  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);
  if (!requireJSON(request)) return json({ error: "Content-Type must be application/json." }, 415);

  if (removeMatch) {
    const report = await env.ADMIN_DB.prepare("SELECT room_id, message_id FROM chat_reports WHERE id = ?").bind(removeMatch[1]).first();
    if (!report) return json({ error: "Not found." }, 404);
    await auditAdmin(env, request, "chat_report.remove_message", removeMatch[1]);
    const result = await env.CHAT_ROOM.getByName(report.room_id).moderatorRemoveMessage(report.message_id);
    if (result.status === "not_found") return json({ error: "The message no longer exists." }, 404);
    await resolveReport(env, removeMatch[1], "メッセージを削除");
    return json({ status: result.status });
  }

  const body = await readJSONLimited(request, 1_000);
  if (url.pathname === "/api/admin/accounts/suspend") {
    const reportID = String(body?.reportID ?? "");
    if (!/^[0-9a-f-]{36}$/.test(reportID)) return json({ error: "reportID is required." }, 400);
    const found = await reportedAccount(env, reportID);
    if (found.response) return found.response;
    await auditAdmin(env, request, "account.suspend", found.identityHash.slice(0, 16), `report ${reportID}`);
    await env.STUDIQUO_DATA.put(`${SUSPENSION_PREFIX}${found.identityHash}`, JSON.stringify({
      at: Date.now(), reportID, // who did it is in the audit log, not here
    }));
    await resolveReport(env, reportID, "アカウントを停止");
    return json({ suspended: true, suspensionID: found.identityHash });
  }

  if (url.pathname === "/api/admin/accounts/unsuspend") {
    let id = String(body?.suspensionID ?? "");
    if (!id && /^[0-9a-f-]{36}$/.test(String(body?.reportID ?? ""))) {
      const found = await reportedAccount(env, body.reportID);
      if (found.response) return found.response;
      id = found.identityHash;
    }
    if (!/^[0-9a-f]{64}$/.test(id)) return json({ error: "suspensionID or reportID is required." }, 400);
    await auditAdmin(env, request, "account.unsuspend", id.slice(0, 16));
    await env.STUDIQUO_DATA.delete(`${SUSPENSION_PREFIX}${id}`);
    return json({ suspended: false });
  }

  return json({ error: "Not found." }, 404);
}
