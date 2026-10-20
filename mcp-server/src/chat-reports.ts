// Filing a chat report (POST /api/chat/rooms/:id/messages/:n/report, called
// from chat.ts once the caller is known to be in the room).
//
// What makes a report usable: the message and its neighbours are copied at the
// moment of the report (a sender can retract afterwards, which blanks the
// room's copy), the sender is recorded as the reported party, and the
// operator is told in Slack — with the id and a link only, never the text.
import { json } from "./http.ts";
import { postSlackBlocks } from "./slack.ts";
import type { Env } from "./env.ts";

function roomErrorResponse(error: unknown) {
  if (error instanceof Error && error.message === "Forbidden") return json({ error: "Forbidden" }, 403);
  return null;
}

export async function fileChatReport(env: Env, ctx: ExecutionContext, url: URL, { roomID, messageID, reporterKey, reason }: any) {
  let snapshot;
  try {
    snapshot = await env.CHAT_ROOM.getByName(roomID).reportSnapshot(reporterKey, messageID);
  } catch (error) {
    const response = roomErrorResponse(error);
    if (response) return response;
    throw error;
  }
  if (!snapshot) return json({ error: "Not found" }, 404);
  if (snapshot.reportedKey === reporterKey) return json({ error: "You cannot report your own message." }, 400);

  const id = crypto.randomUUID();
  const now = Date.now();
  const inserted = await env.ADMIN_DB.prepare(
    `INSERT OR IGNORE INTO chat_reports
       (id, room_id, message_id, reporter_key, reported_key, reason, snapshot, status, admin_note, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'open', '', ?, ?)`
  ).bind(id, roomID, messageID, reporterKey, snapshot.reportedKey, reason, JSON.stringify(snapshot.messages), now, now).run();
  // Reporting the same message twice is accepted but adds nothing.
  if ((inserted.meta?.changes ?? inserted.meta?.rows_written ?? 1) === 0) return json({ status: "reported" });

  const notify = postSlackBlocks(env, [
    { type: "header", text: { type: "plain_text", text: "🚩 studiquo チャットの通報", emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: `通報ID: ${id}` } },
    { type: "context", elements: [{ type: "mrkdwn", text: `<${url.origin}/api/admin/chat-reports/${id}|管理APIで開く(Access認証)>` }] },
  ]);
  if (ctx?.waitUntil) ctx.waitUntil(notify); else await notify;
  return json({ status: "reported" });
}
